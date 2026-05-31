"""Session intent wire types and voucher helpers.

The session intent opens a payment channel between a client and server so the
client can pay incrementally with off-chain signed vouchers, settled on-chain
only at open / top-up / close. Backed by the on-chain payment-channels program.

Mirrors the Rust spine at ``rust/crates/mpp/src/protocol/intents/session.rs``.

Load-bearing wire parity:

* ``cumulativeAmount`` wire name with a ``cumulative`` read-alias.
* ``salt`` serialized as a decimal string, deserialized from string or number.
* action tag ``topUp`` (capital U) inside :class:`SessionAction`.
* voucher signing bytes = ``channel_id(32) || cumulative(u64 LE) ||
  expires_at(i64 LE)`` = 48 bytes (see :mod:`solana_mpp.protocol.payment_channels`).
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from solana_mpp.protocol.payment_channels import voucher_message_bytes

# Default session voucher/directive expiry: 2100-01-01T00:00:00Z.
#
# This stays below JavaScript's max safe integer so JSON intermediaries do not
# round it before the credential is decoded. Matches the Rust spine constant
# ``DEFAULT_SESSION_EXPIRES_AT``.
DEFAULT_SESSION_EXPIRES_AT = 4_102_444_800

# Session funding modes, serialized camelCase.
SESSION_MODE_PUSH = "push"
SESSION_MODE_PULL = "pull"

# Pull-mode voucher authority strategies, serialized camelCase.
PULL_STRATEGY_CLIENT_VOUCHER = "clientVoucher"
PULL_STRATEGY_OPERATED_VOUCHER = "operatedVoucher"

# Commit receipt status, serialized camelCase.
COMMIT_STATUS_COMMITTED = "committed"
COMMIT_STATUS_REPLAYED = "replayed"


def _salt_to_wire(value: int | None) -> str | None:
    """Serialize an optional u64 salt as a decimal string (never a number)."""
    if value is None:
        return None
    return str(value)


def _salt_from_wire(value: Any) -> int | None:
    """Deserialize an optional u64 salt from a string or a JSON number.

    Mirrors ``deserialize_optional_u64_from_string_or_number`` on the Rust
    spine: the serializer always emits a string, but the deserializer accepts
    both for ecosystem compatibility.
    """
    if value is None:
        return None
    if isinstance(value, bool):
        raise ValueError("salt must be a decimal string or unsigned 64-bit integer")
    if isinstance(value, int):
        return value
    if isinstance(value, str):
        return int(value)
    raise ValueError("salt must be a decimal string or unsigned 64-bit integer")


@dataclass
class SessionSplit:
    """A payment split committed at channel open, distributed at close."""

    recipient: str
    bps: int

    def to_dict(self) -> dict[str, Any]:
        return {"recipient": self.recipient, "bps": self.bps}

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> SessionSplit:
        return cls(recipient=data["recipient"], bps=int(data["bps"]))


@dataclass
class SessionRequest:
    """Session intent request, embedded in a 402 challenge.

    Describes the channel parameters: cap, currency, splits, network, etc.
    """

    cap: str
    currency: str
    operator: str
    recipient: str
    decimals: int | None = None
    network: str | None = None
    splits: list[SessionSplit] = field(default_factory=list)
    program_id: str | None = None
    description: str | None = None
    external_id: str | None = None
    min_voucher_delta: str | None = None
    modes: list[str] = field(default_factory=list)
    pull_voucher_strategy: str | None = None
    recent_blockhash: str | None = None

    def to_dict(self) -> dict[str, Any]:
        d: dict[str, Any] = {"cap": self.cap, "currency": self.currency}
        if self.decimals is not None:
            d["decimals"] = self.decimals
        if self.network is not None:
            d["network"] = self.network
        d["operator"] = self.operator
        d["recipient"] = self.recipient
        if self.splits:
            d["splits"] = [s.to_dict() for s in self.splits]
        if self.program_id is not None:
            d["programId"] = self.program_id
        if self.description is not None:
            d["description"] = self.description
        if self.external_id is not None:
            d["externalId"] = self.external_id
        if self.min_voucher_delta is not None:
            d["minVoucherDelta"] = self.min_voucher_delta
        if self.modes:
            d["modes"] = list(self.modes)
        if self.pull_voucher_strategy is not None:
            d["pullVoucherStrategy"] = self.pull_voucher_strategy
        if self.recent_blockhash is not None:
            d["recentBlockhash"] = self.recent_blockhash
        return d

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> SessionRequest:
        return cls(
            cap=data["cap"],
            currency=data["currency"],
            operator=data.get("operator", ""),
            recipient=data.get("recipient", ""),
            decimals=data.get("decimals"),
            network=data.get("network"),
            splits=[SessionSplit.from_dict(s) for s in data.get("splits", [])],
            program_id=data.get("programId"),
            description=data.get("description"),
            external_id=data.get("externalId"),
            min_voucher_delta=data.get("minVoucherDelta"),
            modes=list(data.get("modes", [])),
            pull_voucher_strategy=data.get("pullVoucherStrategy"),
            recent_blockhash=data.get("recentBlockhash"),
        )


@dataclass
class VoucherData:
    """The canonical content of a voucher, signed by the client's session key.

    The wire JSON carries ``channelId`` (base58), ``cumulativeAmount`` (decimal
    string, also accepted as ``cumulative`` on read) and ``expiresAt`` (i64).
    The signed bytes are the on-chain Borsh layout (see :meth:`message_bytes`).
    """

    channel_id: str
    cumulative: str
    expires_at: int
    nonce: int | None = None

    def message_bytes(self) -> bytes:
        """Serialize to the payment-channels VoucherArgs bytes signed by Ed25519.

        Layout: ``channel_id(32) || cumulative(u64 LE) || expires_at(i64 LE)``.
        """
        return voucher_message_bytes(self.channel_id, int(self.cumulative), self.expires_at)

    def to_dict(self) -> dict[str, Any]:
        d: dict[str, Any] = {
            "channelId": self.channel_id,
            "cumulativeAmount": self.cumulative,
            "expiresAt": self.expires_at,
        }
        if self.nonce is not None:
            d["nonce"] = self.nonce
        return d

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> VoucherData:
        # Accept both the canonical ``cumulativeAmount`` and the legacy
        # ``cumulative`` alias on read; serialize only as ``cumulativeAmount``.
        cumulative = data.get("cumulativeAmount")
        if cumulative is None:
            cumulative = data.get("cumulative")
        return cls(
            channel_id=data["channelId"],
            cumulative=str(cumulative),
            expires_at=int(data["expiresAt"]),
            nonce=data.get("nonce"),
        )


@dataclass
class SignedVoucher:
    """A signed voucher authorizing cumulative payment up to ``cumulative``."""

    data: VoucherData
    signature: str

    def to_dict(self) -> dict[str, Any]:
        return {"data": self.data.to_dict(), "signature": self.signature}

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> SignedVoucher:
        return cls(data=VoucherData.from_dict(data["data"]), signature=data["signature"])


@dataclass
class OpenPayload:
    """Payload for the ``open`` action.

    Use :meth:`push`, :meth:`payment_channel`, or :meth:`pull` to construct.
    Inspect :attr:`mode` to distinguish variants on the server.
    """

    mode: str
    authorized_signer: str
    signature: str
    # Push mode.
    channel_id: str | None = None
    deposit: str | None = None
    payer: str | None = None
    payee: str | None = None
    mint: str | None = None
    salt: int | None = None
    grace_period: int | None = None
    transaction: str | None = None
    # Pull mode.
    token_account: str | None = None
    approved_amount: str | None = None
    owner: str | None = None
    init_multi_delegate_tx: str | None = None
    update_delegation_tx: str | None = None

    @classmethod
    def push(cls, channel_id: str, deposit: str, authorized_signer: str, signature: str) -> OpenPayload:
        return cls(
            mode=SESSION_MODE_PUSH,
            authorized_signer=authorized_signer,
            signature=signature,
            channel_id=channel_id,
            deposit=deposit,
        )

    @classmethod
    def payment_channel(
        cls,
        channel_id: str,
        deposit: str,
        payer: str,
        payee: str,
        mint: str,
        salt: int,
        grace_period: int,
        authorized_signer: str,
        signature: str,
    ) -> OpenPayload:
        return cls.payment_channel_with_mode(
            SESSION_MODE_PUSH,
            channel_id,
            deposit,
            payer,
            payee,
            mint,
            salt,
            grace_period,
            authorized_signer,
            signature,
        )

    @classmethod
    def payment_channel_with_mode(
        cls,
        mode: str,
        channel_id: str,
        deposit: str,
        payer: str,
        payee: str,
        mint: str,
        salt: int,
        grace_period: int,
        authorized_signer: str,
        signature: str,
    ) -> OpenPayload:
        return cls(
            mode=mode,
            authorized_signer=authorized_signer,
            signature=signature,
            channel_id=channel_id,
            deposit=deposit,
            payer=payer,
            payee=payee,
            mint=mint,
            salt=salt,
            grace_period=grace_period,
        )

    @classmethod
    def pull(
        cls,
        token_account: str,
        approved_amount: str,
        owner: str,
        authorized_signer: str,
        signature: str,
    ) -> OpenPayload:
        return cls(
            mode=SESSION_MODE_PULL,
            authorized_signer=authorized_signer,
            signature=signature,
            token_account=token_account,
            approved_amount=approved_amount,
            owner=owner,
        )

    def with_transaction(self, tx_base64: str) -> OpenPayload:
        self.transaction = tx_base64
        return self

    def with_init_tx(self, tx_base64: str) -> OpenPayload:
        self.init_multi_delegate_tx = tx_base64
        return self

    def with_update_tx(self, tx_base64: str) -> OpenPayload:
        self.update_delegation_tx = tx_base64
        return self

    def session_id(self) -> str:
        """Session identifier used as the store key.

        Push: ``channel_id``. Operated-voucher pull: ``token_account``.
        """
        if self.channel_id is not None:
            return self.channel_id
        if self.mode == SESSION_MODE_PULL and self.token_account is not None:
            return self.token_account
        if self.mode == SESSION_MODE_PUSH:
            raise ValueError("push open missing channelId")
        raise ValueError("pull open missing channelId or tokenAccount")

    def deposit_amount(self) -> int:
        """Deposit / approved amount for this open (base units)."""
        raw = self.deposit
        if raw is None:
            if self.mode == SESSION_MODE_PUSH:
                raise ValueError("push open missing deposit")
            raw = self.approved_amount
            if raw is None:
                raise ValueError("pull open missing deposit or approvedAmount")
        try:
            return int(raw)
        except ValueError as exc:
            raise ValueError(f"invalid deposit amount: {raw}") from exc

    def to_dict(self) -> dict[str, Any]:
        d: dict[str, Any] = {"mode": self.mode}
        if self.channel_id is not None:
            d["channelId"] = self.channel_id
        if self.deposit is not None:
            d["deposit"] = self.deposit
        if self.payer is not None:
            d["payer"] = self.payer
        if self.payee is not None:
            d["payee"] = self.payee
        if self.mint is not None:
            d["mint"] = self.mint
        salt_wire = _salt_to_wire(self.salt)
        if salt_wire is not None:
            d["salt"] = salt_wire
        if self.grace_period is not None:
            d["gracePeriod"] = self.grace_period
        if self.transaction is not None:
            d["transaction"] = self.transaction
        if self.token_account is not None:
            d["tokenAccount"] = self.token_account
        if self.approved_amount is not None:
            d["approvedAmount"] = self.approved_amount
        if self.owner is not None:
            d["owner"] = self.owner
        if self.init_multi_delegate_tx is not None:
            d["initMultiDelegateTx"] = self.init_multi_delegate_tx
        if self.update_delegation_tx is not None:
            d["updateDelegationTx"] = self.update_delegation_tx
        d["authorizedSigner"] = self.authorized_signer
        d["signature"] = self.signature
        return d

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> OpenPayload:
        if "mode" not in data:
            # Clients must always send "mode" -- no default. Mirrors the Rust
            # spine's missing-mode deserialization rejection.
            raise ValueError("open payload missing mode")
        return cls(
            mode=data["mode"],
            authorized_signer=data["authorizedSigner"],
            signature=data["signature"],
            channel_id=data.get("channelId"),
            deposit=data.get("deposit"),
            payer=data.get("payer"),
            payee=data.get("payee"),
            mint=data.get("mint"),
            salt=_salt_from_wire(data.get("salt")),
            grace_period=data.get("gracePeriod"),
            transaction=data.get("transaction"),
            token_account=data.get("tokenAccount"),
            approved_amount=data.get("approvedAmount"),
            owner=data.get("owner"),
            init_multi_delegate_tx=data.get("initMultiDelegateTx"),
            update_delegation_tx=data.get("updateDelegationTx"),
        )


@dataclass
class VoucherPayload:
    """Payload for the ``voucher`` action (per-request micropayment)."""

    voucher: SignedVoucher

    def to_dict(self) -> dict[str, Any]:
        return {"voucher": self.voucher.to_dict()}

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> VoucherPayload:
        return cls(voucher=SignedVoucher.from_dict(data["voucher"]))


@dataclass
class CommitPayload:
    """Payload for the ``commit`` action."""

    delivery_id: str
    voucher: SignedVoucher

    def to_dict(self) -> dict[str, Any]:
        return {"deliveryId": self.delivery_id, "voucher": self.voucher.to_dict()}

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> CommitPayload:
        return cls(delivery_id=data["deliveryId"], voucher=SignedVoucher.from_dict(data["voucher"]))


@dataclass
class TopUpPayload:
    """Payload for the ``topup`` action."""

    channel_id: str
    new_deposit: str
    signature: str

    def to_dict(self) -> dict[str, Any]:
        return {
            "channelId": self.channel_id,
            "newDeposit": self.new_deposit,
            "signature": self.signature,
        }

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> TopUpPayload:
        return cls(
            channel_id=data["channelId"],
            new_deposit=data["newDeposit"],
            signature=data["signature"],
        )


@dataclass
class ClosePayload:
    """Payload for the ``close`` action."""

    channel_id: str
    voucher: SignedVoucher | None = None

    def to_dict(self) -> dict[str, Any]:
        d: dict[str, Any] = {"channelId": self.channel_id}
        if self.voucher is not None:
            d["voucher"] = self.voucher.to_dict()
        return d

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> ClosePayload:
        voucher = data.get("voucher")
        return cls(
            channel_id=data["channelId"],
            voucher=SignedVoucher.from_dict(voucher) if voucher is not None else None,
        )


# Discriminated action tag <-> dataclass mapping. The wire tag is ``action``;
# ``topup`` serializes as ``topUp`` (capital U) to match the Rust spine.
_ACTION_TAGS: dict[type, str] = {
    OpenPayload: "open",
    VoucherPayload: "voucher",
    CommitPayload: "commit",
    TopUpPayload: "topUp",
    ClosePayload: "close",
}


SessionActionPayload = OpenPayload | VoucherPayload | CommitPayload | TopUpPayload | ClosePayload


def session_action_to_dict(payload: SessionActionPayload) -> dict[str, Any]:
    """Serialize a session action as a tagged object (``{"action": ..., ...}``)."""
    tag = _ACTION_TAGS[type(payload)]
    return {"action": tag, **payload.to_dict()}


def session_action_from_dict(data: dict[str, Any]) -> SessionActionPayload:
    """Parse a tagged session action object into its payload dataclass."""
    action = data.get("action")
    if action == "open":
        return OpenPayload.from_dict(data)
    if action == "voucher":
        return VoucherPayload.from_dict(data)
    if action == "commit":
        return CommitPayload.from_dict(data)
    if action == "topUp":
        return TopUpPayload.from_dict(data)
    if action == "close":
        return ClosePayload.from_dict(data)
    raise ValueError(f"unknown session action: {action!r}")


@dataclass
class MeteringDirective:
    """Server-issued metering directive attached to a delivered response."""

    delivery_id: str
    session_id: str
    amount: str
    currency: str
    sequence: int
    expires_at: int
    commit_url: str | None = None
    proof: str | None = None

    def amount_base_units(self) -> int:
        try:
            return int(self.amount)
        except ValueError as exc:
            raise ValueError(f"invalid metering amount: {self.amount}") from exc

    def to_dict(self) -> dict[str, Any]:
        d: dict[str, Any] = {
            "deliveryId": self.delivery_id,
            "sessionId": self.session_id,
            "amount": self.amount,
            "currency": self.currency,
            "sequence": self.sequence,
            "expiresAt": self.expires_at,
        }
        if self.commit_url is not None:
            d["commitUrl"] = self.commit_url
        if self.proof is not None:
            d["proof"] = self.proof
        return d

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> MeteringDirective:
        return cls(
            delivery_id=data["deliveryId"],
            session_id=data["sessionId"],
            amount=data["amount"],
            currency=data["currency"],
            sequence=int(data["sequence"]),
            expires_at=int(data["expiresAt"]),
            commit_url=data.get("commitUrl"),
            proof=data.get("proof"),
        )


@dataclass
class MeteringUsage:
    """Final usage reported by a streaming response."""

    delivery_id: str
    amount: str

    def amount_base_units(self) -> int:
        try:
            return int(self.amount)
        except ValueError as exc:
            raise ValueError(f"invalid metering usage amount: {self.amount}") from exc

    def to_dict(self) -> dict[str, Any]:
        return {"deliveryId": self.delivery_id, "amount": self.amount}

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> MeteringUsage:
        return cls(delivery_id=data["deliveryId"], amount=data["amount"])


@dataclass
class MeteredEnvelope:
    """A payload paired with the metering directive required to acknowledge it."""

    payload: Any
    metering: MeteringDirective

    def to_dict(self) -> dict[str, Any]:
        return {"payload": self.payload, "metering": self.metering.to_dict()}

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> MeteredEnvelope:
        return cls(payload=data.get("payload"), metering=MeteringDirective.from_dict(data["metering"]))


@dataclass
class CommitReceipt:
    """Result returned after a delivery commit is accepted."""

    delivery_id: str
    session_id: str
    amount: str
    cumulative: str
    status: str

    def to_dict(self) -> dict[str, Any]:
        return {
            "deliveryId": self.delivery_id,
            "sessionId": self.session_id,
            "amount": self.amount,
            "cumulative": self.cumulative,
            "status": self.status,
        }

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> CommitReceipt:
        return cls(
            delivery_id=data["deliveryId"],
            session_id=data["sessionId"],
            amount=data["amount"],
            cumulative=data["cumulative"],
            status=data["status"],
        )
