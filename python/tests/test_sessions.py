"""Tests for Solana session protocol schema helpers."""

from __future__ import annotations

import pytest

from solana_mpp.protocol.sessions import (
    CommitReceipt,
    MeteringDirective,
    SessionMode,
    SessionPullVoucherStrategy,
    SessionRequest,
    SessionSplit,
    SignedVoucher,
    VoucherData,
)


def test_session_request_round_trips_shared_wire_fields():
    request = SessionRequest(
        cap="1000000",
        currency="USDC",
        operator="operator",
        recipient="recipient",
        decimals=6,
        network="devnet",
        splits=[SessionSplit(recipient="affiliate", bps=250)],
        program_id="program",
        description="Metered API session",
        external_id="session-001",
        min_voucher_delta="1000",
        modes=[SessionMode.PUSH, SessionMode.PULL],
        pull_voucher_strategy=SessionPullVoucherStrategy.CLIENT_VOUCHER,
        recent_blockhash="blockhash",
    )

    wire = request.to_dict()

    assert wire["programId"] == "program"
    assert wire["externalId"] == "session-001"
    assert wire["minVoucherDelta"] == "1000"
    assert wire["modes"] == ["push", "pull"]
    assert wire["pullVoucherStrategy"] == "clientVoucher"
    assert SessionRequest.from_dict(wire) == request


def test_session_request_requires_pull_strategy_when_pull_mode_is_advertised():
    request = SessionRequest(
        cap="1000000",
        currency="USDC",
        operator="operator",
        recipient="recipient",
        modes=[SessionMode.PULL],
    )

    with pytest.raises(ValueError, match="pullVoucherStrategy"):
        request.to_dict()


def test_session_request_rejects_invalid_cap_and_split():
    with pytest.raises(ValueError, match="cap must be positive"):
        SessionRequest(cap="0", currency="USDC", operator="operator", recipient="recipient").to_dict()

    with pytest.raises(ValueError, match="split bps"):
        SessionRequest(
            cap="1",
            currency="USDC",
            operator="operator",
            recipient="recipient",
            splits=[SessionSplit(recipient="affiliate", bps=0)],
        ).to_dict()


def test_signed_voucher_round_trips_cumulative_voucher_shape():
    voucher = SignedVoucher(
        data=VoucherData(
            channel_id="channel",
            cumulative_amount="25000",
            expires_at=4_102_444_800,
            nonce=1,
        ),
        signature="signature",
    )

    assert voucher.to_dict() == {
        "data": {
            "channelId": "channel",
            "cumulativeAmount": "25000",
            "expiresAt": 4_102_444_800,
            "nonce": 1,
        },
        "signature": "signature",
    }
    assert SignedVoucher.from_dict(voucher.to_dict()) == voucher


def test_metering_directive_and_commit_receipt_wire_fields():
    directive = MeteringDirective(
        delivery_id="delivery-001",
        session_id="channel",
        amount="5000",
        currency="USDC",
        sequence=1,
        expires_at=4_102_444_800,
        commit_url="https://merchant.example/session/commit",
        proof="proof",
    )
    receipt = CommitReceipt(
        delivery_id="delivery-001",
        session_id="channel",
        amount="5000",
        cumulative="30000",
        status="committed",
    )

    assert directive.to_dict()["deliveryId"] == "delivery-001"
    assert directive.to_dict()["sessionId"] == "channel"
    assert directive.to_dict()["commitUrl"] == "https://merchant.example/session/commit"
    assert receipt.to_dict()["status"] == "committed"


def test_commit_receipt_rejects_unknown_status():
    receipt = CommitReceipt(
        delivery_id="delivery-001",
        session_id="channel",
        amount="5000",
        cumulative="30000",
        status="accepted",  # type: ignore[arg-type]
    )

    with pytest.raises(ValueError, match="status"):
        receipt.to_dict()
