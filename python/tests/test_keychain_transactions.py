"""Transaction-native signing preserves payment messages and signature slots."""

from __future__ import annotations

import asyncio
import base64

import pytest
from solana_keychain import MemorySigner, ModifyingSigner, SendingSigner, SignedTransaction
from solders.hash import Hash
from solders.instruction import AccountMeta, Instruction
from solders.keypair import Keypair
from solders.message import Message, MessageV0, MessageV1, TransactionConfig, to_bytes_versioned
from solders.pubkey import Pubkey
from solders.signature import Signature
from solders.transaction import Transaction, VersionedTransaction

from solana_pay_kit._paycore.transaction import (
    build_partially_signed_v0_transaction,
    build_partially_signed_v0_transaction_async,
    decode_supported_transaction,
)
from solana_pay_kit.signer import LocalSigner, sign_transaction


def _key(seed: int) -> Keypair:
    return Keypair.from_seed(bytes([seed]) * 32)


def _instruction(payer: Keypair, cosigner: Keypair) -> Instruction:
    return Instruction(
        Pubkey.default(),
        b"\x01",
        [AccountMeta(payer.pubkey(), True, True), AccountMeta(cosigner.pubkey(), True, False)],
    )


def _transaction(version: str = "v0", signed_payer: bool = True) -> VersionedTransaction:
    payer, cosigner = _key(1), _key(2)
    instructions = [_instruction(payer, cosigner)]
    if version == "legacy":
        message = Message.new_with_blockhash(instructions, payer.pubkey(), Hash.default())
    elif version == "v0":
        message = MessageV0.try_compile(payer.pubkey(), instructions, [], Hash.default())
    else:
        message = MessageV1.try_compile(
            payer.pubkey(),
            instructions,
            Hash.default(),
            TransactionConfig(compute_unit_limit=30000, loaded_accounts_data_size_limit=65536),
        )
    first = payer.sign_message(to_bytes_versioned(message)) if signed_payer else Signature.default()
    return VersionedTransaction.populate(message, [first, Signature.default()])


class LegacySigner:
    def __init__(self, keypair: Keypair) -> None:
        self.keypair = keypair
        self.calls = 0

    def pubkey(self) -> str:
        return str(self.keypair.pubkey())

    def sign(self, message: bytes) -> bytes:
        self.calls += 1
        return bytes(self.keypair.sign_message(message))

    async def sign_transaction(self, transaction: VersionedTransaction) -> SignedTransaction:
        raise AssertionError("a method name alone is not a Keychain capability")


@pytest.mark.parametrize("version", ["legacy", "v0"])
@pytest.mark.parametrize("kind", ["local", "keypair", "keychain", "legacy"])
async def test_signing_preserves_existing_signature_and_input(version: str, kind: str) -> None:
    key = _key(2)
    signer = {"local": LocalSigner(key), "keypair": key, "keychain": MemorySigner(key), "legacy": LegacySigner(key)}[
        kind
    ]
    transaction = _transaction(version)
    original = bytes(transaction)
    result = await sign_transaction(signer, transaction)
    assert bytes(transaction) == original
    assert result.transaction.signatures[0] == transaction.signatures[0]
    assert result.transaction.verify_with_results() == [True, True]
    assert to_bytes_versioned(result.transaction.message) == to_bytes_versioned(transaction.message)
    assert base64.b64decode(result.encoded_transaction) == bytes(result.transaction)
    assert result.signature == result.transaction.signatures[1]
    assert result.is_complete


async def test_local_and_keypair_use_keychain_transaction_method(monkeypatch: pytest.MonkeyPatch) -> None:
    calls = []
    original = MemorySigner.sign_transaction

    async def tracked(self: MemorySigner, transaction: VersionedTransaction) -> SignedTransaction:
        calls.append(self.pubkey)
        return await original(self, transaction)

    monkeypatch.setattr(MemorySigner, "sign_transaction", tracked)
    local = LocalSigner(_key(2))
    await local.sign_transaction(_transaction())
    await sign_transaction(_key(2), _transaction())
    assert calls == [_key(2).pubkey(), _key(2).pubkey()]
    assert local.sign(b"still synchronous") == bytes(_key(2).sign_message(b"still synchronous"))


async def test_legacy_transaction_input_and_partial_completion() -> None:
    payer, cosigner = _key(1), _key(2)
    legacy = Transaction.new_unsigned(
        Message.new_with_blockhash([_instruction(payer, cosigner)], payer.pubkey(), Hash.default())
    )
    wire = bytes(legacy)
    partial = await sign_transaction(cosigner, legacy)
    assert not partial.is_complete
    assert partial.transaction.verify_with_results() == [False, True]
    complete = await sign_transaction(payer, partial.transaction)
    assert complete.is_complete
    assert complete.transaction.verify_with_results() == [True, True]
    assert bytes(legacy) == wire


@pytest.mark.parametrize("kind", ["v1", "outsider", "invalid-existing", "invalid-count"])
async def test_policy_rejects_before_signing(kind: str) -> None:
    signer = LegacySigner(_key(3) if kind == "outsider" else _key(2))
    transaction = _transaction("v1" if kind == "v1" else "v0")
    if kind == "invalid-existing":
        transaction.signatures = [Signature.from_bytes(bytes([9]) * 64), Signature.default()]
    if kind == "invalid-count":
        transaction.signatures = [Signature.default()]
    before = bytes(transaction)
    with pytest.raises(ValueError):
        await sign_transaction(signer, transaction)
    assert signer.calls == 0
    assert bytes(transaction) == before


class UntrustedSigner(MemorySigner):
    def __init__(self, action: str) -> None:
        super().__init__(_key(2))
        self.action = action

    async def sign_transaction(self, transaction: VersionedTransaction) -> SignedTransaction:
        result = await super().sign_transaction(transaction)
        if self.action == "cancel":
            raise asyncio.CancelledError
        if self.action == "fail":
            raise RuntimeError("provider failed")
        if self.action == "other-slot":
            transaction.signatures = [Signature.default(), result.signature]
        if self.action == "signature":
            transaction.signatures = [transaction.signatures[0], Signature.default()]
        if self.action == "count":
            transaction.signatures = [*transaction.signatures, Signature.default()]
        if self.action == "message":
            message = MessageV0.try_compile(_key(1).pubkey(), [_instruction(_key(1), _key(2))], [], Hash.new_unique())
            transaction = VersionedTransaction.populate(message, transaction.signatures)
        encoded = "invalid" if self.action == "encoding" else base64.b64encode(bytes(transaction)).decode()
        return SignedTransaction(encoded, result.signature, False, transaction)


@pytest.mark.parametrize("action", ["other-slot", "signature", "count", "message", "encoding", "cancel", "fail"])
async def test_backend_failure_or_mutation_leaves_original_unchanged(action: str) -> None:
    transaction = _transaction()
    original = bytes(transaction)
    expected = asyncio.CancelledError if action == "cancel" else RuntimeError if action == "fail" else ValueError
    with pytest.raises(expected):
        await sign_transaction(UntrustedSigner(action), transaction)
    assert bytes(transaction) == original


async def test_completion_is_derived_from_verified_slots() -> None:
    result = await sign_transaction(UntrustedSigner("complete"), _transaction())
    assert result.is_complete


@pytest.mark.parametrize("length", [63, 64, 65])
async def test_invalid_custom_signature_is_rejected(length: int) -> None:
    class InvalidSigner(LegacySigner):
        def sign(self, message: bytes) -> bytes:
            return bytes(length)

    with pytest.raises(ValueError, match="signature"):
        await sign_transaction(InvalidSigner(_key(2)), _transaction())


class ForbiddenModifyingSigner(ModifyingSigner):
    @property
    def pubkey(self) -> Pubkey:
        raise AssertionError("must reject before identity lookup")

    async def sign_message(self, message: bytes) -> Signature:
        raise AssertionError("must not sign")

    async def is_available(self) -> bool:
        return True

    async def modify_and_sign_transaction(self, transaction: VersionedTransaction) -> SignedTransaction:
        raise AssertionError("must not modify")


class ForbiddenSendingSigner(SendingSigner):
    @property
    def pubkey(self) -> Pubkey:
        raise AssertionError("must reject before identity lookup")

    async def sign_message(self, message: bytes) -> Signature:
        raise AssertionError("must not sign")

    async def is_available(self) -> bool:
        return True

    async def sign_and_send_transaction(self, transaction: VersionedTransaction) -> Signature:
        raise AssertionError("must not broadcast")


@pytest.mark.parametrize("signer", [ForbiddenModifyingSigner(), ForbiddenSendingSigner(), object()])
async def test_unsupported_signer_capabilities_are_rejected(signer: object) -> None:
    with pytest.raises(ValueError, match="signer"):
        await sign_transaction(signer, _transaction())


async def test_async_builder_matches_sync_wire_and_checks_signer_before_call() -> None:
    payer, signer = _key(1), LegacySigner(_key(2))
    instructions = [_instruction(payer, signer.keypair)]
    expected = build_partially_signed_v0_transaction(
        instructions,
        payer.pubkey(),
        Hash.default(),
        signer.keypair.pubkey(),
        signer.sign,
    )
    actual = await build_partially_signed_v0_transaction_async(
        instructions,
        payer.pubkey(),
        Hash.default(),
        signer.keypair.pubkey(),
        signer,
    )
    assert actual == expected
    assert decode_supported_transaction(actual).verify_with_results() == [False, True]
    calls = signer.calls
    with pytest.raises(ValueError, match="does not match"):
        await build_partially_signed_v0_transaction_async(
            instructions,
            payer.pubkey(),
            Hash.default(),
            payer.pubkey(),
            signer,
        )
    assert signer.calls == calls
    with pytest.raises(ValueError, match="not a required signer"):
        await build_partially_signed_v0_transaction_async(
            instructions,
            payer.pubkey(),
            Hash.default(),
            _key(3).pubkey(),
            signer,
        )
    assert signer.calls == calls


@pytest.mark.parametrize("version", ["legacy", "v0"])
def test_decoder_accepts_only_one_complete_supported_transaction(version: str) -> None:
    wire = bytes(_transaction(version))
    assert bytes(decode_supported_transaction(wire)) == wire
    for malformed in [wire + b"\x00", wire[:-1], b""]:
        with pytest.raises(ValueError):
            decode_supported_transaction(malformed)


def test_decoder_rejects_real_v1_wire() -> None:
    with pytest.raises(ValueError, match="unsupported transaction version"):
        decode_supported_transaction(bytes(_transaction("v1")))
