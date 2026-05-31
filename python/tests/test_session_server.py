"""Server-side session tests.

Mirrors ``rust/crates/mpp/src/server/session.rs``: challenge issuance, open
processing, voucher verification, metered deliveries with idempotent commit,
topup, and close.
"""

from __future__ import annotations

import pytest
from solders.keypair import Keypair
from solders.pubkey import Pubkey

from solana_mpp.channel_store import MemoryChannelStore
from solana_mpp.client.session import ActiveSession
from solana_mpp.protocol.payment_channels import (
    Distribution,
    OpenChannelParams,
    derive_channel_addresses,
    distribution_hash,
)
from solana_mpp.protocol.session import (
    SESSION_MODE_PULL,
    SESSION_MODE_PUSH,
    ClosePayload,
    CommitPayload,
    OpenPayload,
    SignedVoucher,
    TopUpPayload,
    VoucherData,
    VoucherPayload,
)
from solana_mpp.protocol.solana import (
    KNOWN_MINTS,
    TOKEN_2022_PROGRAM,
    default_token_program_for_currency,
)
from solana_mpp.server.session import DeliveryRequest, SessionConfig, SessionServer, Split

RECIPIENT = "CXhrFZJLKqjzmP3sjYLcF4dTeXWKCy9e2SXXZ2Yo6MPY"
USDC_MAINNET = KNOWN_MINTS["USDC"]["mainnet"]


def _signer(seed: int = 42) -> Keypair:
    return Keypair.from_seed(bytes([seed] * 32))


def _channel() -> str:
    return str(Pubkey(bytes([7] * 32)))


def _server(min_delta: int = 0, modes: list[str] | None = None, splits: list[Split] | None = None) -> SessionServer:
    return SessionServer(
        SessionConfig(
            operator=RECIPIENT,
            recipient=RECIPIENT,
            currency="USDC",
            network="localnet",
            min_voucher_delta=min_delta,
            modes=modes if modes is not None else [SESSION_MODE_PUSH],
            pull_voucher_strategy="clientVoucher" if modes and SESSION_MODE_PULL in modes else None,
            splits=splits or [],
        ),
        MemoryChannelStore(),
    )


def _open(channel_id: str, deposit: int, signer: str) -> OpenPayload:
    return OpenPayload.push(channel_id, str(deposit), signer, "dummy_tx_sig")


# ── build_challenge_request ──


def test_build_challenge_request_clamps_cap():
    assert _server().build_challenge_request(50_000_000).cap == "10000000"


def test_build_challenge_request_below_cap():
    assert _server().build_challenge_request(5_000_000).cap == "5000000"


def test_build_challenge_request_includes_fields_and_omits_push_only_modes():
    req = _server().build_challenge_request(1_000_000)
    assert req.operator == RECIPIENT
    assert req.recipient == RECIPIENT
    assert req.currency == "USDC"
    assert req.decimals == 6
    assert req.network == "localnet"
    assert req.splits == []
    # Push-only: modes omitted so clients assume push.
    assert req.modes == []


def test_build_challenge_request_advertises_pull_strategy():
    req = _server(modes=[SESSION_MODE_PUSH, SESSION_MODE_PULL]).build_challenge_request(1_000)
    assert req.modes == ["push", "pull"]
    assert req.pull_voucher_strategy == "clientVoucher"


def test_build_challenge_request_with_splits():
    split_pk = str(Pubkey(bytes([5] * 32)))
    req = _server(splits=[Split(split_pk, 1_000)]).build_challenge_request(1_000_000)
    assert len(req.splits) == 1
    assert req.splits[0].recipient == split_pk
    assert req.splits[0].bps == 1_000


# ── process_open ──


async def test_process_open_stores_state():
    server = _server()
    state = await server.process_open(_open("chan1", 1_000_000, "signer1"))
    assert state.deposit == 1_000_000
    assert state.cumulative == 0
    assert not state.finalized
    assert state.authorized_signer == "signer1"


async def test_process_open_zero_deposit_rejected():
    with pytest.raises(ValueError):
        await _server().process_open(_open("chan1", 0, "signer1"))


async def test_process_open_exceeds_cap_rejected():
    with pytest.raises(ValueError):
        await _server().process_open(_open("chan1", 20_000_000, "signer1"))


async def test_process_open_exactly_at_cap_accepted():
    state = await _server().process_open(_open("chan1", 10_000_000, "s"))
    assert state.deposit == 10_000_000


async def test_process_open_rejects_unadvertised_pull_mode():
    payload = OpenPayload.payment_channel_with_mode(
        SESSION_MODE_PULL, "chan1", "1000000", "payer", RECIPIENT, "mint", 1, 900, "signer1", "pending"
    )
    with pytest.raises(ValueError, match="not supported"):
        await _server().process_open(payload)


async def test_process_open_accepts_advertised_pull_channel():
    server = _server(modes=[SESSION_MODE_PULL])
    payload = OpenPayload.payment_channel_with_mode(
        SESSION_MODE_PULL, "chan1", "1000000", "payer", RECIPIENT, "mint", 1, 900, "signer1", "pending"
    )
    state = await server.process_open(payload)
    assert state.channel_id == "chan1"
    assert state.deposit == 1_000_000


# ── payment_channel_open_params ──


def test_payment_channel_open_params_validate_challenge_fields():
    payer = str(Pubkey(bytes([11] * 32)))
    authorized_signer = str(Pubkey(bytes([12] * 32)))
    split_recipient = str(Pubkey(bytes([13] * 32)))
    server = _server(modes=[SESSION_MODE_PULL], splits=[Split(split_recipient, 10)])
    token_program = default_token_program_for_currency("USDC", "localnet")
    expected = OpenChannelParams(
        payer=payer,
        payee=RECIPIENT,
        mint=USDC_MAINNET,
        authorized_signer=authorized_signer,
        salt=77,
        deposit=1_000_000,
        grace_period=900,
        token_program=token_program,
        recipients=[Distribution(split_recipient, 10)],
    )
    channel = derive_channel_addresses(expected).channel
    payload = OpenPayload.payment_channel_with_mode(
        SESSION_MODE_PULL, channel, "1000000", payer, RECIPIENT, USDC_MAINNET, 77, 900, authorized_signer, "pending"
    )
    params = server.payment_channel_open_params(payload)
    assert params.payer == payer
    assert params.payee == RECIPIENT
    assert params.mint == USDC_MAINNET
    assert params.authorized_signer == authorized_signer
    assert params.recipients == [Distribution(split_recipient, 10)]


def test_payment_channel_open_params_rejects_wrong_fields():
    payer = str(Pubkey(bytes([11] * 32)))
    authorized_signer = str(Pubkey(bytes([12] * 32)))
    server = _server(modes=[SESSION_MODE_PULL])
    expected = OpenChannelParams(
        payer=payer,
        payee=RECIPIENT,
        mint=USDC_MAINNET,
        authorized_signer=authorized_signer,
        salt=77,
        deposit=1_000_000,
        grace_period=900,
        token_program=default_token_program_for_currency("USDC", "localnet"),
    )
    channel = derive_channel_addresses(expected).channel
    base = OpenPayload.payment_channel_with_mode(
        SESSION_MODE_PULL, channel, "1000000", payer, RECIPIENT, USDC_MAINNET, 77, 900, authorized_signer, "pending"
    )

    wrong_payee = OpenPayload.from_dict({**base.to_dict(), "payee": str(Pubkey(bytes([14] * 32)))})
    with pytest.raises(ValueError, match="payee does not match"):
        server.payment_channel_open_params(wrong_payee)

    wrong_mint = OpenPayload.from_dict({**base.to_dict(), "mint": str(Pubkey(bytes([15] * 32)))})
    with pytest.raises(ValueError, match="mint does not match"):
        server.payment_channel_open_params(wrong_mint)

    missing_salt = OpenPayload.from_dict({k: v for k, v in base.to_dict().items() if k != "salt"})
    with pytest.raises(ValueError, match="missing salt"):
        server.payment_channel_open_params(missing_salt)

    wrong_channel = OpenPayload.from_dict({**base.to_dict(), "channelId": str(Pubkey(bytes([16] * 32)))})
    with pytest.raises(ValueError, match="channelId does not match"):
        server.payment_channel_open_params(wrong_channel)


def test_payment_channel_open_params_rejects_native_sol():
    server = SessionServer(
        SessionConfig(operator=RECIPIENT, recipient=RECIPIENT, currency="SOL", network="localnet"),
        MemoryChannelStore(),
    )
    payload = OpenPayload.payment_channel_with_mode(
        SESSION_MODE_PUSH, "chan1", "1000000", "payer", RECIPIENT, USDC_MAINNET, 1, 900, "s", "sig"
    )
    with pytest.raises(ValueError, match="SPL token"):
        server.payment_channel_open_params(payload)


def test_payment_channel_open_params_resolves_token_2022():
    pyusd_devnet = KNOWN_MINTS["PYUSD"]["devnet"]
    payer = str(Pubkey(bytes([11] * 32)))
    authorized_signer = str(Pubkey(bytes([12] * 32)))
    server = SessionServer(
        SessionConfig(
            operator=RECIPIENT,
            recipient=RECIPIENT,
            currency="PYUSD",
            network="devnet",
            modes=[SESSION_MODE_PULL],
            pull_voucher_strategy="clientVoucher",
        ),
        MemoryChannelStore(),
    )
    expected = OpenChannelParams(
        payer=payer,
        payee=RECIPIENT,
        mint=pyusd_devnet,
        authorized_signer=authorized_signer,
        salt=88,
        deposit=1_000_000,
        grace_period=901,
        token_program=TOKEN_2022_PROGRAM,
    )
    channel = derive_channel_addresses(expected).channel
    payload = OpenPayload.payment_channel_with_mode(
        SESSION_MODE_PULL, channel, "1000000", payer, RECIPIENT, pyusd_devnet, 88, 901, authorized_signer, "pending"
    )
    params = server.payment_channel_open_params(payload)
    assert params.mint == pyusd_devnet
    assert params.token_program == TOKEN_2022_PROGRAM
    assert params.grace_period == 901


# ── verify_voucher ──


async def _open_session(server: SessionServer, deposit: int, seed: int = 42):
    signer = _signer(seed)
    chan = _channel()
    session = ActiveSession(chan, signer)
    await server.process_open(_open(chan, deposit, session.authorized_signer()))
    return session, chan


async def test_verify_voucher_advances_watermark():
    server = _server()
    session, chan = await _open_session(server, 1_000)
    voucher = session.sign_increment(100)
    assert await server.verify_voucher(VoucherPayload(voucher)) == 100


async def test_verify_voucher_monotonic_and_cap_enforced():
    server = _server()
    session, chan = await _open_session(server, 1_000)
    await server.verify_voucher(VoucherPayload(session.sign_increment(100)))
    # Non-increasing cumulative for a new signature is rejected.
    bad = VoucherData(chan, "50", session.prepare_increment(1).data.expires_at)
    bad_voucher = SignedVoucher(bad, "x")
    with pytest.raises(ValueError, match="must exceed watermark"):
        await server.verify_voucher(VoucherPayload(bad_voucher))
    # Over-deposit is rejected.
    over = session.prepare_increment(2_000)
    with pytest.raises(ValueError, match="exceeds deposit"):
        await server.verify_voucher(VoucherPayload(over))


async def test_verify_voucher_min_delta_enforced():
    server = _server(min_delta=100)
    session, chan = await _open_session(server, 1_000)
    too_small = session.prepare_increment(50)
    with pytest.raises(ValueError, match="below minimum"):
        await server.verify_voucher(VoucherPayload(too_small))


async def test_verify_voucher_unknown_channel_rejected():
    server = _server()
    bad = SignedVoucher(VoucherData("unknown-channel", "10", 4_102_444_800), "sig")
    with pytest.raises(ValueError, match="not found"):
        await server.verify_voucher(VoucherPayload(bad))


async def test_verify_voucher_idempotent_replay():
    server = _server()
    session, chan = await _open_session(server, 1_000)
    voucher = session.sign_increment(100)
    assert await server.verify_voucher(VoucherPayload(voucher)) == 100
    # Same cumulative + same signature replays without error.
    assert await server.verify_voucher(VoucherPayload(voucher)) == 100


async def test_verify_voucher_bad_signature_rejected():
    server = _server()
    session, chan = await _open_session(server, 1_000)
    good = session.prepare_increment(100)
    tampered = SignedVoucher(good.data, str(Keypair().sign_message(b"junk")))
    with pytest.raises(ValueError, match="signature verification failed"):
        await server.verify_voucher(VoucherPayload(tampered))


# ── metered deliveries ──


async def test_begin_delivery_reserves_capacity():
    server = _server()
    session, chan = await _open_session(server, 1_000)
    directive = await server.begin_delivery(DeliveryRequest(session_id=chan, amount=100))
    assert directive.session_id == chan
    assert directive.amount == "100"
    assert directive.sequence == 1
    state = await server.store.get_channel(chan)
    assert len(state.pending_deliveries) == 1
    with pytest.raises(ValueError, match="exceeds available deposit"):
        await server.begin_delivery(DeliveryRequest(session_id=chan, amount=901))


async def test_process_commit_accepts_and_replays_idempotently():
    server = _server()
    session, chan = await _open_session(server, 1_000)
    directive = await server.begin_delivery(DeliveryRequest(session_id=chan, amount=125))
    voucher = session.sign_increment(125)
    payload = CommitPayload(directive.delivery_id, voucher)
    receipt = await server.process_commit(payload)
    assert receipt.amount == "125"
    assert receipt.cumulative == "125"
    assert receipt.status == "committed"
    replay = await server.process_commit(payload)
    assert replay.status == "replayed"
    state = await server.store.get_channel(chan)
    assert len(state.pending_deliveries) == 0
    assert len(state.committed_deliveries) == 1
    assert state.cumulative == 125


async def test_process_commit_accepts_partial_stream_usage():
    server = _server()
    session, chan = await _open_session(server, 1_000)
    directive = await server.begin_delivery(DeliveryRequest(session_id=chan, amount=125))
    voucher = session.sign_increment(75)
    receipt = await server.process_commit(CommitPayload(directive.delivery_id, voucher))
    assert receipt.amount == "75"
    assert receipt.cumulative == "75"


async def test_process_commit_rejects_over_reserved_cumulative():
    server = _server()
    session, chan = await _open_session(server, 1_000)
    directive = await server.begin_delivery(DeliveryRequest(session_id=chan, amount=125))
    voucher = session.sign_increment(200)
    with pytest.raises(ValueError, match="exceeds reserved amount"):
        await server.process_commit(CommitPayload(directive.delivery_id, voucher))


# ── topup + close ──


async def test_process_topup_raises_deposit():
    server = _server()
    session, chan = await _open_session(server, 1_000)
    state = await server.process_topup(TopUpPayload(chan, "5000", "topuptx"))
    assert state.deposit == 5_000
    with pytest.raises(ValueError, match="must exceed current deposit"):
        await server.process_topup(TopUpPayload(chan, "1000", "x"))
    with pytest.raises(ValueError, match="exceeds max cap"):
        await server.process_topup(TopUpPayload(chan, "99999999", "x"))


async def test_process_close_applies_final_voucher_and_returns_finalize_params():
    split_pk = str(Pubkey(bytes([13] * 32)))
    server = _server(splits=[Split(split_pk, 1_000)])
    session, chan = await _open_session(server, 1_000)
    await server.verify_voucher(VoucherPayload(session.sign_increment(100)))
    final = session.prepare_increment(50)
    params = await server.process_close(ClosePayload(chan, final))
    assert params.settled == 150
    assert params.channel_id == chan
    assert params.recipient == RECIPIENT
    assert params.distribution_hash == distribution_hash([Distribution(split_pk, 1_000)])
    state = await server.store.get_channel(chan)
    assert state.close_requested_at is not None
    # No further vouchers after close.
    with pytest.raises(ValueError, match="close is pending"):
        await server.verify_voucher(VoucherPayload(session.prepare_increment(10)))


async def test_process_close_without_voucher_uses_current_watermark():
    server = _server()
    session, chan = await _open_session(server, 1_000)
    await server.verify_voucher(VoucherPayload(session.sign_increment(100)))
    params = await server.process_close(ClosePayload(chan))
    assert params.settled == 100


async def test_mark_finalized_blocks_further_vouchers():
    server = _server()
    session, chan = await _open_session(server, 1_000)
    await server.mark_finalized(chan)
    with pytest.raises(ValueError, match="finalized"):
        await server.verify_voucher(VoucherPayload(session.sign_increment(10)))


async def test_full_lifecycle_open_vouchers_topup_more_vouchers_close():
    """open -> 3 vouchers -> topup -> 2 more vouchers -> close.

    Mirrors the integration scenario in the spec test plan, exercised here in
    memory (no surfpool). Final settled watermark matches the cumulative
    voucher.
    """
    server = _server()
    session, chan = await _open_session(server, 1_000)
    for amount in (100, 100, 100):
        await server.verify_voucher(VoucherPayload(session.sign_increment(amount)))
    state = await server.store.get_channel(chan)
    assert state.cumulative == 300
    await server.process_topup(TopUpPayload(chan, "5000", "topuptx"))
    for amount in (500, 500):
        await server.verify_voucher(VoucherPayload(session.sign_increment(amount)))
    params = await server.process_close(ClosePayload(chan))
    assert params.settled == 1_300
