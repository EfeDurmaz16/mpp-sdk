"""Server-side session intent.

Challenge issuance, voucher verification, and channel lifecycle management.
Mirrors the Rust spine at ``rust/crates/mpp/src/server/session.rs``.

Lifecycle:

1. :meth:`SessionServer.build_challenge_request` produces the ``SessionRequest``
   embedded in a 402 challenge.
2. Client responds with an open action; :meth:`SessionServer.process_open`
   records the channel.
3. For each subsequent call the client attaches a voucher;
   :meth:`SessionServer.verify_voucher` validates and advances the settled
   watermark atomically.
4. For metered streams, :meth:`SessionServer.begin_delivery` reserves capacity
   and :meth:`SessionServer.process_commit` records an idempotent commit.
5. :meth:`SessionServer.process_topup` raises the deposit cap.
6. :meth:`SessionServer.process_close` accepts a final voucher and returns the
   parameters needed for on-chain settlement.

The session server tracks lifecycle state, so it uses the richer
:class:`~solana_mpp.channel_store.ChannelStore`, not the charge replay store.
"""

from __future__ import annotations

import time
from dataclasses import dataclass, field

from solana_mpp.channel_store import (
    ChannelState,
    ChannelStore,
    CommittedDelivery,
    PendingDelivery,
)
from solana_mpp.protocol.payment_channels import (
    Distribution,
    OpenChannelParams,
    default_program_id,
    derive_channel_addresses,
    distribution_hash,
)
from solana_mpp.protocol.session import (
    COMMIT_STATUS_COMMITTED,
    COMMIT_STATUS_REPLAYED,
    DEFAULT_SESSION_EXPIRES_AT,
    SESSION_MODE_PULL,
    SESSION_MODE_PUSH,
    ClosePayload,
    CommitPayload,
    CommitReceipt,
    MeteringDirective,
    OpenPayload,
    SessionRequest,
    SessionSplit,
    SignedVoucher,
    TopUpPayload,
    VoucherPayload,
)
from solana_mpp.protocol.solana import (
    default_token_program_for_currency,
    resolve_mint,
    stablecoin_symbol,
)


@dataclass
class Split:
    """A payment split committed at channel open, distributed at close."""

    recipient: str
    bps: int


@dataclass
class SessionConfig:
    """Server configuration for the session intent."""

    operator: str = ""
    recipient: str = ""
    splits: list[Split] = field(default_factory=list)
    max_cap: int = 10_000_000  # 10 USDC
    currency: str = "USDC"
    decimals: int = 6
    network: str = "mainnet"
    program_id: str | None = None
    min_voucher_delta: int = 0
    modes: list[str] = field(default_factory=lambda: [SESSION_MODE_PUSH])
    pull_voucher_strategy: str | None = None


@dataclass
class DeliveryRequest:
    """Request to reserve a metered delivery for client-side ack/commit."""

    session_id: str
    amount: int
    delivery_id: str | None = None
    commit_url: str | None = None
    proof: str | None = None
    expires_at: int | None = None


@dataclass
class FinalizeParams:
    """Parameters needed to submit a finalize + distribute transaction pair."""

    channel_id: str
    authorized_signer: str | None
    payer: str | None
    mint: str | None
    program_id: str
    settled: int
    voucher_signature: str | None
    voucher_expires_at: int | None
    recipient: str
    splits: list[Split]
    distribution_hash: bytes


def _now_secs() -> int:
    return int(time.time())


def _expected_payment_channel_mint(config: SessionConfig) -> str:
    """Resolve the SPL mint expected for a payment-channel session.

    Mirrors the Rust spine ``resolve_stablecoin_mint``; raises if the currency
    is not an SPL token (e.g. native SOL).
    """
    symbol = stablecoin_symbol(config.currency)
    if symbol is None:
        raise ValueError("payment-channel sessions require an SPL token")
    mint = resolve_mint(config.currency, config.network)
    if not mint:
        raise ValueError("payment-channel sessions require an SPL token")
    return mint


def _verify_signature(voucher: SignedVoucher, authorized_signer: str) -> None:
    """Verify an Ed25519 voucher signature against the authorized signer.

    Validates expiry, then verifies the signature over the on-chain voucher
    bytes. Raises :class:`ValueError` on any failure.
    """
    from solders.pubkey import Pubkey
    from solders.signature import Signature

    if voucher.data.expires_at <= _now_secs():
        raise ValueError("Voucher has expired")

    message = voucher.data.message_bytes()
    try:
        signer_key = Pubkey.from_string(authorized_signer)
    except Exception as exc:  # noqa: BLE001
        raise ValueError(f"Invalid authorized_signer: {exc}") from exc
    try:
        signature = Signature.from_string(voucher.signature)
    except Exception as exc:  # noqa: BLE001
        raise ValueError(f"Invalid signature encoding: {exc}") from exc

    if not signature.verify(signer_key, message):
        raise ValueError("Voucher signature verification failed")


class SessionServer:
    """Server-side session manager backed by a :class:`ChannelStore`."""

    def __init__(self, config: SessionConfig, store: ChannelStore) -> None:
        self._config = config
        self._store = store

    @property
    def store(self) -> ChannelStore:
        return self._store

    def build_challenge_request(self, cap: int) -> SessionRequest:
        """Build the ``SessionRequest`` to embed in a 402 challenge.

        ``cap`` is clamped to ``config.max_cap``.
        """
        config = self._config
        effective_cap = min(cap, config.max_cap)
        # Omit modes if only push -- clients assume push when modes is absent.
        modes = [] if config.modes == [SESSION_MODE_PUSH] else list(config.modes)
        pull_strategy = config.pull_voucher_strategy if SESSION_MODE_PULL in config.modes else None
        return SessionRequest(
            cap=str(effective_cap),
            currency=config.currency,
            operator=config.operator,
            recipient=config.recipient,
            decimals=config.decimals,
            network=config.network,
            splits=[SessionSplit(recipient=s.recipient, bps=s.bps) for s in config.splits],
            program_id=config.program_id,
            min_voucher_delta=str(config.min_voucher_delta) if config.min_voucher_delta > 0 else None,
            modes=modes,
            pull_voucher_strategy=pull_strategy,
        )

    def payment_channel_open_params(self, payload: OpenPayload) -> OpenChannelParams:
        """Validate a payment-channel open payload against the challenge.

        Verifies payee/mint match the challenge, derives the channel PDA, and
        confirms it matches ``payload.channel_id``. Returns the exact on-chain
        open params expected by the payment-channels program.
        """
        config = self._config

        def _require(value: str | None, field_name: str) -> str:
            if value is None:
                raise ValueError(f"payment-channel open missing {field_name}")
            return value

        payer = _require(payload.payer, "payer")
        payee = _require(payload.payee, "payee")
        mint = _require(payload.mint, "mint")
        if payload.salt is None:
            raise ValueError("payment-channel open missing salt")
        if payload.grace_period is None:
            raise ValueError("payment-channel open missing gracePeriod")
        authorized_signer = payload.authorized_signer
        deposit = payload.deposit_amount()
        token_program = default_token_program_for_currency(config.currency, config.network)
        program_id = config.program_id or default_program_id()
        expected_mint = _expected_payment_channel_mint(config)

        # Validate base58 pubkey shape on authorizedSigner so a bad value
        # fails here rather than at PDA derivation.
        from solders.pubkey import Pubkey

        try:
            Pubkey.from_string(authorized_signer)
        except Exception as exc:  # noqa: BLE001
            raise ValueError(f"invalid payment-channel authorizedSigner: {exc}") from exc

        if payee != config.recipient:
            raise ValueError("payment-channel open payee does not match challenge recipient")
        if mint != expected_mint:
            raise ValueError("payment-channel open mint does not match challenge currency")

        recipients = [Distribution(recipient=s.recipient, bps=s.bps) for s in config.splits]
        params = OpenChannelParams(
            payer=payer,
            payee=payee,
            mint=mint,
            authorized_signer=authorized_signer,
            salt=payload.salt,
            deposit=deposit,
            grace_period=payload.grace_period,
            token_program=token_program,
            recipients=recipients,
            program_id=program_id,
        )

        expected_channel = derive_channel_addresses(params).channel
        if payload.channel_id != expected_channel:
            raise ValueError("payment-channel open channelId does not match derived channel PDA")
        return params

    async def process_open(self, payload: OpenPayload) -> ChannelState:
        """Process an open action and persist the channel state."""
        config = self._config
        supports = payload.mode == SESSION_MODE_PUSH if not config.modes else payload.mode in config.modes
        if not supports:
            raise ValueError(f"Session mode {payload.mode} is not supported by this challenge")

        session_id = payload.session_id()
        deposit = payload.deposit_amount()
        if deposit == 0:
            raise ValueError("Deposit must be greater than zero")
        if deposit > config.max_cap:
            raise ValueError(f"Deposit {deposit} exceeds max cap {config.max_cap}")

        operator = payload.owner if payload.owner is not None else payload.payer
        state = ChannelState(
            channel_id=session_id,
            authorized_signer=payload.authorized_signer,
            deposit=deposit,
            operator=operator,
        )
        await self._store.put_channel(session_id, state)
        return state

    async def verify_voucher(self, payload: VoucherPayload) -> int:
        """Verify a voucher, advance the watermark, and return the new cumulative.

        Rejects vouchers for unknown channels, non-increasing cumulatives
        (unless exact idempotent replay), cumulatives over the deposit, invalid
        signatures, below-minimum deltas, and post-close submissions. Uses an
        atomic read-modify-write to prevent double-spend under concurrency.
        """
        voucher = payload.voucher
        channel_id = voucher.data.channel_id
        try:
            new_cumulative = int(voucher.data.cumulative)
        except ValueError as exc:
            raise ValueError("Invalid cumulative in voucher") from exc

        state = await self._store.get_channel(channel_id)
        if state is None:
            raise ValueError(f"Channel {channel_id} not found")
        if state.finalized:
            raise ValueError("Channel is already finalized")
        if state.close_requested_at is not None:
            raise ValueError("Channel close is pending -- no further vouchers accepted")

        # Idempotent replay: same cumulative AND same signature.
        if new_cumulative == state.cumulative and state.highest_voucher_signature == voucher.signature:
            _verify_signature(voucher, state.authorized_signer)
            return new_cumulative

        if new_cumulative <= state.cumulative:
            raise ValueError(f"Voucher cumulative {new_cumulative} must exceed watermark {state.cumulative}")
        if new_cumulative > state.deposit:
            raise ValueError(f"Voucher cumulative {new_cumulative} exceeds deposit {state.deposit}")

        delta = new_cumulative - state.cumulative
        min_delta = self._config.min_voucher_delta
        if min_delta > 0 and delta < min_delta:
            raise ValueError(f"Voucher delta {delta} is below minimum {min_delta}")

        # Verify the signature before touching the store.
        _verify_signature(voucher, state.authorized_signer)

        sig = voucher.signature
        expires_at = voucher.data.expires_at

        def _update(current: ChannelState | None) -> ChannelState:
            if current is None:
                raise ValueError("Channel not found")
            if current.finalized:
                raise ValueError("Channel is already finalized")
            if current.close_requested_at is not None:
                raise ValueError("Channel close is pending -- no further vouchers accepted")
            if new_cumulative == current.cumulative and current.highest_voucher_signature == sig:
                return current
            if new_cumulative <= current.cumulative:
                raise ValueError("Concurrent update: watermark advanced")
            current.cumulative = new_cumulative
            current.highest_voucher_signature = sig
            current.highest_voucher_expires_at = expires_at
            return current

        new_state = await self._store.update_channel(channel_id, _update)
        return new_state.cumulative

    async def process_topup(self, payload: TopUpPayload) -> ChannelState:
        """Process a topup action: atomically raise the channel's deposit cap."""
        try:
            new_deposit = int(payload.new_deposit)
        except ValueError as exc:
            raise ValueError("Invalid new_deposit") from exc
        max_cap = self._config.max_cap
        channel_id = payload.channel_id

        def _update(current: ChannelState | None) -> ChannelState:
            if current is None:
                raise ValueError(f"Channel {channel_id} not found")
            if new_deposit <= current.deposit:
                raise ValueError(f"New deposit {new_deposit} must exceed current deposit {current.deposit}")
            if new_deposit > max_cap:
                raise ValueError(f"New deposit {new_deposit} exceeds max cap {max_cap}")
            current.deposit = new_deposit
            return current

        return await self._store.update_channel(channel_id, _update)

    async def begin_delivery(self, request: DeliveryRequest) -> MeteringDirective:
        """Reserve capacity for a delivery and return its metering directive."""
        if request.amount == 0:
            raise ValueError("Delivery amount must be greater than zero")

        config = self._config
        session_id = request.session_id
        amount = request.amount
        expires_at = request.expires_at if request.expires_at is not None else DEFAULT_SESSION_EXPIRES_AT
        requested_delivery_id = request.delivery_id
        directive_out: list[MeteringDirective] = []

        def _update(current: ChannelState | None) -> ChannelState:
            if current is None:
                raise ValueError(f"Channel {session_id} not found")
            if current.finalized:
                raise ValueError("Channel is already finalized")
            if current.close_requested_at is not None:
                raise ValueError("Channel close is pending -- no further deliveries accepted")
            pending_total = sum(d.amount for d in current.pending_deliveries)
            if current.cumulative + pending_total + amount > current.deposit:
                raise ValueError(f"Delivery amount {amount} exceeds available deposit")

            sequence = current.next_delivery_sequence + 1
            delivery_id = requested_delivery_id or f"{session_id}:{sequence}"
            if any(d.delivery_id == delivery_id for d in current.pending_deliveries) or any(
                d.delivery_id == delivery_id for d in current.committed_deliveries
            ):
                raise ValueError(f"Delivery {delivery_id} already exists")

            current.next_delivery_sequence = sequence
            current.pending_deliveries.append(
                PendingDelivery(delivery_id=delivery_id, amount=amount, sequence=sequence, expires_at=expires_at)
            )
            directive_out.append(
                MeteringDirective(
                    delivery_id=delivery_id,
                    session_id=session_id,
                    amount=str(amount),
                    currency=config.currency,
                    sequence=sequence,
                    expires_at=expires_at,
                    commit_url=request.commit_url,
                    proof=request.proof,
                )
            )
            return current

        await self._store.update_channel(session_id, _update)
        if not directive_out:
            raise ValueError("Delivery reservation did not produce directive")
        return directive_out[0]

    async def process_commit(self, payload: CommitPayload) -> CommitReceipt:
        """Commit a reserved delivery by verifying its voucher.

        Idempotent on ``deliveryId``: a duplicate commit for the same delivery
        returns a ``replayed`` receipt with the cached values rather than a new
        settlement.
        """
        channel_id = payload.voucher.data.channel_id
        try:
            new_cumulative = int(payload.voucher.data.cumulative)
        except ValueError as exc:
            raise ValueError("Invalid cumulative in commit voucher") from exc

        state = await self._store.get_channel(channel_id)
        if state is None:
            raise ValueError(f"Channel {channel_id} not found")

        existing = next((d for d in state.committed_deliveries if d.delivery_id == payload.delivery_id), None)
        if existing is not None:
            if existing.cumulative == new_cumulative and existing.voucher_signature == payload.voucher.signature:
                _verify_signature(payload.voucher, state.authorized_signer)
                return CommitReceipt(
                    delivery_id=payload.delivery_id,
                    session_id=channel_id,
                    amount=str(existing.amount),
                    cumulative=str(existing.cumulative),
                    status=COMMIT_STATUS_REPLAYED,
                )
            raise ValueError(f"Delivery {payload.delivery_id} was already committed with different voucher")

        pending = next((d for d in state.pending_deliveries if d.delivery_id == payload.delivery_id), None)
        if pending is None:
            raise ValueError(f"Delivery {payload.delivery_id} not found")
        now = _now_secs()
        if pending.expires_at <= now:
            raise ValueError(f"Delivery {payload.delivery_id} has expired")
        if new_cumulative <= state.cumulative:
            raise ValueError(f"Commit cumulative {new_cumulative} must exceed watermark {state.cumulative}")
        _verify_signature(payload.voucher, state.authorized_signer)

        delivery_id = payload.delivery_id
        signature = payload.voucher.signature
        expires_at = payload.voucher.data.expires_at
        outcome: list[tuple[int, int, str]] = []

        def _update(current: ChannelState | None) -> ChannelState:
            if current is None:
                raise ValueError(f"Channel {channel_id} not found")
            if current.finalized:
                raise ValueError("Channel is already finalized")
            if current.close_requested_at is not None:
                raise ValueError("Channel close is pending -- no further commits accepted")
            committed = next((d for d in current.committed_deliveries if d.delivery_id == delivery_id), None)
            if committed is not None:
                if committed.cumulative == new_cumulative and committed.voucher_signature == signature:
                    outcome.append((committed.amount, committed.cumulative, COMMIT_STATUS_REPLAYED))
                    return current
                raise ValueError(f"Delivery {delivery_id} was already committed with different voucher")
            pending_idx = next(
                (i for i, d in enumerate(current.pending_deliveries) if d.delivery_id == delivery_id), -1
            )
            if pending_idx == -1:
                raise ValueError(f"Delivery {delivery_id} not found")
            reserved = current.pending_deliveries[pending_idx]
            if reserved.expires_at <= now:
                raise ValueError(f"Delivery {delivery_id} has expired")
            if new_cumulative <= current.cumulative:
                raise ValueError(f"Commit cumulative {new_cumulative} must exceed watermark {current.cumulative}")
            actual_amount = new_cumulative - current.cumulative
            if actual_amount > reserved.amount:
                raise ValueError(f"Commit amount {actual_amount} exceeds reserved amount {reserved.amount}")

            current.pending_deliveries.pop(pending_idx)
            current.cumulative = new_cumulative
            current.highest_voucher_signature = signature
            current.highest_voucher_expires_at = expires_at
            current.committed_deliveries.append(
                CommittedDelivery(
                    delivery_id=delivery_id,
                    amount=actual_amount,
                    cumulative=new_cumulative,
                    voucher_signature=signature,
                )
            )
            outcome.append((actual_amount, new_cumulative, COMMIT_STATUS_COMMITTED))
            return current

        await self._store.update_channel(channel_id, _update)
        if not outcome:
            raise ValueError("Commit did not produce a receipt")
        amount, cumulative, status = outcome[0]
        return CommitReceipt(
            delivery_id=payload.delivery_id,
            session_id=channel_id,
            amount=str(amount),
            cumulative=str(cumulative),
            status=status,
        )

    async def process_close(self, payload: ClosePayload) -> FinalizeParams:
        """Process a close action: set close-pending, accept a final voucher,
        and return the parameters needed for on-chain settlement.
        """
        now = _now_secs()
        voucher = payload.voucher

        def _update(current: ChannelState | None) -> ChannelState:
            if current is None:
                raise ValueError("Channel not found")
            if current.finalized:
                raise ValueError("Channel is already finalized")
            if current.close_requested_at is not None:
                raise ValueError("Close already requested")

            if voucher is not None:
                try:
                    cumulative = int(voucher.data.cumulative)
                except ValueError as exc:
                    raise ValueError("Invalid cumulative") from exc
                if cumulative <= current.cumulative:
                    # Idempotent replay check.
                    if cumulative == current.cumulative and current.highest_voucher_signature == voucher.signature:
                        if current.highest_voucher_expires_at is None:
                            current.highest_voucher_expires_at = voucher.data.expires_at
                    else:
                        raise ValueError(
                            f"Final voucher cumulative {cumulative} must exceed watermark {current.cumulative}"
                        )
                else:
                    if cumulative > current.deposit:
                        raise ValueError("Final voucher exceeds deposit")
                    _verify_signature(voucher, current.authorized_signer)
                    current.cumulative = cumulative
                    current.highest_voucher_signature = voucher.signature
                    current.highest_voucher_expires_at = voucher.data.expires_at

            current.close_requested_at = now
            return current

        await self._store.update_channel(payload.channel_id, _update)
        return await self.finalize_params(payload.channel_id)

    async def finalize_params(self, channel_id: str) -> FinalizeParams:
        """Return finalize parameters for a channel ready for settlement."""
        config = self._config
        state = await self._store.get_channel(channel_id)
        if state is None:
            raise ValueError(f"Channel {channel_id} not found")

        try:
            mint: str | None = _expected_payment_channel_mint(config)
        except ValueError:
            mint = None

        program_id = config.program_id or default_program_id()
        recipients = [Distribution(recipient=s.recipient, bps=s.bps) for s in config.splits]

        return FinalizeParams(
            channel_id=channel_id,
            authorized_signer=state.authorized_signer or None,
            payer=state.operator,
            mint=mint,
            program_id=program_id,
            settled=state.cumulative,
            voucher_signature=state.highest_voucher_signature,
            voucher_expires_at=state.highest_voucher_expires_at,
            recipient=config.recipient,
            splits=list(config.splits),
            distribution_hash=distribution_hash(recipients),
        )

    async def mark_finalized(self, channel_id: str) -> None:
        """Mark a channel as finalized (after the on-chain finalize tx confirms)."""
        await self._store.mark_finalized(channel_id)
