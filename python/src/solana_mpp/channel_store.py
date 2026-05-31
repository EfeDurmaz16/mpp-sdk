"""Richer channel store for the session intent.

Unlike the charge replay :class:`~solana_mpp.store.Store` (a flat consumed-key
set), the session server tracks live channel lifecycle state and advances a
settled watermark under concurrent vouchers. This needs an atomic
read-modify-write store, mirroring the Rust spine ``ChannelStore`` /
``MemoryChannelStore`` at ``rust/crates/mpp/src/store.rs``.

The ``update_channel`` method runs the caller's updater closure inside the
store lock so the entire read-modify-write is atomic and no concurrent voucher
can interleave a double-spend.
"""

from __future__ import annotations

import asyncio
from collections.abc import Callable
from dataclasses import dataclass, field
from typing import Any, Protocol, runtime_checkable


@dataclass
class PendingDelivery:
    """A delivery reserved by the server but not yet committed by the client."""

    delivery_id: str
    amount: int
    sequence: int
    expires_at: int

    def to_dict(self) -> dict[str, Any]:
        return {
            "deliveryId": self.delivery_id,
            "amount": self.amount,
            "sequence": self.sequence,
            "expiresAt": self.expires_at,
        }

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> PendingDelivery:
        return cls(
            delivery_id=data["deliveryId"],
            amount=int(data["amount"]),
            sequence=int(data["sequence"]),
            expires_at=int(data["expiresAt"]),
        )


@dataclass
class CommittedDelivery:
    """A committed delivery, kept for idempotent commit replay."""

    delivery_id: str
    amount: int
    cumulative: int
    voucher_signature: str

    def to_dict(self) -> dict[str, Any]:
        return {
            "deliveryId": self.delivery_id,
            "amount": self.amount,
            "cumulative": self.cumulative,
            "voucherSignature": self.voucher_signature,
        }

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> CommittedDelivery:
        return cls(
            delivery_id=data["deliveryId"],
            amount=int(data["amount"]),
            cumulative=int(data["cumulative"]),
            voucher_signature=data["voucherSignature"],
        )


@dataclass
class ChannelState:
    """Persisted state of a payment channel, managed by the server."""

    channel_id: str
    authorized_signer: str
    deposit: int
    cumulative: int = 0
    finalized: bool = False
    highest_voucher_signature: str | None = None
    highest_voucher_expires_at: int | None = None
    close_requested_at: int | None = None
    operator: str | None = None
    next_delivery_sequence: int = 0
    pending_deliveries: list[PendingDelivery] = field(default_factory=list)
    committed_deliveries: list[CommittedDelivery] = field(default_factory=list)

    def clone(self) -> ChannelState:
        """Return a deep copy so updater closures cannot mutate stored state."""
        return ChannelState(
            channel_id=self.channel_id,
            authorized_signer=self.authorized_signer,
            deposit=self.deposit,
            cumulative=self.cumulative,
            finalized=self.finalized,
            highest_voucher_signature=self.highest_voucher_signature,
            highest_voucher_expires_at=self.highest_voucher_expires_at,
            close_requested_at=self.close_requested_at,
            operator=self.operator,
            next_delivery_sequence=self.next_delivery_sequence,
            pending_deliveries=[
                PendingDelivery(d.delivery_id, d.amount, d.sequence, d.expires_at) for d in self.pending_deliveries
            ],
            committed_deliveries=[
                CommittedDelivery(d.delivery_id, d.amount, d.cumulative, d.voucher_signature)
                for d in self.committed_deliveries
            ],
        )


@runtime_checkable
class ChannelStore(Protocol):
    """Async store for channel state with atomic watermark advancement.

    Implementations MUST guarantee that ``update_channel`` is atomic to
    prevent double-spend under concurrent requests.
    """

    async def get_channel(self, channel_id: str) -> ChannelState | None: ...

    async def put_channel(self, channel_id: str, state: ChannelState) -> None: ...

    async def update_channel(
        self,
        channel_id: str,
        updater: Callable[[ChannelState | None], ChannelState],
    ) -> ChannelState: ...

    async def mark_finalized(self, channel_id: str) -> None: ...


class MemoryChannelStore:
    """In-memory channel store backed by an asyncio lock.

    The ``update_channel`` method holds the lock across the read, the updater
    call, and the write, so the entire read-modify-write is atomic.
    """

    def __init__(self) -> None:
        self._data: dict[str, ChannelState] = {}
        self._lock = asyncio.Lock()

    async def get_channel(self, channel_id: str) -> ChannelState | None:
        state = self._data.get(channel_id)
        return state.clone() if state is not None else None

    async def put_channel(self, channel_id: str, state: ChannelState) -> None:
        async with self._lock:
            self._data[channel_id] = state.clone()

    async def update_channel(
        self,
        channel_id: str,
        updater: Callable[[ChannelState | None], ChannelState],
    ) -> ChannelState:
        async with self._lock:
            current = self._data.get(channel_id)
            # Hand the updater a clone so a raising updater cannot leave the
            # stored state partially mutated.
            new_state = updater(current.clone() if current is not None else None)
            self._data[channel_id] = new_state.clone()
            return new_state.clone()

    async def mark_finalized(self, channel_id: str) -> None:
        async with self._lock:
            state = self._data.get(channel_id)
            if state is None:
                raise KeyError(f"Channel {channel_id} not found")
            state.finalized = True
