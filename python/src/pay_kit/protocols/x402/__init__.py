"""x402 ``exact`` (Solana) adapter package.

Self-hosted x402 ``exact`` scheme for the Solana SVM. ``X402Adapter`` (this
module) issues 402 challenges, runs the structural 11-rule verifier on
submitted credentials, cosigns as the facilitator fee payer, broadcasts via
the configured RPC, and namespaces the consumed signature in the replay store.
The verifier, module constants, and ``X402*`` wire TypedDicts live under
:mod:`pay_kit.protocols.x402.exact`; the client builder lives under
:mod:`pay_kit.protocols.x402.client`.

Delegated mode (``X402Config.facilitator_url`` set) is reserved in the config
schema but not yet wired; the adapter raises ``NotImplementedError`` when a
facilitator URL is configured. Self-hosted is the only x402 path that ships.
"""

from __future__ import annotations

import base64
import json
from collections.abc import Callable, Iterable
from typing import TYPE_CHECKING, Any, cast

from pay_kit._paycore.mints import resolve, token_program_for
from pay_kit._paycore.network import SOLANA_DEVNET_CAIP2, SOLANA_MAINNET_CAIP2
from pay_kit._paycore.network_check import check_network_blockhash
from pay_kit._paycore.protocol import Protocol
from pay_kit._paycore.rpc import SolanaRpc
from pay_kit._paycore.store import MemoryStore, Store
from pay_kit.errors import ConfigurationError, InvalidProofError
from pay_kit.payment import Payment
from pay_kit.protocols.mpp.intents.charge import parse_units
from pay_kit.protocols.x402.exact.types import (
    X402AcceptsEntry,
    X402Challenge,
    X402Extra,
    X402PayloadField,
    X402ResponseEnvelope,
)
from pay_kit.protocols.x402.exact.verify import (
    X402_V1_PAYMENT_HEADER,
    X402_V2_PAYMENT_HEADER,
    X402_VERSION,
    X402_VERSION_FIELD,
    X402_VERSION_V1,
    X402_VERSION_V2,
    ExactVerifier,
)

if TYPE_CHECKING:
    from pay_kit.config import Config
    from pay_kit.gate import Gate

__all__ = ["X402Adapter", "ExactVerifier", "X402_VERSION"]


_SETTLEMENT_HEADER = "x-payment-settlement-signature"
_RESPONSE_HEADER = "payment-response"
_REPLAY_PREFIX = "x402-svm-exact:consumed:"


class X402Adapter:
    """Self-hosted server adapter for the x402 ``exact`` Solana scheme."""

    def __init__(
        self,
        config: Config,
        replay_store: Store | None = None,
        recent_blockhash_provider: Callable[[], str | None] | None = None,
    ) -> None:
        """Build an adapter bound to ``config``; raise for delegated mode."""
        if config.x402.is_delegated():
            raise NotImplementedError(
                "pay_kit: x402 delegated mode is not yet implemented; "
                "leave X402Config.facilitator_url None for self-hosted"
            )
        self._config = config
        self._store: Store = replay_store if replay_store is not None else MemoryStore()
        self._recent_blockhash_provider = recent_blockhash_provider

    def accepts_entry(self, gate: Gate, request: Any) -> X402AcceptsEntry:
        """Build one ``accepts[]`` entry (the server x402 offer for ``gate``)."""
        coin = gate.amount.primary_coin()
        coin_value = coin.value if coin is not None else self._config.stablecoins[0].value
        label = self._config.network.mints_label()
        # x402 puts the on-chain mint pubkey on `asset`, not the ticker.
        # resolve() falls back to the mainnet row when the network row is
        # absent (caveat #1).
        asset = resolve(coin_value, label) or coin_value
        token_program = token_program_for(coin_value, label)
        pay_to = gate.pay_to or self._config.effective_recipient()
        # Exact 6-decimal base-unit conversion. ``int(amount * 1_000_000)``
        # silently truncated sub-microunit precision (usd("0.0000009") -> "0"),
        # which would have the verifier accept a zero-amount transfer. Reuse the
        # MPP ``parse_units`` helper so over-precision is rejected the same way
        # MPP rejects it; surface it as a ConfigurationError at offer-build time.
        try:
            amount = parse_units(gate.total().amount_string(), 6)
        except ValueError as exc:
            raise ConfigurationError(
                f"pay_kit: x402 price {gate.total().amount_string()!r} exceeds 6-decimal (micro-unit) precision; "
                "USDC settles in micro-units"
            ) from exc
        signer = self._config.x402.effective_signer(self._config.operator)
        extra: X402Extra = {
            "feePayer": signer.pubkey() if signer is not None else "",
            "decimals": 6,
            "tokenProgram": token_program,
            "memo": _request_path(request),
        }
        # caveat #5: stamp the server's recent blockhash into accepted.extra
        # so pay-kit Rust clients sign against the same chain state the server
        # broadcasts to. Canonical TS/Go clients ignore it; harmless on real
        # networks. The provider keeps unit tests offline.
        blockhash = self._fetch_recent_blockhash()
        if blockhash is not None:
            extra["recentBlockhash"] = blockhash
        return {
            "protocol": "x402",
            "scheme": "exact",
            "network": self._caip2(),
            "asset": asset,
            "amount": amount,
            "maxAmountRequired": amount,
            "payTo": pay_to,
            "maxTimeoutSeconds": 60,
            "extra": extra,
        }

    def challenge_headers(self, gate: Gate, request: Any) -> dict[str, str]:
        """Build the ``payment-required`` header (base64 JSON challenge)."""
        challenge: X402Challenge = {
            "x402Version": X402_VERSION,
            "resource": {"type": "http", "url": _request_path(request)},
            "accepts": [self.accepts_entry(gate, request)],
        }
        payload = json.dumps(challenge, separators=(",", ":")).encode("utf-8")
        return {"payment-required": base64.b64encode(payload).decode("ascii")}

    async def verify_and_settle(self, gate: Gate, request: Any) -> Payment:
        """Verify the submitted x402 credential, cosign, broadcast, settle."""
        signer = self._config.x402.effective_signer(self._config.operator)
        if signer is None:
            raise InvalidProofError("pay_kit: x402 requires operator.signer", code="payment_invalid")

        header = _payment_signature_header(request)
        if not header:
            raise InvalidProofError("pay_kit: payment required", code="payment_required")

        try:
            decoded = base64.b64decode(header, validate=True)
        except Exception as exc:  # noqa: BLE001
            raise InvalidProofError(
                "invalid_exact_svm_payload_signature_base64",
                code="invalid_exact_svm_payload_signature_base64",
            ) from exc
        try:
            envelope = json.loads(decoded)
        except Exception as exc:  # noqa: BLE001
            raise InvalidProofError(
                "invalid_exact_svm_payload_signature_json",
                code="invalid_exact_svm_payload_signature_json",
            ) from exc

        if not isinstance(envelope, dict):
            raise InvalidProofError("unsupported_x402_version", code="unsupported_x402_version")
        # The envelope is attacker-controlled; it is validated field-by-field
        # below, then narrowed to the typed wire shape for the rest of the flow.
        envelope_map = cast("dict[str, object]", envelope)
        version = envelope_map.get(X402_VERSION_FIELD)
        # Branch on the version first: a genuinely-unknown version is rejected
        # before any further envelope validation (mirrors rust exact.rs:315-346,
        # which matches on ``x402Version`` and falls through to the unsupported
        # arm). v1 and v2 share the same envelope/payload validation below.
        if version not in (X402_VERSION_V1, X402_VERSION_V2):
            raise InvalidProofError("unsupported_x402_version", code="unsupported_x402_version")

        payload_raw = envelope_map.get("payload")
        if not isinstance(payload_raw, dict):
            raise InvalidProofError(
                "invalid_exact_svm_payload_envelope",
                code="invalid_exact_svm_payload_envelope",
            )
        payload = cast("X402PayloadField", payload_raw)

        # The route's expected requirement always comes from the server offer,
        # never from the credential. x402 has no HMAC-bound challenge id, so the
        # credential's self-described identity is only ever compared against,
        # never trusted (mirrors rust ``verify_pinned_fields`` + the targeted
        # deepEqual gate).
        offer = self.accepts_entry(gate, request)
        offer_map = cast("dict[str, object]", offer)

        if version == X402_VERSION_V2:
            # v2: the credential carries an ``accepted`` requirement that must
            # match the server's freshly built offer for this route.
            accepted_raw = envelope_map.get("accepted")
            if not isinstance(accepted_raw, dict):
                raise InvalidProofError(
                    "invalid_exact_svm_payload_envelope",
                    code="invalid_exact_svm_payload_envelope",
                )
            accepted = cast("dict[str, object]", accepted_raw)
            self._verify_accepted_matches_offer(accepted, offer_map)
        else:
            # v1 (legacy): the envelope commits only to top-level ``scheme`` +
            # ``network`` and carries NO ``accepted`` object (mirrors rust
            # exact.rs:316-327). Validate scheme=="exact" and that the legacy
            # network string normalizes to the server's CAIP-2 network; the
            # credential-binding deepEqual block is skipped entirely and the
            # server offer is the sole source of truth.
            scheme = envelope_map.get("scheme")
            if scheme != "exact":
                raise InvalidProofError(
                    "invalid_exact_svm_payload_type",
                    code="invalid_exact_svm_payload_type",
                )
            network_raw = envelope_map.get("network")
            network = network_raw if isinstance(network_raw, str) else ""
            expected_network = self._caip2()
            if _caip2_network_for_cluster(network) != expected_network:
                raise InvalidProofError(
                    f"pay_kit: x402 network mismatch: credential {network!r} != server {expected_network!r}",
                    code="charge_request_mismatch",
                )
            # v1 has no per-credential ``accepted``; the route offer is truth.
            accepted = offer_map

        tx_base64 = payload.get("transaction")
        if not isinstance(tx_base64, str) or tx_base64 == "":
            raise InvalidProofError(
                "invalid_exact_svm_payload_missing_transaction",
                code="invalid_exact_svm_payload_missing_transaction",
            )

        # Structural shape (11 rules) against the server offer.
        ExactVerifier.verify(tx_base64, cast("dict[str, Any]", offer), [signer.pubkey()])

        # Reject up-front if the client signed against the wrong cluster.
        # Skip on a loopback RPC where a Surfpool blockhash is expected.
        rpc_url = self._config.effective_rpc_url()
        if not _is_loopback_rpc(rpc_url):
            blockhash = _recent_blockhash_of(tx_base64)
            if blockhash is not None:
                check_network_blockhash(self._config.network.mints_label(), blockhash)

        # Cosign as the facilitator fee payer (slot-splice, version aware).
        cosigned_wire = _co_sign(tx_base64, signer)

        rpc = SolanaRpc(rpc_url)
        try:
            try:
                response = await rpc.send_raw_transaction(cosigned_wire)
                signature = str(response.value if hasattr(response, "value") else response)
            except Exception as exc:  # noqa: BLE001
                raise InvalidProofError(
                    f"pay_kit: invalid proof: broadcast failed: {exc}", code="payment_invalid"
                ) from exc
            if not signature:
                raise InvalidProofError("pay_kit: empty broadcast result", code="payment_invalid")

            # Replay reservation. Namespace is distinct from the MPP charge key
            # so an x402 signature can never satisfy an MPP route and vice
            # versa. Reserve BEFORE confirmation so a concurrent resubmit of the
            # same signature loses the race and is rejected as consumed.
            replay_key = _REPLAY_PREFIX + signature
            if not await self._store.put_if_absent(replay_key, True):
                raise InvalidProofError("pay_kit: signature_consumed", code="signature_consumed")

            # Await on-chain confirmation BEFORE returning success. Without this
            # the adapter returned a settlement header for a transaction that
            # may have been dropped by the cluster or reverted on-chain, granting
            # the client access without payment. ``await_confirmation`` raises
            # ``transaction-failed`` (included but reverted) or
            # ``transaction-not-found`` (never confirmed inside the window).
            #
            # On failure roll the reservation back: the transaction did not
            # land, so the same signature must remain replayable for an honest
            # retry. Mirrors the confirmation gate the MPP charge flow runs
            # (protocols/mpp/server/charge.py).
            try:
                await rpc.await_confirmation(signature)
            except Exception as exc:  # noqa: BLE001
                await self._store.delete(replay_key)
                raise InvalidProofError(
                    f"pay_kit: invalid proof: confirmation failed: {exc}", code="payment_invalid"
                ) from exc
        finally:
            await rpc.aclose()

        accepted_network = accepted.get("network")
        response_body: X402ResponseEnvelope = {
            "success": True,
            "transaction": signature,
            "network": accepted_network if isinstance(accepted_network, str) and accepted_network else self._caip2(),
            "payer": payload.get("transactionHash", ""),
        }
        response_envelope = base64.b64encode(json.dumps(response_body, separators=(",", ":")).encode("utf-8")).decode(
            "ascii"
        )

        return Payment(
            protocol=Protocol.X402,
            transaction=signature,
            gate_name=gate.name,
            settlement_headers={
                _RESPONSE_HEADER: response_envelope,
                _SETTLEMENT_HEADER: signature,
            },
            raw=header,
        )

    @staticmethod
    def _verify_accepted_matches_offer(accepted: dict[str, object], offer_map: dict[str, object]) -> None:
        """Reject when the v2 credential's ``accepted`` drifts from the offer."""
        for key in ("scheme", "network", "asset", "payTo"):
            if accepted.get(key) != offer_map.get(key):
                raise InvalidProofError(
                    "pay_kit: charge_request_mismatch: accepted payment requirement does not match server challenge",
                    code="charge_request_mismatch",
                )
        # Reject if EITHER the exact `amount` or the `maxAmountRequired`
        # ceiling drifts from the server offer. An AND would only trip when both
        # diverged, so one-sided drift (e.g. amount tampered while
        # maxAmountRequired left intact) would silently pass.
        if accepted.get("amount") != offer_map.get("amount") or accepted.get(
            "maxAmountRequired"
        ) != offer_map.get("maxAmountRequired"):
            raise InvalidProofError(
                "pay_kit: charge_request_mismatch (amount)",
                code="charge_request_mismatch",
            )
        offer_extra = cast("dict[str, object]", offer_map.get("extra") or {})
        accepted_extra_raw = accepted.get("extra")
        accepted_extra = cast("dict[str, object]", accepted_extra_raw if isinstance(accepted_extra_raw, dict) else {})
        for key in ("feePayer", "tokenProgram", "memo"):
            if key in offer_extra and accepted_extra.get(key) != offer_extra[key]:
                raise InvalidProofError(
                    f"pay_kit: charge_request_mismatch (extra.{key})",
                    code="charge_request_mismatch",
                )

    def _fetch_recent_blockhash(self) -> str | None:
        if self._recent_blockhash_provider is not None:
            try:
                value = self._recent_blockhash_provider()
            except Exception:  # noqa: BLE001 - provider failures are non-fatal
                return None
            return value if isinstance(value, str) and value != "" else None
        return None

    def _caip2(self) -> str:
        return self._config.network.caip2()


def _caip2_network_for_cluster(cluster: str) -> str:
    """Normalize a cluster slug or CAIP-2 id to a Solana CAIP-2 network.

    Mirrors rust ``caip2_network_for_cluster`` (types.rs:31-39) for the subset
    the python SDK supports (mainnet + devnet/localnet; testnet is absent from
    the python network table). The legacy v1 network strings ``"solana"`` and
    ``"solana-devnet"`` normalize back to the correct CAIP-2 id so the v1
    network-mismatch check compares like for like.
    """
    if cluster in (SOLANA_MAINNET_CAIP2, "solana", "mainnet", "mainnet-beta"):
        return SOLANA_MAINNET_CAIP2
    if cluster in (SOLANA_DEVNET_CAIP2, "solana-devnet", "devnet", "localnet"):
        return SOLANA_DEVNET_CAIP2
    # Any other ``solana:...`` id passes through; everything else defaults to
    # mainnet (mirrors the rust catch-all arm).
    return cluster if cluster.startswith("solana:") else SOLANA_MAINNET_CAIP2


def _co_sign(transaction_b64: str, signer: Any) -> bytes:
    """Splice the facilitator signature into the fee-payer slot, return wire.

    Legacy messages are signed over ``bytes(msg)``, v0 over
    ``to_bytes_versioned(msg)`` (0x80 prefix). The fee payer must occupy a
    signature slot. The v0-wire detector lives in the shared
    :mod:`pay_kit._paycore.transaction` core so neither protocol depends on the
    other.
    """
    from solders.message import to_bytes_versioned
    from solders.pubkey import Pubkey
    from solders.transaction import Transaction, VersionedTransaction

    from pay_kit._paycore.transaction import is_v0_wire_bytes

    raw = base64.b64decode(transaction_b64)
    fee_payer_pubkey = Pubkey.from_string(signer.pubkey())

    # SECURITY: ``solders.transaction.Transaction.from_bytes`` is lenient and
    # silently MIS-PARSES v0 ``VersionedTransaction`` wire bytes as a legacy
    # transaction (it does not raise), yielding a bogus header and garbage
    # account keys. The rust x402 client (and the canonical PaymentProof
    # builder) emit v0 messages, so we must route on the message-version
    # prefix byte rather than trusting a legacy parse to fail. Reuses the
    # shared ``is_v0_wire_bytes`` guard from ``pay_kit._paycore.transaction``
    # (no parallel detection logic; same routing as the MPP charge cosign).
    if is_v0_wire_bytes(raw):
        try:
            vtx = VersionedTransaction.from_bytes(raw)
        except Exception as exc:  # noqa: BLE001
            raise InvalidProofError(
                "invalid_exact_svm_payload_transaction_parse",
                code="invalid_exact_svm_payload_transaction_parse",
            ) from exc
        account_keys = list(vtx.message.account_keys)
        message_bytes = bytes(to_bytes_versioned(vtx.message))
        num_required = int(vtx.message.header.num_required_signatures)
    else:
        try:
            tx = Transaction.from_bytes(raw)
        except Exception:  # noqa: BLE001 - fall back to versioned
            try:
                vtx = VersionedTransaction.from_bytes(raw)
            except Exception as exc:  # noqa: BLE001
                raise InvalidProofError(
                    "invalid_exact_svm_payload_transaction_parse",
                    code="invalid_exact_svm_payload_transaction_parse",
                ) from exc
            account_keys = list(vtx.message.account_keys)
            message_bytes = bytes(to_bytes_versioned(vtx.message))
            num_required = int(vtx.message.header.num_required_signatures)
        else:
            account_keys = list(tx.message.account_keys)
            message_bytes = bytes(tx.message)
            num_required = int(tx.message.header.num_required_signatures)

    try:
        idx = account_keys.index(fee_payer_pubkey)
    except ValueError as exc:
        raise InvalidProofError(
            "pay_kit: fee payer pubkey not present in transaction accounts",
            code="payment_invalid",
        ) from exc
    if idx >= num_required:
        raise InvalidProofError("pay_kit: fee payer is not a required signer", code="payment_invalid")

    sig_bytes = bytes(signer.sign(message_bytes))
    serialized = bytearray(raw)
    sig_start = 1 + idx * 64
    serialized[sig_start : sig_start + 64] = sig_bytes
    return bytes(serialized)


def _recent_blockhash_of(transaction_b64: str) -> str | None:
    """Best-effort extract of the recent blockhash for the network check."""
    from solders.transaction import VersionedTransaction

    try:
        raw = base64.b64decode(transaction_b64)
        tx = VersionedTransaction.from_bytes(raw)
        return str(tx.message.recent_blockhash)
    except Exception:  # noqa: BLE001 - the verifier already validated shape
        return None


def _is_loopback_rpc(rpc_url: str) -> bool:
    """True if ``rpc_url`` points at a loopback host (mirror rust)."""
    stripped = rpc_url.strip()
    for prefix in ("http://", "https://", "ws://", "wss://"):
        if stripped.startswith(prefix):
            stripped = stripped[len(prefix) :]
            break
    host_and_rest = stripped.split("/", 1)[0]
    host = host_and_rest[1:].split("]", 1)[0] if host_and_rest.startswith("[") else host_and_rest.split(":", 1)[0]
    return host in {"127.0.0.1", "localhost", "::1", "0.0.0.0"}


def _request_path(request: Any) -> str:
    """Resolve the request path across framework request shapes."""
    path = getattr(request, "path", None)
    if isinstance(path, str):
        return path
    url = getattr(request, "url", None)
    if url is not None:
        url_path = getattr(url, "path", None)
        if isinstance(url_path, str):
            return url_path
    if isinstance(request, dict):
        candidate = cast("dict[str, object]", request).get("path")
        if isinstance(candidate, str):
            return candidate
    return "/"


#: Credential header names the server reads, in priority order: the v2
#: ``PAYMENT-SIGNATURE`` header is preferred; the legacy v1 ``X-PAYMENT`` header
#: is accepted for backward compatibility (mirrors rust reading both,
#: constants.rs:16/25). Each entry is the set of casings tried against a
#: case-sensitive ``.get`` (framework header maps are case-insensitive; a plain
#: dict is not, so common casings are tried explicitly).
_CREDENTIAL_HEADER_CASINGS = (
    ("payment-signature", "Payment-Signature", X402_V2_PAYMENT_HEADER),
    ("x-payment", "X-Payment", X402_V1_PAYMENT_HEADER),
)
#: Lowercased credential header names for the plain-dict case-insensitive scan.
_CREDENTIAL_HEADER_NAMES = (X402_V2_PAYMENT_HEADER.lower(), X402_V1_PAYMENT_HEADER.lower())


def _payment_signature_header(request: Any) -> str:
    """Read the v2 ``PAYMENT-SIGNATURE`` or legacy v1 ``X-PAYMENT`` credential.

    Header matching is case-insensitive; the v2 header wins when both are
    present. Mirrors the rust server reading both header names (the v2 default
    plus the legacy v1 header) so an ``x402Version == 1`` envelope sent on
    ``X-PAYMENT`` is accepted for backward compatibility.
    """
    headers = getattr(request, "headers", None)
    if headers is not None:
        getter = getattr(headers, "get", None)
        if callable(getter):
            for casings in _CREDENTIAL_HEADER_CASINGS:
                for name in casings:
                    value: object = getter(name)
                    if value:
                        return str(value)
            # Plain-dict header maps are case-sensitive: scan once, lowercased.
            items = getattr(headers, "items", None)
            if callable(items):
                pairs = cast("Iterable[tuple[object, object]]", items())
                lowered: dict[str, object] = {
                    key.lower(): hv for key, hv in pairs if isinstance(key, str) and hv
                }
                for name in _CREDENTIAL_HEADER_NAMES:
                    if name in lowered:
                        return str(lowered[name])
    if isinstance(request, dict):
        raw_headers = cast("dict[str, object]", request).get("headers")
        if isinstance(raw_headers, dict):
            lowered_dict: dict[str, object] = {
                key.lower(): header_value
                for key, header_value in cast("dict[object, object]", raw_headers).items()
                if isinstance(key, str) and header_value
            }
            for name in _CREDENTIAL_HEADER_NAMES:
                if name in lowered_dict:
                    return str(lowered_dict[name])
    return ""
