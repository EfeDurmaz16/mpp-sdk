"""MPP transaction paths use Keychain without changing payment signatures."""

from __future__ import annotations

import base64
from types import SimpleNamespace

import pytest
from solana_keychain import MemorySigner, SignedTransaction
from solders.hash import Hash
from solders.keypair import Keypair
from solders.message import Message, MessageV0, MessageV1, to_bytes_versioned
from solders.signature import Signature
from solders.system_program import TransferParams, transfer
from solders.transaction import VersionedTransaction

from solana_pay_kit._paycore.errors import PaymentError
from solana_pay_kit._paycore.solana import MethodDetails
from solana_pay_kit._paycore.store import MemoryStore
from solana_pay_kit.protocols.mpp.client.charge import build_charge_transaction
from solana_pay_kit.protocols.mpp.client.payment_channels import (
    PaymentChannelOpenOptions,
    PaymentChannelSessionOpenOptions,
    create_payment_channel_session_opener_async,
)
from solana_pay_kit.protocols.mpp.core.types import PaymentCredential
from solana_pay_kit.protocols.mpp.server._verify import _co_sign_with_fee_payer_async
from solana_pay_kit.protocols.mpp.server.charge import ChargeOptions, Config, Mpp
from solana_pay_kit.protocols.mpp.server.session_onchain import cosign_and_broadcast_open
from tests.test_keychain_mpp_openers import _request
from tests.test_server import TEST_SECRET, FakeRPC, _verify


def _keypair(seed: int) -> Keypair:
    return Keypair.from_seed(bytes([seed] * 32))


@pytest.fixture
def keychain_calls(monkeypatch: pytest.MonkeyPatch) -> list[bytes]:
    calls: list[bytes] = []
    original = MemorySigner.sign_transaction

    async def sign(self: MemorySigner, transaction: VersionedTransaction) -> SignedTransaction:
        calls.append(bytes(transaction))
        return await original(self, transaction)

    monkeypatch.setattr(MemorySigner, "sign_transaction", sign)
    return calls


def _payment(version: str = "v0", *, sponsor_at_zero: bool = True) -> VersionedTransaction:
    sponsor, payer, recipient = _keypair(1), _keypair(2), _keypair(3)
    instruction = transfer(TransferParams(from_pubkey=payer.pubkey(), to_pubkey=recipient.pubkey(), lamports=1000))
    fee_payer = sponsor.pubkey() if sponsor_at_zero else payer.pubkey()
    if not sponsor_at_zero:
        instruction = transfer(
            TransferParams(from_pubkey=sponsor.pubkey(), to_pubkey=recipient.pubkey(), lamports=1000)
        )
    if version == "legacy":
        message = Message.new_with_blockhash([instruction], fee_payer, Hash.default())
    elif version == "v1":
        message = MessageV1.try_compile(fee_payer, [instruction], Hash.default())
    else:
        message = MessageV0.try_compile(fee_payer, [instruction], [], Hash.default())
    signatures = [Signature.default()] * message.header.num_required_signatures
    signatures[list(message.account_keys).index(payer.pubkey())] = payer.sign_message(to_bytes_versioned(message))
    return VersionedTransaction.populate(message, signatures)


@pytest.mark.parametrize("version", ["legacy", "v0"])
async def test_fee_payer_cosign_preserves_client_signature_and_exact_wire(
    keychain_calls: list[bytes], version: str
) -> None:
    original = _payment(version)
    raw = bytes(original)
    result = await _co_sign_with_fee_payer_async(base64.b64encode(raw).decode(), _keypair(1))
    signed = VersionedTransaction.from_bytes(base64.b64decode(result, validate=True))
    expected = VersionedTransaction(original.message, [_keypair(1), _keypair(2)])
    assert bytes(signed) == bytes(expected)
    assert signed.signatures[1] == original.signatures[1]
    assert signed.verify_with_results() == [True, True]
    assert bytes(original) == raw
    assert keychain_calls == [raw]


@pytest.mark.parametrize(
    ("invalid", "error"),
    [
        ("slot", "must occupy account index 0"),
        ("missing-key", "not present"),
        ("v1", "could not decode"),
        ("trailing", "could not decode"),
        ("signature", "co-sign rejected"),
    ],
)
async def test_invalid_cosign_fails_before_keychain(keychain_calls: list[bytes], invalid: str, error: str) -> None:
    transaction = _payment("v1" if invalid == "v1" else "v0", sponsor_at_zero=invalid != "slot")
    raw = bytes(transaction)
    signer = _keypair(9) if invalid == "missing-key" else _keypair(1)
    if invalid == "trailing":
        raw += b"trailing"
    elif invalid == "signature":
        signatures = list(transaction.signatures)
        signatures[1] = _keypair(2).sign_message(b"different message")
        transaction.signatures = signatures
        raw = bytes(transaction)
    with pytest.raises(PaymentError, match=error):
        await _co_sign_with_fee_payer_async(base64.b64encode(raw).decode(), signer)
    assert keychain_calls == []


@pytest.mark.parametrize("sponsored", [False, True])
async def test_charge_transaction_routes_raw_keypair_through_keychain(
    keychain_calls: list[bytes], sponsored: bool
) -> None:
    payer, sponsor = _keypair(2), _keypair(1)
    payload = await build_charge_transaction(
        signer=payer,
        rpc_client=None,
        amount="1000",
        currency="sol",
        recipient=str(_keypair(3).pubkey()),
        method_details=MethodDetails(
            recent_blockhash=str(Hash.default()),
            fee_payer=sponsored,
            fee_payer_key=str(sponsor.pubkey()) if sponsored else "",
        ),
    )
    assert payload.transaction is not None
    transaction = VersionedTransaction.from_bytes(base64.b64decode(payload.transaction, validate=True))
    assert len(keychain_calls) == 1
    assert transaction.version() == 0
    assert transaction.message.account_keys[0] == (sponsor if sponsored else payer).pubkey()
    assert transaction.verify_with_results() == ([False, True] if sponsored else [True])
    if sponsored:
        assert transaction.signatures[0] == Signature.default()


@pytest.mark.parametrize("missing_transaction", [False, True])
async def test_open_broadcast_uses_keychain_after_client_signing(
    keychain_calls: list[bytes], missing_transaction: bool
) -> None:
    opened = await create_payment_channel_session_opener_async(
        _request(sponsored=True),
        _keypair(3),
        _keypair(4),
        options=PaymentChannelSessionOpenOptions(open=PaymentChannelOpenOptions(salt=7)),
    )
    payload = opened.action.open
    assert payload is not None
    keychain_calls.clear()

    class Rpc:
        def __init__(self) -> None:
            self.sent: list[bytes] = []

        async def get_latest_blockhash(self, commitment: str = "confirmed") -> SimpleNamespace:
            raise AssertionError("open must use the challenged blockhash")

        async def send_raw_transaction(self, raw_tx: bytes) -> SimpleNamespace:
            self.sent.append(raw_tx)
            signature = str(VersionedTransaction.from_bytes(raw_tx).signatures[0])
            return SimpleNamespace(value=signature)

        async def get_signature_statuses(self, signatures: list[str]) -> list[dict | None]:
            return [{"err": None, "confirmationStatus": "confirmed"}]

    rpc = Rpc()
    if missing_transaction:
        payload.transaction = ""
        with pytest.raises(PaymentError, match="client-built transaction"):
            await cosign_and_broadcast_open(payload, fee_payer=_keypair(5), rpc=rpc)
        assert rpc.sent == []
        assert keychain_calls == []
    else:
        original = VersionedTransaction.from_bytes(base64.b64decode(payload.transaction))
        signature = await cosign_and_broadcast_open(payload, fee_payer=_keypair(5), rpc=rpc)
        assert len(rpc.sent) == len(keychain_calls) == 1
        signed = VersionedTransaction.from_bytes(rpc.sent[0])
        assert signature == str(signed.signatures[0])
        assert signed.signatures[1] == original.signatures[1]
        assert signed.verify_with_results() == [True, True]


@pytest.mark.parametrize("valid_signature", [True, False])
async def test_sponsored_charge_route_checks_client_signature_before_keychain(
    keychain_calls: list[bytes], valid_signature: bool
) -> None:
    sponsor, payer, recipient = _keypair(1), _keypair(2), _keypair(3)
    info = {"source": str(payer.pubkey()), "destination": str(recipient.pubkey()), "lamports": "1000"}
    instruction = {"program": "system", "parsed": {"type": "transfer", "info": info}}
    rpc = FakeRPC(
        tx={
            "meta": {"err": None},
            "version": 0,
            "transaction": {"message": {"instructions": [instruction]}},
        }
    )
    mpp = Mpp(
        Config(
            recipient=str(recipient.pubkey()),
            currency="SOL",
            decimals=9,
            network="localnet",
            secret_key=TEST_SECRET,
            rpc=rpc,
            store=MemoryStore(),
            fee_payer_signer=sponsor,
        )
    )
    challenge = mpp.charge_with_options("0.000001", ChargeOptions(fee_payer=True))
    request = challenge.decode_request()
    details = MethodDetails.from_dict(request["methodDetails"])
    details.recent_blockhash = str(Hash.default())
    payload = await build_charge_transaction(
        signer=payer,
        rpc_client=None,
        amount=request["amount"],
        currency=request["currency"],
        recipient=request["recipient"],
        method_details=details,
    )
    assert payload.transaction is not None
    transaction = VersionedTransaction.from_bytes(base64.b64decode(payload.transaction))
    assert transaction.verify_with_results() == [False, True]
    if not valid_signature:
        transaction.signatures = [Signature.default(), payer.sign_message(b"wrong message")]
    original = bytes(transaction)
    credential = PaymentCredential(
        challenge=challenge.to_echo(),
        payload={"type": "transaction", "transaction": base64.b64encode(original).decode()},
    )
    keychain_calls.clear()
    if not valid_signature:
        with pytest.raises(PaymentError, match="co-sign rejected"):
            await _verify(mpp, credential, challenge)
        assert keychain_calls == []
        assert rpc.sent == []
        return
    receipt = await _verify(mpp, credential, challenge)
    assert receipt.is_success()
    assert keychain_calls == [original]
    assert len(rpc.sent) == 1
    signed = VersionedTransaction.from_bytes(rpc.sent[0])
    assert signed.signatures[1] == transaction.signatures[1]
    assert signed.verify_with_results() == [True, True]
    assert to_bytes_versioned(signed.message) == to_bytes_versioned(transaction.message)
    assert bytes(transaction) == original
