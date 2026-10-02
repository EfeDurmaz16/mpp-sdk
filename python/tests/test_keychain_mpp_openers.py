"""Async MPP openers preserve existing wire bytes and challenge policy."""

from __future__ import annotations

import asyncio
import base64

import pytest
from solana_keychain import MemorySigner, SignedTransaction
from solders.hash import Hash
from solders.keypair import Keypair
from solders.message import to_bytes_versioned
from solders.signature import Signature
from solders.transaction import VersionedTransaction

from solana_pay_kit._paycore.solana import TOKEN_PROGRAM
from solana_pay_kit.protocols.mpp._paymentchannels import PROGRAM_ID
from solana_pay_kit.protocols.mpp.client import (
    PaymentChannelOpenOptions,
    PaymentChannelOpenTransaction,
    PaymentChannelSessionOpen,
    PaymentChannelSessionOpenOptions,
    build_open_payment_channel_transaction,
    build_open_payment_channel_transaction_async,
    create_payment_channel_session_opener,
    create_payment_channel_session_opener_async,
)
from solana_pay_kit.protocols.mpp.intents.session import (
    SessionAuthentication,
    SessionMethodDetails,
    SessionRequest,
    SessionSplit,
)
from solana_pay_kit.signer import LocalSigner

# Captured from the original synchronous openers before the async refactor.
# Each fixture includes the exact payer signature and all transaction bytes.
_FROZEN_OPEN = {
    False: (
        "ARpT+IiD3LTbYd5Zo6KiC+tKydKlg70Vrbv1wbb7BoQ3sbMK/bF3NuTX3uwfeQqEpoPgGNEmpU2Q77gsR2I79Q6AAQAJDe1JKMYo0cLG"
        "6ukDOJBZlWEpWSc6XGP5NjbBRhSshzfRIhaouFTNCaWOsK+Qp4cHcIzZokTAkWxbWklQ+XVoXsVj1Hy1XLTZwCUIh+dGILEBrFn/QRk3"
        "r2ZUgGeYxUnwM7e7hPX+M94VpB5bCOvSGlrx+G5G9lNFPocPMEelHtDgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAGp9UXGSxcUS"
        "GMyUw9SvF/WNruCJuh/UTj29mKAAAAAAbd9uHXZaGT2cvhRs7reawctIXtX1s3kTqM9YV+/wCpWlQNe2seKyu1F1IZyaPwYBCSQcqMTxc"
        "MwcotSO7q+dCBOXcOqH0XX1ajVGbDTH7My42KkbTuN6Jd9g9bj8mzlIyXJY9OJInxuz0QKRSODYMLWhOZ2v8QhASOe9jb6fhZp6H7pOsr"
        "CQmT99Lf1iuJ4rhyB3pjn9fXR6jpn2PUFa7G+nrzvtutOj1l82qryXQxsbvkwtL24OR8pgIDRS9dYcqTrBcFGHBx1nuDx/8O/oEI6OxFMF"
        "dddyaHkzPb2r58AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABCg4AAAgLDAIDAQYEBQkHCkMBBwAAAAAAAADoAwAAAAAAAHgAAAAqAAAA"
        "AAAAAAEAAAD9FyQ4WqDHW2T7eM1gL6HZkf3r92sTxY7XAurINen2GGQAAA=="
    ),
    True: (
        "AgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAC/T0mHKNe/hc0LNfQAtGuj"
        "P/LLdJTkZMZTVwhUnJZ4zPHiOK2BdzD/OQmJvHZxynkis5ZMObwY1D+48yygYJMOgAIACQ5uehzdKbC3j9E69MVZj+/07yqXFm48pvLk"
        "+/zNgFBb8e1JKMYo0cLG6ukDOJBZlWEpWSc6XGP5NjbBRhSshzfRIhaouFTNCaWOsK+Qp4cHcIzZokTAkWxbWklQ+XVoXsVj1Hy1XLTZw"
        "CUIh+dGILEBrFn/QRk3r2ZUgGeYxUnwM7e7hPX+M94VpB5bCOvSGlrx+G5G9lNFPocPMEelHtDgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        "AAAAAAAAAAAGp9UXGSxcUSGMyUw9SvF/WNruCJuh/UTj29mKAAAAAAbd9uHXZaGT2cvhRs7reawctIXtX1s3kTqM9YV+/wCpWlQNe2seKyu"
        "1F1IZyaPwYBCSQcqMTxcMwcotSO7q+dCBOXcOqH0XX1ajVGbDTH7My42KkbTuN6Jd9g9bj8mzlIyXJY9OJInxuz0QKRSODYMLWhOZ2v8Qh"
        "ASOe9jb6fhZp6H7pOsrCQmT99Lf1iuJ4rhyB3pjn9fXR6jpn2PUFa7G+nrzvtutOj1l82qryXQxsbvkwtL24OR8pgIDRS9dYcqTrBcFGHB"
        "x1nuDx/8O/oEI6OxFMFdddyaHkzPb2r58AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABCw4BAAkMDQMEAgcFBgoIC0MBBwAAAAAAAADo"
        "AwAAAAAAAHgAAAAqAAAAAAAAAAEAAAD9FyQ4WqDHW2T7eM1gL6HZkf3r92sTxY7XAurINen2GGQAAA=="
    ),
}


def _kp(seed: int) -> Keypair:
    return Keypair.from_seed(bytes([seed] * 32))


def _request(*, sponsored: bool = False) -> SessionRequest:
    return SessionRequest(
        amount="25",
        currency="USDC",
        recipient=str(_kp(2).pubkey()),
        suggested_deposit="1000",
        method_details=SessionMethodDetails(
            network="localnet",
            channel_program=str(PROGRAM_ID),
            decimals=6,
            token_program=TOKEN_PROGRAM,
            fee_payer=sponsored,
            fee_payer_key=str(_kp(5).pubkey()) if sponsored else None,
            voucher_signer="client",
            grace_period_seconds=120,
            idle_timeout_options_seconds=[30, 300],
            distribution_splits=[SessionSplit(str(_kp(9).pubkey()), 100)],
            recent_blockhash=str(Hash.default()),
            recent_slot=42,
        ),
    )


@pytest.fixture
def keychain_calls(monkeypatch: pytest.MonkeyPatch) -> list[bytes]:
    calls: list[bytes] = []
    original = MemorySigner.sign_transaction

    async def sign(self: MemorySigner, transaction: VersionedTransaction) -> SignedTransaction:
        assert asyncio.get_running_loop().is_running()
        calls.append(bytes(transaction))
        await asyncio.sleep(0)
        return await original(self, transaction)

    monkeypatch.setattr(MemorySigner, "sign_transaction", sign)
    return calls


@pytest.mark.parametrize("sponsored", [False, True])
@pytest.mark.parametrize("local", [False, True], ids=["keypair", "local-signer"])
async def test_async_openers_preserve_frozen_wire_and_use_keychain(
    keychain_calls: list[bytes], sponsored: bool, local: bool
) -> None:
    payer = LocalSigner(_kp(3)) if local else _kp(3)
    request = _request(sponsored=sponsored)
    options = PaymentChannelSessionOpenOptions(
        open=PaymentChannelOpenOptions(salt=7),
        idle_timeout_seconds=30,
        cumulative=17,
        expires_at=2_000_000_000,
    )
    synchronous = build_open_payment_channel_transaction(request, payer, _kp(4).pubkey(), options=options.open)
    sync_session = create_payment_channel_session_opener(request, payer, _kp(4), options=options)
    assert isinstance(synchronous, PaymentChannelOpenTransaction)
    assert isinstance(sync_session, PaymentChannelSessionOpen)
    assert keychain_calls == []

    built = await build_open_payment_channel_transaction_async(request, payer, _kp(4).pubkey(), options=options.open)
    opened = await create_payment_channel_session_opener_async(request, payer, _kp(4), options=options)
    assert built == synchronous
    assert built.transaction == _FROZEN_OPEN[sponsored]
    assert str(built.channel_id) == "7ihHdk3pqYvt1qpQ9xz5GSF3eUDDs1zLgoaXifri3MSz"
    assert opened.action.to_dict() == sync_session.action.to_dict()
    assert opened.open == sync_session.open
    assert opened.session.channel_id == built.channel_id
    assert opened.session.cumulative == 17
    assert opened.session.expires_at == 2_000_000_000
    assert len(keychain_calls) == 2
    assert all(
        all(signature == Signature.default() for signature in VersionedTransaction.from_bytes(raw).signatures)
        for raw in keychain_calls
    )
    transaction = VersionedTransaction.from_bytes(base64.b64decode(built.transaction, validate=True))
    assert transaction.version() == 0
    assert transaction.message.recent_blockhash == Hash.default()
    assert transaction.message.account_keys[0] == (_kp(5) if sponsored else _kp(3)).pubkey()
    assert len(transaction.signatures) == (2 if sponsored else 1)
    if sponsored:
        assert transaction.signatures[0] == Signature.default()
    assert transaction.signatures[-1].verify(_kp(3).pubkey(), to_bytes_versioned(transaction.message))


@pytest.mark.parametrize("session_opener", [False, True], ids=["transaction", "session"])
@pytest.mark.parametrize(
    ("invalid", "error"),
    [
        ("missing-blockhash", "missing recentBlockhash"),
        ("invalid-blockhash", "invalid challenged recentBlockhash"),
        ("missing-slot", "missing recentSlot"),
        ("future-slot", "ahead of the challenged recentSlot"),
        ("missing-deposit", "suggestedDeposit or minimumDeposit"),
        ("missing-fee-key", "feePayerKey is required"),
        ("invalid-fee-key", "invalid feePayerKey"),
    ],
)
async def test_challenge_policy_fails_before_keychain(
    keychain_calls: list[bytes], session_opener: bool, invalid: str, error: str
) -> None:
    request = _request(sponsored=True)
    options = PaymentChannelOpenOptions(salt=7)
    if invalid == "missing-blockhash":
        request.method_details.recent_blockhash = None
    elif invalid == "invalid-blockhash":
        request.method_details.recent_blockhash = "invalid"
    elif invalid == "missing-slot":
        request.method_details.recent_slot = None
    elif invalid == "future-slot":
        options.open_slot = 43
    elif invalid == "missing-deposit":
        request.suggested_deposit = None
    elif invalid == "missing-fee-key":
        request.method_details.fee_payer_key = None
    elif invalid == "invalid-fee-key":
        request.method_details.fee_payer_key = "invalid"
    with pytest.raises(ValueError, match=error):
        if session_opener:
            await create_payment_channel_session_opener_async(
                request, LocalSigner(_kp(3)), _kp(4), options=PaymentChannelSessionOpenOptions(open=options)
            )
        else:
            await build_open_payment_channel_transaction_async(
                request, LocalSigner(_kp(3)), _kp(4).pubkey(), options=options
            )
    assert keychain_calls == []


async def test_fee_payer_override_is_checked_before_keychain(keychain_calls: list[bytes]) -> None:
    with pytest.raises(ValueError, match="challenge fee-payer policy"):
        await build_open_payment_channel_transaction_async(
            _request(sponsored=True), _kp(3), _kp(4).pubkey(), fee_payer=_kp(3).pubkey()
        )
    assert keychain_calls == []

    accepted = await build_open_payment_channel_transaction_async(
        _request(sponsored=True),
        _kp(3),
        _kp(4).pubkey(),
        fee_payer=_kp(5).pubkey(),
        options=PaymentChannelOpenOptions(salt=7),
    )
    assert accepted.transaction == _FROZEN_OPEN[True]
    assert len(keychain_calls) == 1


@pytest.mark.parametrize("invalid", ["authentication", "idle-timeout", "operator"])
async def test_session_policy_fails_before_keychain(keychain_calls: list[bytes], invalid: str) -> None:
    request = _request()
    options = PaymentChannelSessionOpenOptions(open=PaymentChannelOpenOptions(salt=7))
    error = "authentication"
    if invalid == "idle-timeout":
        options.idle_timeout_seconds = 31
        error = "advertised options"
    else:
        request.method_details.voucher_signer = "operator"
        if invalid == "operator":
            options.authentication = SessionAuthentication("challenge", str(_kp(3).pubkey()), "proof")
            error = "operator is required"
    with pytest.raises(ValueError, match=error):
        await create_payment_channel_session_opener_async(request, _kp(3), _kp(4), options=options)
    assert keychain_calls == []


async def test_operator_opener_preserves_authority_authentication_and_overrides(keychain_calls: list[bytes]) -> None:
    request = _request(sponsored=True)
    request.method_details.voucher_signer = "operator"
    request.method_details.operator = str(_kp(6).pubkey())
    authentication = SessionAuthentication("challenge", str(_kp(3).pubkey()), "proof")
    options = PaymentChannelSessionOpenOptions(
        open=PaymentChannelOpenOptions(salt=7, open_slot=41),
        authentication=authentication,
        idle_timeout_seconds=30,
    )
    override = Hash.from_bytes(bytes([7] * 32))
    expected = create_payment_channel_session_opener(request, _kp(3), _kp(4), override, options)
    actual = await create_payment_channel_session_opener_async(request, _kp(3), _kp(4), override, options)
    assert actual.open == expected.open
    assert actual.open.authorized_signer == _kp(6).pubkey()
    assert actual.open.open_slot == 41
    assert actual.action.to_dict() == expected.action.to_dict()
    assert actual.action.open is not None
    assert actual.action.open.authentication == authentication
    transaction = VersionedTransaction.from_bytes(base64.b64decode(actual.action.open.transaction, validate=True))
    assert transaction.message.recent_blockhash == override
    assert transaction.signatures[0] == Signature.default()
    assert len(keychain_calls) == 1


async def test_custom_synchronous_message_signer_remains_supported(keychain_calls: list[bytes]) -> None:
    class MessageSigner:
        def pubkey(self) -> str:
            return str(_kp(3).pubkey())

        def sign(self, message: bytes) -> bytes:
            return bytes(_kp(3).sign_message(message))

    opened = await create_payment_channel_session_opener_async(
        _request(sponsored=True),
        MessageSigner(),
        _kp(4),
        options=PaymentChannelSessionOpenOptions(open=PaymentChannelOpenOptions(salt=7)),
    )
    assert opened.action.open is not None
    assert opened.action.open.transaction == _FROZEN_OPEN[True]
    assert keychain_calls == []


async def test_custom_signer_cannot_return_another_keys_signature(keychain_calls: list[bytes]) -> None:
    class WrongKeySigner:
        def pubkey(self) -> str:
            return str(_kp(3).pubkey())

        def sign(self, message: bytes) -> bytes:
            return bytes(_kp(4).sign_message(message))

    with pytest.raises(ValueError, match="payment-channel open signing failed"):
        await build_open_payment_channel_transaction_async(
            _request(sponsored=True),
            WrongKeySigner(),
            _kp(4).pubkey(),
            options=PaymentChannelOpenOptions(salt=7),
        )
    assert keychain_calls == []
