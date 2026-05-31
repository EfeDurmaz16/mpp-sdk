"""Kafka-style client helpers for metered session deliveries.

:class:`SessionConsumer` wraps :class:`~solana_mpp.client.session.ActiveSession`
so applications can process delivered messages and call ``ack``/``commit``
instead of manually signing and posting vouchers.

Mirrors the Rust spine at ``rust/crates/mpp/src/client/session_consumer.rs``.

A ``CommitTransport`` is any object exposing an async
``commit(directive, payload) -> CommitReceipt`` coroutine. HTTP clients,
queues, and in-process tests can all implement it. The directive is passed
alongside the payload so transports can use ``commit_url`` / ``proof`` routing
hints without those fields being repeated in the signed commit body.
"""

from __future__ import annotations

from typing import Any, Protocol, runtime_checkable

from solana_mpp.client.session import ActiveSession
from solana_mpp.protocol.session import (
    CommitPayload,
    CommitReceipt,
    MeteredEnvelope,
    MeteringDirective,
)


@runtime_checkable
class CommitTransport(Protocol):
    """Transport used by :class:`SessionConsumer` to send commit payloads."""

    async def commit(self, directive: MeteringDirective, payload: CommitPayload) -> CommitReceipt: ...


class SessionConsumer:
    """Client-side consumer for session-metered deliveries."""

    def __init__(self, session: ActiveSession, transport: CommitTransport) -> None:
        self._session = session
        self._transport = transport

    @property
    def session(self) -> ActiveSession:
        return self._session

    def accept(self, envelope: MeteredEnvelope) -> MeteredDelivery:
        """Accept an envelope and return a delivery handle with ``ack``/``commit``."""
        self._validate_directive(envelope.metering)
        return MeteredDelivery(self, envelope.payload, envelope.metering)

    async def commit_directive(self, directive: MeteringDirective) -> CommitReceipt:
        """Commit a directive directly, without a delivery handle.

        On a transport failure the local watermark is NOT advanced, so the
        same directive can be retried with an identical cumulative.
        """
        self._validate_directive(directive)
        amount = directive.amount_base_units()
        if amount == 0:
            raise ValueError("metered delivery amount must be greater than zero")

        voucher = self._session.prepare_increment(amount)
        payload = CommitPayload(delivery_id=directive.delivery_id, voucher=voucher)

        receipt = await self._transport.commit(directive, payload)
        self._session.record_voucher(payload.voucher)
        return receipt

    def _validate_directive(self, directive: MeteringDirective) -> None:
        channel_id = self._session.channel_id_str()
        if directive.session_id != channel_id:
            raise ValueError(
                f"metered delivery session {directive.session_id} does not match active session {channel_id}"
            )


class MeteredDelivery:
    """A delivered payload plus its metering directive."""

    def __init__(self, consumer: SessionConsumer, payload: Any, metering: MeteringDirective) -> None:
        self._consumer = consumer
        self._payload = payload
        self._metering = metering

    @property
    def payload(self) -> Any:
        return self._payload

    @property
    def metering(self) -> MeteringDirective:
        return self._metering

    async def ack(self) -> CommitReceipt:
        """Commit this delivery after the application has processed the payload."""
        return await self._consumer.commit_directive(self._metering)

    async def commit(self) -> CommitReceipt:
        """Alias for :meth:`ack`."""
        return await self.ack()

    def into_parts(self) -> tuple[Any, MeteringDirective]:
        return self._payload, self._metering
