"""Keychain routing and pre-signing boundaries for the x402 async flows."""

from __future__ import annotations

import base64
import json

import pytest
from solana_keychain.memory import MemorySigner
from solders.hash import Hash
from solders.instruction import AccountMeta, Instruction
from solders.keypair import Keypair
from solders.message import Message, MessageV0, MessageV1, to_bytes_versioned
from solders.pubkey import Pubkey
from solders.signature import Signature
from solders.transaction import VersionedTransaction

from solana_pay_kit import LocalSigner
from solana_pay_kit.config import reset
from solana_pay_kit.errors import InvalidProofError
from solana_pay_kit.protocols.x402 import _co_sign_async
from solana_pay_kit.protocols.x402.client.exact import build_payment
from solana_pay_kit.protocols.x402.client.upto import (
    build_upto_header_async,
    build_upto_payload,
    build_upto_payload_async,
)
from solana_pay_kit.protocols.x402.client.upto import payment as upto_client
from solana_pay_kit.protocols.x402.exact.verify import ExactVerifier
from solana_pay_kit.protocols.x402.upto import _cosign_fee_payer_async, _decode_transaction
from tests.test_pk_x402_client import _entry, _offer
from tests.test_pk_x402_settle import _adapter, _build_envelope, _Req
from tests.test_pk_x402_upto_settle import (
    _client_header,
    _engine,
    _expected_distribution_hash,
    _fake_channel,
    _gate,
    _op_pubkey,
    _verified,
)
from tests.test_pk_x402_upto_verifier import _requirements


@pytest.fixture(autouse=True)
def _clean(monkeypatch):
    reset()
    monkeypatch.setenv("PAY_KIT_DISABLE_PREFLIGHT", "1")
    yield
    reset()


@pytest.fixture
def memory_calls(monkeypatch):
    calls: list[Pubkey] = []
    original = MemorySigner.sign_transaction

    async def record(self, transaction):
        calls.append(self.pubkey)
        return await original(self, transaction)

    monkeypatch.setattr(MemorySigner, "sign_transaction", record)
    return calls


def _partial_transaction(payer: Keypair, client: Keypair, legacy: bool = False) -> VersionedTransaction:
    instruction = Instruction(Pubkey.new_unique(), b"", [AccountMeta(client.pubkey(), True, False)])
    message = (
        Message.new_with_blockhash([instruction], payer.pubkey(), Hash.default())
        if legacy
        else MessageV0.try_compile(payer.pubkey(), [instruction], [], Hash.default())
    )
    signatures = [Signature.default(), client.sign_message(bytes(to_bytes_versioned(message)))]
    return VersionedTransaction.populate(message, signatures)


@pytest.mark.parametrize("cosign", [_co_sign_async, _cosign_fee_payer_async])
@pytest.mark.parametrize("legacy", [False, True])
async def test_cosign_uses_memory_and_preserves_other_signature(cosign, legacy, memory_calls):
    payer, client = Keypair(), Keypair()
    transaction = _partial_transaction(payer, client, legacy)
    raw = bytes(transaction)
    signed = VersionedTransaction.from_bytes(
        await cosign(base64.b64encode(raw).decode(), LocalSigner.from_keypair(payer))
    )
    assert memory_calls == [payer.pubkey()]
    assert signed.message == transaction.message
    assert signed.signatures[1] == transaction.signatures[1]
    assert signed.verify_with_results() == [True, True]
    assert bytes(transaction) == raw


@pytest.mark.parametrize("cosign", [_co_sign_async, _cosign_fee_payer_async])
async def test_cosign_rejects_nonzero_fee_payer_slot_before_memory(cosign, memory_calls):
    payer, server = Keypair(), Keypair()
    transaction = _partial_transaction(payer, server)
    with pytest.raises(InvalidProofError, match="slot 0"):
        await cosign(base64.b64encode(bytes(transaction)).decode(), LocalSigner.from_keypair(server))
    assert memory_calls == []


@pytest.mark.parametrize("cosign", [_co_sign_async, _cosign_fee_payer_async])
@pytest.mark.parametrize("legacy", [False, True])
async def test_cosign_rejects_invalid_existing_signature_before_memory(cosign, legacy, memory_calls):
    payer = Keypair()
    transaction = _partial_transaction(payer, Keypair(), legacy)
    transaction.signatures = [Signature.default(), Keypair().sign_message(b"different message")]
    with pytest.raises(InvalidProofError) as raised:
        await cosign(base64.b64encode(bytes(transaction)).decode(), LocalSigner.from_keypair(payer))
    assert raised.value.code == "payment_invalid"
    assert raised.value.http_status == 402
    assert str(raised.value) == "solana_pay_kit: invalid transaction for fee payer signing"
    assert memory_calls == []


@pytest.mark.parametrize("cosign", [_co_sign_async, _cosign_fee_payer_async])
@pytest.mark.parametrize("bad_format", ["v1", "trailing"])
async def test_unsupported_wire_is_rejected_before_memory(cosign, bad_format, memory_calls):
    payer = Keypair()
    if bad_format == "v1":
        message = MessageV1.try_compile(payer.pubkey(), [], Hash.default())
        raw = bytes(VersionedTransaction.populate(message, [Signature.default()]))
        assert VersionedTransaction.from_bytes(raw).version() == 1
    else:
        raw = bytes(_partial_transaction(payer, Keypair())) + b"trailing"
    encoded = base64.b64encode(raw).decode()
    with pytest.raises(InvalidProofError):
        ExactVerifier.verify(encoded, {}, [])
    with pytest.raises(InvalidProofError):
        _decode_transaction(encoded)
    with pytest.raises(InvalidProofError):
        await cosign(encoded, LocalSigner.from_keypair(payer))
    assert memory_calls == []


@pytest.mark.parametrize("cosign", [_co_sign_async, _cosign_fee_payer_async])
async def test_cosign_preserves_custom_message_signer(cosign, memory_calls):
    payer, client = Keypair(), Keypair()
    messages: list[bytes] = []

    class CustomSigner:
        def pubkey(self):
            return str(payer.pubkey())

        def sign(self, message):
            messages.append(message)
            return bytes(payer.sign_message(message))

    transaction = _partial_transaction(payer, client)
    signed = VersionedTransaction.from_bytes(
        await cosign(base64.b64encode(bytes(transaction)).decode(), CustomSigner())
    )
    assert messages == [bytes(to_bytes_versioned(transaction.message))]
    assert signed.signatures[1] == transaction.signatures[1]
    assert signed.verify_with_results() == [True, True]
    assert memory_calls == []


async def test_exact_async_client_uses_memory(monkeypatch, memory_calls):
    payer, client = Keypair(), Keypair()
    signer = LocalSigner.from_keypair(client)

    def refuse_sync(*args):
        raise AssertionError("async client used synchronous signing")

    monkeypatch.setattr(LocalSigner, "sign", refuse_sync)
    envelope = await build_payment(signer, None, _entry(_offer(fee_payer=str(payer.pubkey()))))
    payload = envelope.get("payload")
    assert payload is not None
    encoded = payload.get("transaction")
    assert encoded is not None
    transaction = VersionedTransaction.from_bytes(base64.b64decode(encoded))
    assert memory_calls == [client.pubkey()]
    assert transaction.signatures[0] == Signature.default()
    assert transaction.verify_with_results() == [False, True]


async def test_upto_async_client_matches_sync_wire(monkeypatch, memory_calls):
    payer, client = Keypair(), Keypair()
    signer = LocalSigner.from_keypair(client)
    requirements = _requirements(str(payer.pubkey()), str(Pubkey.new_unique()))
    monkeypatch.setattr(upto_client.secrets, "randbits", lambda bits: 7)
    expected = build_upto_payload(signer, requirements, 123456)

    def refuse_sync(*args):
        raise AssertionError("async client used synchronous signing")

    monkeypatch.setattr(LocalSigner, "sign", refuse_sync)
    actual = await build_upto_payload_async(signer, requirements, 123456)
    assert actual == expected
    assert memory_calls == [client.pubkey()]
    assert await build_upto_header_async(signer, requirements, 123456)
    assert memory_calls == [client.pubkey(), client.pubkey()]


async def test_exact_default_server_uses_memory(monkeypatch, memory_calls):
    adapter, gate, payer = _adapter(monkeypatch=monkeypatch)
    header = _build_envelope(adapter, gate, payer)
    await adapter.verify_and_settle(gate, _Req(header))
    assert memory_calls == [payer.pubkey()]


async def test_exact_policy_failure_does_not_call_memory(monkeypatch, memory_calls):
    adapter, gate, payer = _adapter(monkeypatch=monkeypatch)
    header = _build_envelope(adapter, gate, payer, amount_override=1)
    with pytest.raises(InvalidProofError):
        await adapter.verify_and_settle(gate, _Req(header))
    assert memory_calls == []


async def test_exact_invalid_signature_is_payment_error_before_rpc_or_memory(monkeypatch, memory_calls):
    rpcs = []
    adapter, gate, payer = _adapter(monkeypatch=monkeypatch, rpcs=rpcs)
    envelope = json.loads(base64.b64decode(_build_envelope(adapter, gate, payer)))
    transaction = VersionedTransaction.from_bytes(base64.b64decode(envelope["payload"]["transaction"]))
    transaction.signatures = [Signature.default(), Keypair().sign_message(b"different message")]
    envelope["payload"]["transaction"] = base64.b64encode(bytes(transaction)).decode()
    header = base64.b64encode(json.dumps(envelope).encode()).decode()

    with pytest.raises(InvalidProofError) as raised:
        await adapter.verify_and_settle(gate, _Req(header))
    assert raised.value.code == "payment_invalid"
    assert raised.value.http_status == 402
    assert str(raised.value) == "solana_pay_kit: invalid transaction for fee payer signing"
    assert memory_calls == []
    assert rpcs == []


async def test_upto_default_open_uses_memory(monkeypatch, memory_calls):
    engine, config, accounts = _engine(monkeypatch)
    header, client, requirements = _client_header(engine, config)
    operator = _op_pubkey(config)
    accounts["account"] = _fake_channel(
        payer=client,
        payee=operator,
        mint=requirements["asset"],
        operator=operator,
        deposit=100000,
        distribution_hash=_expected_distribution_hash(config.effective_recipient(), operator),
    )
    verified = await engine.verify_open(_gate(config), _Req(header, path="/usage"))
    assert memory_calls == [Pubkey.from_string(operator)]
    assert str(verified.payer) == client
    verified.release()


@pytest.mark.parametrize("amount", [0, 50000])
async def test_upto_settlement_uses_memory(monkeypatch, memory_calls, amount):
    engine, config, _ = _engine(monkeypatch)
    settlement = await engine.settle_actual(_verified(config), amount)
    assert settlement["success"] is True
    signer = config.effective_x402_signer()
    assert signer is not None
    assert memory_calls == [Pubkey.from_string(signer.pubkey())]


async def test_upto_ceiling_failure_does_not_call_memory(monkeypatch, memory_calls):
    engine, config, _ = _engine(monkeypatch)
    with pytest.raises(InvalidProofError):
        await engine.settle_actual(_verified(config), 100001)
    assert memory_calls == []
