"""Wire-shape tests for the session intent protocol types.

Mirrors the unit tests in ``rust/crates/mpp/src/protocol/intents/session.rs``.
"""

from __future__ import annotations

import pytest

from solana_mpp.protocol.session import (
    DEFAULT_SESSION_EXPIRES_AT,
    SESSION_MODE_PULL,
    SESSION_MODE_PUSH,
    ClosePayload,
    CommitPayload,
    MeteredEnvelope,
    MeteringDirective,
    MeteringUsage,
    OpenPayload,
    SessionRequest,
    SessionSplit,
    SignedVoucher,
    VoucherData,
    VoucherPayload,
    session_action_from_dict,
    session_action_to_dict,
)


def test_session_mode_constants_are_camel_case():
    assert SESSION_MODE_PUSH == "push"
    assert SESSION_MODE_PULL == "pull"


def test_default_session_expires_at_below_js_max_safe_int():
    assert DEFAULT_SESSION_EXPIRES_AT == 4_102_444_800
    assert DEFAULT_SESSION_EXPIRES_AT < 2**53


def test_session_request_roundtrip():
    req = SessionRequest(
        cap="10000000",
        currency="USDC",
        operator="op",
        recipient="rec",
        decimals=6,
        network="mainnet-beta",
        description="API session",
        modes=[SESSION_MODE_PUSH],
    )
    d = req.to_dict()
    back = SessionRequest.from_dict(d)
    assert back.cap == "10000000"
    assert back.currency == "USDC"
    assert back.description == "API session"
    assert back.modes == [SESSION_MODE_PUSH]


def test_session_request_omits_empty_splits_and_modes_and_none_fields():
    req = SessionRequest(cap="1000", currency="USDC", operator="op", recipient="rec")
    d = req.to_dict()
    assert "splits" not in d
    assert "modes" not in d
    assert "decimals" not in d
    assert "network" not in d
    assert "description" not in d
    assert "externalId" not in d
    assert "minVoucherDelta" not in d
    assert "pullVoucherStrategy" not in d


def test_session_request_with_modes_push_and_pull():
    req = SessionRequest(
        cap="1000",
        currency="USDC",
        operator="op",
        recipient="rec",
        modes=[SESSION_MODE_PUSH, SESSION_MODE_PULL],
        pull_voucher_strategy="clientVoucher",
    )
    d = req.to_dict()
    assert d["modes"] == ["push", "pull"]
    assert d["pullVoucherStrategy"] == "clientVoucher"
    back = SessionRequest.from_dict(d)
    assert back.modes == ["push", "pull"]
    assert back.pull_voucher_strategy == "clientVoucher"


def test_session_request_with_splits_and_program_id():
    req = SessionRequest(
        cap="1000",
        currency="USDC",
        operator="op",
        recipient="rec",
        splits=[SessionSplit("s1", 100), SessionSplit("s2", 200)],
        program_id="prog123",
        external_id="ref-1",
    )
    back = SessionRequest.from_dict(req.to_dict())
    assert len(back.splits) == 2
    assert back.splits[0].bps == 100
    assert back.program_id == "prog123"
    assert back.external_id == "ref-1"


def test_session_request_min_voucher_delta_roundtrip():
    req = SessionRequest(cap="100", currency="USDC", operator="op", recipient="rec", min_voucher_delta="500")
    d = req.to_dict()
    assert d["minVoucherDelta"] == "500"
    assert SessionRequest.from_dict(d).min_voucher_delta == "500"


def test_open_payload_push_fields():
    p = OpenPayload.push("chan1", "1000000", "signer1", "txsig")
    assert p.mode == SESSION_MODE_PUSH
    assert p.channel_id == "chan1"
    assert p.deposit == "1000000"
    assert p.token_account is None
    assert p.approved_amount is None
    assert p.authorized_signer == "signer1"
    assert p.signature == "txsig"


def test_open_payload_pull_fields():
    p = OpenPayload.pull("tokacct", "5000000", "wallet1", "signer1", "approvesig")
    assert p.mode == SESSION_MODE_PULL
    assert p.channel_id is None
    assert p.deposit is None
    assert p.token_account == "tokacct"
    assert p.approved_amount == "5000000"
    assert p.owner == "wallet1"


def test_open_payload_payment_channel_and_tx_helpers():
    p = (
        OpenPayload.payment_channel("chan1", "1000000", "payer1", "payee1", "mint1", 99, 45, "signer1", "txsig")
        .with_transaction("open-tx")
        .with_init_tx("init-tx")
        .with_update_tx("update-tx")
    )
    assert p.session_id() == "chan1"
    assert p.deposit_amount() == 1_000_000
    assert p.payer == "payer1"
    assert p.salt == 99
    assert p.grace_period == 45
    assert p.transaction == "open-tx"
    assert p.init_multi_delegate_tx == "init-tx"
    assert p.update_delegation_tx == "update-tx"


def test_open_payload_session_id_and_deposit_push_and_pull():
    push = OpenPayload.push("chan1", "2000000", "s", "sig")
    assert push.session_id() == "chan1"
    assert push.deposit_amount() == 2_000_000
    pull = OpenPayload.pull("tokacct", "3000000", "wallet1", "s", "sig")
    assert pull.session_id() == "tokacct"
    assert pull.deposit_amount() == 3_000_000


def test_open_payload_missing_required_fields_and_invalid_deposit_error():
    push = OpenPayload.push("chan1", "bad", "s", "sig")
    with pytest.raises(ValueError):
        push.deposit_amount()
    push.deposit = None
    with pytest.raises(ValueError):
        push.deposit_amount()
    push.channel_id = None
    with pytest.raises(ValueError):
        push.session_id()

    pull = OpenPayload.pull("tokacct", "bad", "wallet", "s", "sig")
    with pytest.raises(ValueError):
        pull.deposit_amount()
    pull.approved_amount = None
    with pytest.raises(ValueError):
        pull.deposit_amount()
    pull.token_account = None
    with pytest.raises(ValueError):
        pull.session_id()


def test_open_payload_push_roundtrip_omits_pull_fields():
    p = OpenPayload.push("chan1", "1000000", "signer1", "txsig")
    d = p.to_dict()
    assert d["mode"] == "push"
    assert d["channelId"] == "chan1"
    assert "tokenAccount" not in d
    back = OpenPayload.from_dict(d)
    assert back.mode == "push"
    assert back.channel_id == "chan1"


def test_open_payload_pull_roundtrip_omits_channel_id():
    p = OpenPayload.pull("tokacct", "5000000", "wallet1", "signer1", "approvesig")
    d = p.to_dict()
    assert d["mode"] == "pull"
    assert d["tokenAccount"] == "tokacct"
    assert d["owner"] == "wallet1"
    assert "channelId" not in d


def test_salt_serializes_as_string_and_accepts_legacy_number():
    salt = 2**64 - 7
    p = OpenPayload.payment_channel("chan1", "1000000", "payer1", "payee1", "mint1", salt, 900, "signer1", "txsig")
    d = p.to_dict()
    assert d["salt"] == str(salt)
    assert isinstance(d["salt"], str)
    assert OpenPayload.from_dict(d).salt == salt
    legacy = OpenPayload.from_dict({**d, "salt": 42})
    assert legacy.salt == 42


def test_open_payload_missing_mode_raises():
    with pytest.raises(ValueError):
        OpenPayload.from_dict(
            {"channelId": "chan1", "deposit": "1000", "authorizedSigner": "s", "signature": "sig"}
        )


def test_session_action_open_push_roundtrip():
    action = OpenPayload.push("chan123", "5000000", "signer123", "sig456")
    d = session_action_to_dict(action)
    assert d["action"] == "open"
    assert d["mode"] == "push"
    back = session_action_from_dict(d)
    assert isinstance(back, OpenPayload)
    assert back.session_id() == "chan123"
    assert back.deposit_amount() == 5_000_000


def test_session_action_voucher_roundtrip():
    action = VoucherPayload(
        SignedVoucher(VoucherData("chan1", "500000", 2**63 - 1, nonce=3), "sig_here")
    )
    d = session_action_to_dict(action)
    assert d["action"] == "voucher"
    back = session_action_from_dict(d)
    assert isinstance(back, VoucherPayload)
    assert back.voucher.data.cumulative == "500000"
    assert back.voucher.data.nonce == 3


def test_session_action_commit_roundtrip():
    action = CommitPayload("delivery-1", SignedVoucher(VoucherData("chan1", "500000", 99, nonce=3), "sig"))
    d = session_action_to_dict(action)
    assert d["action"] == "commit"
    assert d["deliveryId"] == "delivery-1"
    back = session_action_from_dict(d)
    assert isinstance(back, CommitPayload)
    assert back.delivery_id == "delivery-1"


def test_session_action_topup_uses_capital_u_tag():
    from solana_mpp.protocol.session import TopUpPayload

    action = TopUpPayload("chan1", "9000000", "txsig")
    d = session_action_to_dict(action)
    assert d["action"] == "topUp"
    back = session_action_from_dict(d)
    assert isinstance(back, TopUpPayload)
    assert back.new_deposit == "9000000"


def test_session_action_close_with_and_without_voucher():
    no_voucher = ClosePayload("chan1")
    d = session_action_to_dict(no_voucher)
    assert d["action"] == "close"
    assert "voucher" not in d
    back = session_action_from_dict(d)
    assert isinstance(back, ClosePayload)
    assert back.voucher is None

    with_voucher = ClosePayload("chan1", SignedVoucher(VoucherData("chan1", "700000", 99, nonce=7), "final_sig"))
    back2 = session_action_from_dict(session_action_to_dict(with_voucher))
    assert isinstance(back2, ClosePayload)
    assert back2.voucher is not None
    assert back2.voucher.data.cumulative == "700000"


def test_session_action_unknown_tag_raises():
    with pytest.raises(ValueError):
        session_action_from_dict({"action": "nope"})


def test_metering_directive_and_envelope_roundtrip():
    directive = MeteringDirective(
        delivery_id="d1",
        session_id="chan1",
        amount="125",
        currency="USDC",
        sequence=7,
        expires_at=DEFAULT_SESSION_EXPIRES_AT,
        commit_url="https://example.test/commit",
    )
    assert directive.amount_base_units() == 125
    envelope = MeteredEnvelope(payload={"ok": True}, metering=directive)
    d = envelope.to_dict()
    assert d["metering"]["deliveryId"] == "d1"
    assert d["metering"]["commitUrl"] == "https://example.test/commit"
    back = MeteredEnvelope.from_dict(d)
    assert back.metering.sequence == 7
    assert back.payload["ok"] is True


def test_metering_amount_parsers():
    bad = MeteringDirective("d1", "chan1", "not-a-number", "USDC", 1, 99)
    with pytest.raises(ValueError):
        bad.amount_base_units()
    usage = MeteringUsage("d1", "42")
    assert MeteringUsage.from_dict(usage.to_dict()).amount_base_units() == 42
    with pytest.raises(ValueError):
        MeteringUsage("d1", "bad").amount_base_units()


def test_voucher_data_cumulative_alias_read_serialize_canonical():
    legacy = VoucherData.from_dict({"channelId": "c", "cumulative": "500", "expiresAt": 99})
    assert legacy.cumulative == "500"
    assert legacy.to_dict()["cumulativeAmount"] == "500"
    assert "cumulative" not in legacy.to_dict()
    canonical = VoucherData.from_dict({"channelId": "c", "cumulativeAmount": "600", "expiresAt": 99})
    assert canonical.cumulative == "600"
