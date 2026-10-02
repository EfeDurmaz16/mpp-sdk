"""Run with a clean consumer interpreter after installing the wheel or sdist."""

import importlib.metadata
import importlib.util
import json
from pathlib import Path

from solders.pubkey import Pubkey

import solana_pay_kit
from solana_pay_kit.protocols.programs.paymentchannels.types.voucherArgs import VoucherArgs

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
for package in ("solana-pay-kit", "solana", "solders", "pyborsh", "pydantic"):
    print(f"{package}: {importlib.metadata.version(package)}")
print("Installed distribution imports and native wire round-trip passed.")
