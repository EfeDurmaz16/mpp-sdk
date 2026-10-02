"""Run with a clean consumer interpreter after installing the wheel or sdist."""

import asyncio
import importlib.metadata
import importlib.util
import json
from pathlib import Path

from solders.hash import Hash
from solders.keypair import Keypair
from solders.message import Message, MessageV0
from solders.pubkey import Pubkey
from solders.signature import Signature
from solders.transaction import Transaction, VersionedTransaction

import solana_pay_kit
from solana_pay_kit.protocols.programs.paymentchannels.types.voucherArgs import VoucherArgs
from solana_pay_kit.signer import LocalSigner

assert "site-packages" in Path(solana_pay_kit.__file__).parts
for removed in ("anchorpy", "borsh_construct"):
    assert importlib.util.find_spec(removed) is None, removed
fixture = json.loads((Path(__file__).parent / "fixtures/paymentchannels_native.json").read_text())
case = next(item for item in fixture["cases"] if item["kind"] == "voucherArgs")
value = dict(case["input"])
value["channelId"] = bytes(value["channelId"])
voucher = VoucherArgs.model_validate(value)
assert voucher.to_borsh().hex() == case["hex"]
assert VoucherArgs.from_borsh(voucher.to_borsh()) == voucher
assert voucher.to_json()["channelId"] == str(Pubkey.from_bytes(value["channelId"]))


async def check_signing() -> None:
    keypair = Keypair.from_seed(bytes([42]) * 32)
    signer = LocalSigner.from_keypair(keypair)
    transactions = (
        Transaction.new_unsigned(Message.new_with_blockhash([], keypair.pubkey(), Hash.default())),
        VersionedTransaction.populate(
            MessageV0.try_compile(keypair.pubkey(), [], [], Hash.default()), [Signature.default()]
        ),
    )
    for transaction in transactions:
        original = bytes(transaction)
        result = await signer.sign_transaction(transaction)
        assert result.transaction.verify_with_results() == [True]
        assert bytes(transaction) == original


asyncio.run(check_signing())
for package in ("solana-pay-kit", "solana", "solders", "solana-keychain", "pyborsh", "pydantic"):
    print(f"{package}: {importlib.metadata.version(package)}")
print("Installed distribution imports, native wire round-trip and Keychain legacy/v0 signing passed.")
