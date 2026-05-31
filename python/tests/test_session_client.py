"""Client-side session tests.

Mirrors ``rust/crates/mpp/src/client/session.rs`` plus the session_consumer
tests. Uses a deterministic ``solders.keypair.Keypair`` as the session signer.
"""

from __future__ import annotations

import pytest
from solders.keypair import Keypair
from solders.pubkey import Pubkey
from solders.signature import Signature

from solana_mpp.client.session import DEFAULT_VOUCHER_EXPIRES_AT, ActiveSession
from solana_mpp.client.session_consumer import SessionConsumer
from solana_mpp.protocol.session import (
    ClosePayload,
    CommitReceipt,
    MeteredEnvelope,
    MeteringDirective,
    OpenPayload,
    TopUpPayload,
    VoucherPayload,
)


def _signer(seed: int = 42) -> Keypair:
    return Keypair.from_seed(bytes([seed] * 32))


def _channel() -> str:
    return str(Pubkey(bytes([9] * 32)))


def _session(seed: int = 42) -> ActiveSession:
    return ActiveSession(_channel(), _signer(seed))


def test_sign_increment_increases_cumulative_and_sets_nonce():
    s = _session()
    assert s.cumulative == 0
    v = s.sign_increment(100)
    assert s.cumulative == 100
    assert v.data.cumulative == "100"
    assert v.data.nonce == 1


def test_sign_voucher_absolute():
    s = _session()
    s.sign_increment(50)
    v = s.sign_voucher(200)
    assert s.cumulative == 200
    assert v.data.cumulative == "200"


def test_voucher_signature_verifies_against_authorized_signer():
    signer = _signer()
    s = ActiveSession(_channel(), signer)
    v = s.sign_increment(100)
    sig = Signature.from_string(v.signature)
    assert sig.verify(signer.pubkey(), v.data.message_bytes())
    # A different key must not verify.
    other = Keypair.from_seed(bytes([1] * 32))
    assert not sig.verify(other.pubkey(), v.data.message_bytes())


def test_prepare_and_record_voucher_are_separate_steps():
    s = _session()
    prepared = s.prepare_increment(75)
    assert prepared.data.cumulative == "75"
    assert prepared.data.nonce == 1
    assert s.cumulative == 0
    s.record_voucher(prepared)
    assert s.cumulative == 75
    with pytest.raises(ValueError):
        s.record_voucher(prepared)


def test_record_voucher_handles_missing_nonce_and_rejects_bad_cumulative():
    s = _session()
    from solana_mpp.protocol.session import SignedVoucher, VoucherData

    bad = SignedVoucher(VoucherData(_channel(), "not-a-number", DEFAULT_VOUCHER_EXPIRES_AT), "sig")
    with pytest.raises(ValueError):
        s.record_voucher(bad)
    without_nonce = SignedVoucher(VoucherData(_channel(), "15", DEFAULT_VOUCHER_EXPIRES_AT), "sig")
    s.record_voucher(without_nonce)
    assert s.cumulative == 15


def test_sign_voucher_rejects_non_increasing_and_zero():
    s = _session()
    s.sign_increment(100)
    with pytest.raises(ValueError):
        s.sign_voucher(100)
    with pytest.raises(ValueError):
        s.sign_voucher(50)
    fresh = _session()
    with pytest.raises(ValueError):
        fresh.sign_voucher(0)


def test_nonce_increments_per_voucher():
    s = _session()
    v1 = s.sign_increment(10)
    v2 = s.sign_increment(10)
    assert v1.data.nonce == 1
    assert v2.data.nonce == 2


def test_set_expires_at_controls_voucher_expiry():
    s = ActiveSession(_channel(), _signer(), expires_at=1234)
    first = s.prepare_increment(10)
    assert first.data.expires_at == 1234
    s.set_expires_at(5678)
    second = s.prepare_increment(10)
    assert second.data.expires_at == 5678


def test_voucher_channel_id_matches_session():
    s = _session()
    v = s.sign_increment(100)
    assert v.data.channel_id == s.channel_id_str()


def test_voucher_action_fields():
    s = _session()
    action = s.voucher_action(33)
    assert isinstance(action, VoucherPayload)
    assert action.voucher.data.cumulative == "33"
    assert action.voucher.data.channel_id == s.channel_id_str()


def test_open_action_push_fields():
    s = _session()
    action = s.open_action(1_000_000, "txsig123")
    assert isinstance(action, OpenPayload)
    assert action.mode == "push"
    assert action.deposit == "1000000"
    assert action.signature == "txsig123"
    assert action.channel_id == s.channel_id_str()
    assert action.authorized_signer == s.authorized_signer()


def test_open_payment_channel_action_fields():
    s = _session()
    action = s.open_payment_channel_action(9_000, "payer", "payee", "mint", 42, 60, "open-sig")
    assert isinstance(action, OpenPayload)
    assert action.mode == "push"
    assert action.deposit == "9000"
    assert action.payer == "payer"
    assert action.salt == 42
    assert action.grace_period == 60


def test_open_payment_channel_action_can_use_pull_mode():
    s = _session()
    action = s.open_payment_channel_action_with_mode("pull", 9_000, "payer", "payee", "mint", 42, 60, "pending")
    assert isinstance(action, OpenPayload)
    assert action.mode == "pull"
    assert action.channel_id == s.channel_id_str()
    assert action.token_account is None


def test_open_pull_action_fields():
    s = _session()
    action = s.open_pull_action(5_000_000, "wallet123", "approvesig")
    assert isinstance(action, OpenPayload)
    assert action.mode == "pull"
    assert action.approved_amount == "5000000"
    assert action.token_account == s.channel_id_str()
    assert action.owner == "wallet123"
    assert action.channel_id is None


def test_topup_action_fields():
    s = _session()
    action = s.topup_action(5_000_000, "topuptx")
    assert isinstance(action, TopUpPayload)
    assert action.new_deposit == "5000000"
    assert action.signature == "topuptx"


def test_close_action_variants():
    s = _session()
    no_final = s.close_action()
    assert isinstance(no_final, ClosePayload)
    assert no_final.voucher is None

    s2 = _session()
    s2.sign_increment(100)
    with_final = s2.close_action(50)
    assert isinstance(with_final, ClosePayload)
    assert with_final.voucher is not None
    assert with_final.voucher.data.cumulative == "150"

    s3 = _session()
    zero_final = s3.close_action(0)
    assert isinstance(zero_final, ClosePayload)
    assert zero_final.voucher is None


# ── SessionConsumer ──


class _RecordingTransport:
    def __init__(self, fail: bool = False) -> None:
        self.commits: list = []
        self.fail = fail

    async def commit(self, directive: MeteringDirective, payload) -> CommitReceipt:
        if self.fail:
            raise RuntimeError("commit failed")
        cumulative = payload.voucher.data.cumulative
        self.commits.append(payload)
        return CommitReceipt(
            delivery_id=directive.delivery_id,
            session_id=directive.session_id,
            amount=directive.amount,
            cumulative=cumulative,
            status="committed",
        )


def _directive(session_id: str, amount: int) -> MeteringDirective:
    return MeteringDirective(
        delivery_id="d1",
        session_id=session_id,
        amount=str(amount),
        currency="USDC",
        sequence=1,
        expires_at=DEFAULT_VOUCHER_EXPIRES_AT,
    )


async def test_consumer_ack_sends_commit_and_advances_watermark():
    session = _session()
    transport = _RecordingTransport()
    consumer = SessionConsumer(session, transport)
    envelope = MeteredEnvelope(payload="work", metering=_directive(session.channel_id_str(), 250))
    delivery = consumer.accept(envelope)
    assert delivery.payload == "work"
    receipt = await delivery.ack()
    assert receipt.cumulative == "250"
    assert consumer.session.cumulative == 250
    assert len(transport.commits) == 1


async def test_consumer_commit_alias_and_into_parts():
    session = _session()
    transport = _RecordingTransport()
    consumer = SessionConsumer(session, transport)
    consumer.session.set_expires_at(1234)
    delivery = consumer.accept(MeteredEnvelope(payload="payload", metering=_directive(session.channel_id_str(), 50)))
    assert delivery.metering.amount == "50"
    receipt = await delivery.commit()
    assert receipt.cumulative == "50"
    assert transport.commits[0].voucher.data.expires_at == 1234

    delivery2 = consumer.accept(MeteredEnvelope(payload="second", metering=_directive(session.channel_id_str(), 75)))
    payload, metering = delivery2.into_parts()
    assert payload == "second"
    assert metering.amount == "75"


async def test_consumer_rejects_wrong_session_and_zero_amount():
    session = _session()
    transport = _RecordingTransport()
    consumer = SessionConsumer(session, transport)
    with pytest.raises(ValueError, match="does not match active session"):
        consumer.accept(MeteredEnvelope(payload=None, metering=_directive("other-session", 1)))
    with pytest.raises(ValueError, match="greater than zero"):
        await consumer.commit_directive(_directive(session.channel_id_str(), 0))


async def test_consumer_failed_commit_does_not_advance_watermark():
    session = _session()
    transport = _RecordingTransport(fail=True)
    consumer = SessionConsumer(session, transport)
    with pytest.raises(RuntimeError, match="commit failed"):
        await consumer.commit_directive(_directive(session.channel_id_str(), 250))
    assert consumer.session.cumulative == 0
