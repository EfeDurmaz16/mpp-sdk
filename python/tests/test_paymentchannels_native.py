"""Generated native client contracts against independently encoded Rust fixtures.

PAYMENTCHANNELS_PACKAGE can select an uninstalled renderer output for codegen CI.
The JSON records wire-domain examples, not claims of valid on-chain state.
"""

from __future__ import annotations

import json
import os
from collections.abc import Callable
from enum import IntEnum
from importlib import import_module
from pathlib import Path

import pytest
from solders.instruction import AccountMeta, Instruction
from solders.pubkey import Pubkey

PACKAGE = os.environ.get("PAYMENTCHANNELS_PACKAGE", "solana_pay_kit.protocols.programs.paymentchannels")
_voucher = import_module(f"{PACKAGE}.types.voucherArgs").VoucherArgs
if PACKAGE == "solana_pay_kit.protocols.programs.paymentchannels" and not hasattr(_voucher, "to_borsh"):
    pytest.skip(
        "Native renderer contracts run against PAYMENTCHANNELS_PACKAGE until activation", allow_module_level=True
    )

from pyborsh import BorshDeserializationError  # noqa: E402
from pydantic import ValidationError, create_model  # noqa: E402

from solana_pay_kit._paycore.program_client import WireModel  # noqa: E402

FIXTURES = json.loads((Path(__file__).parent / "fixtures" / "paymentchannels_native.json").read_text())
MODEL_NAMES = (
    "distributeArgs",
    "distributionEntry",
    "openArgs",
    "settleAndSealArgs",
    "topUpArgs",
    "voucherArgs",
    "settlementWatermarks",
    "opened",
    "payoutRedirected",
)
ENUM_NAMES = ("accountDiscriminator", "channelStatus", "payoutBeneficiary", "redirectReason")
MODELS = {name: getattr(import_module(f"{PACKAGE}.types.{name}"), name[0].upper() + name[1:]) for name in MODEL_NAMES}
MODELS["channel"] = import_module(f"{PACKAGE}.accounts.channel").Channel
ENUMS: dict[str, type[IntEnum]] = {
    name: getattr(import_module(f"{PACKAGE}.types.{name}"), name[0].upper() + name[1:]) for name in ENUM_NAMES
}


# One-field envelopes exercise IntEnum bytes through the public model codec.
ENUM_WIRES: dict[str, type[WireModel]] = {
    name: create_model(name + "Wire", __base__=WireModel, value=(enum, ...)) for name, enum in ENUMS.items()
}

PUBKEY_FIELDS = {
    "recipient",
    "channelId",
    "payer",
    "payee",
    "authorizedSigner",
    "mint",
    "rentPayer",
    "channel",
    "owner",
}
CASES = FIXTURES["cases"]
INSTRUCTIONS = FIXTURES["instructions"]
STRUCT_CASES = [case for case in CASES if case["kind"] not in ENUMS]


def native_input(value, field: str = ""):
    if field in PUBKEY_FIELDS:
        return bytes(value)
    if field in ("beneficiary", "reason"):
        enum = ENUMS["payoutBeneficiary" if field == "beneficiary" else "redirectReason"]
        return enum[value] if isinstance(value, str) else enum(value)
    if isinstance(value, dict):
        return {key: native_input(item, key) for key, item in value.items()}
    if isinstance(value, list):
        return [native_input(item) for item in value]
    return value


def wire_model(case):
    kind = case["kind"]
    if kind in ENUMS:
        return ENUM_WIRES[kind].model_validate({"value": ENUMS[kind][case["input"]["variant"]]})
    return MODELS[kind].model_validate(native_input(case["input"]))


def example(kind: str) -> dict:
    return next(case for case in CASES if case["kind"] == kind)


def expected_json(value, field: str = ""):
    if field in PUBKEY_FIELDS:
        return str(Pubkey.from_bytes(bytes(value)))
    if isinstance(value, dict):
        return {key: expected_json(item, key) for key, item in value.items()}
    if isinstance(value, list):
        return [expected_json(item) for item in value]
    if field in ("beneficiary", "reason"):
        enum = ENUMS["payoutBeneficiary" if field == "beneficiary" else "redirectReason"]
        return int(enum[value] if isinstance(value, str) else enum(value))
    return value


def build_instruction(case, accounts, **kwargs) -> Instruction:
    name = case["name"]
    builder: Callable[..., Instruction] = getattr(
        import_module(f"{PACKAGE}.instructions.{name}"), name[0].upper() + name[1:]
    )
    args = {name: MODELS[name].model_validate(native_input(value)) for name, value in case["args"].items()}
    return builder(args=args, accounts=accounts, **kwargs) if args else builder(accounts=accounts, **kwargs)


def explicit_accounts(case) -> dict[str, Pubkey]:
    return {account["name"]: Pubkey.from_bytes(bytes(account["pubkey"])) for account in case["accounts"]}


def meta_tuples(accounts) -> list[tuple[bytes, bool, bool]]:
    return [(bytes(account.pubkey), account.is_signer, account.is_writable) for account in accounts]


def test_fixture_inventory_covers_the_pinned_program() -> None:
    assert {case["kind"] for case in CASES} == set(MODEL_NAMES) | set(ENUM_NAMES) | {"channel"}
    assert {case["name"] for case in INSTRUCTIONS} == {
        "open",
        "settle",
        "topUp",
        "settleAndSeal",
        "requestClose",
        "seal",
        "distribute",
        "withdrawPayer",
        "reclaim",
        "emitEvent",
    }
    for name, enum in ENUMS.items():
        assert {case["input"]["variant"] for case in CASES if case["kind"] == name} == set(enum.__members__)


@pytest.mark.parametrize("case", CASES, ids=lambda case: case["name"])
def test_wire_matches_independent_rust_bytes(case) -> None:
    obj = wire_model(case)
    frozen = bytes.fromhex(case["hex"])
    assert obj.to_borsh() == frozen
    assert type(obj).from_borsh(frozen) == obj


@pytest.mark.parametrize("case", CASES, ids=lambda case: case["name"])
def test_every_truncation_and_trailing_byte_is_rejected(case) -> None:
    model = type(wire_model(case))
    frozen = bytes.fromhex(case["hex"])
    for length in range(len(frozen)):
        with pytest.raises(BorshDeserializationError):
            model.from_borsh(frozen[:length])
    with pytest.raises(BorshDeserializationError):
        model.from_borsh(frozen + b"\x00")


@pytest.mark.parametrize("case", STRUCT_CASES, ids=lambda case: case["name"])
def test_explicit_json_preserves_fields_and_base58_pubkeys(case) -> None:
    obj = wire_model(case)
    as_json = expected_json(case["input"])
    assert obj.to_json() == as_json
    assert type(obj).from_json(as_json) == obj
    assert json.loads(json.dumps(obj.to_json())) == as_json


@pytest.mark.parametrize("case", INSTRUCTIONS, ids=lambda case: case["name"])
def test_all_instruction_data_order_and_flags_match_rust(case) -> None:
    accounts = explicit_accounts(case)
    before = accounts.copy()
    instruction = build_instruction(case, accounts)
    assert bytes(instruction.program_id) == bytes(case["programId"])
    assert instruction.data.hex() == case["hex"]
    assert meta_tuples(instruction.accounts) == [
        (bytes(account["pubkey"]), account["isSigner"], account["isWritable"]) for account in case["accounts"]
    ]
    assert accounts == before


@pytest.mark.parametrize("case", INSTRUCTIONS, ids=lambda case: case["name"])
def test_custom_program_and_remaining_accounts_are_preserved(case) -> None:
    custom_program = Pubkey.from_bytes(bytes([240]) * 32)
    remaining = [
        AccountMeta(Pubkey.from_bytes(bytes([241]) * 32), True, False),
        AccountMeta(Pubkey.from_bytes(bytes([242]) * 32), False, True),
    ]
    accounts = explicit_accounts(case)
    base = build_instruction(case, accounts)
    instruction = build_instruction(case, accounts, program_id=custom_program, remaining_accounts=remaining)
    assert instruction.program_id == custom_program
    assert instruction.data == base.data
    assert instruction.accounts == [*base.accounts, *remaining]
    assert remaining == instruction.accounts[-2:]


@pytest.mark.parametrize("name", ["open", "distribute", "emitEvent"])
@pytest.mark.parametrize("custom", [False, True])
def test_declared_account_defaults_and_custom_pda_program(name: str, custom: bool) -> None:
    case = next(case for case in INSTRUCTIONS if case["name"] == name)
    accounts = explicit_accounts(case)
    for key in ("systemProgram", "eventAuthority", "selfProgram"):
        accounts.pop(key, None)
    defaults = FIXTURES["defaults"]
    program = Pubkey.from_string(defaults["customProgramId"] if custom else defaults["programId"])
    instruction = build_instruction(case, accounts, program_id=program)
    expected = explicit_accounts(case)
    for key, value in (
        ("systemProgram", defaults["systemProgram"]),
        ("eventAuthority", defaults["customEventAuthority"] if custom else defaults["eventAuthority"]),
        ("selfProgram", defaults["programId"]),
    ):
        if key in expected:
            expected[key] = Pubkey.from_string(value)
    assert instruction.program_id == program
    assert instruction.data.hex() == case["hex"]
    assert meta_tuples(instruction.accounts) == [
        (bytes(expected[account["name"]]), account["isSigner"], account["isWritable"]) for account in case["accounts"]
    ]


INTEGER_FIELDS = [
    ("distributionEntry", "bps", 0, 2**16 - 1),
    ("openArgs", "salt", 0, 2**64 - 1),
    ("openArgs", "deposit", 0, 2**64 - 1),
    ("openArgs", "gracePeriod", 0, 2**32 - 1),
    ("openArgs", "openSlot", 0, 2**64 - 1),
    ("settleAndSealArgs", "hasVoucher", 0, 255),
    ("topUpArgs", "amount", 0, 2**64 - 1),
    ("voucherArgs", "cumulativeAmount", 0, 2**64 - 1),
    ("voucherArgs", "expiresAt", -(2**63), 2**63 - 1),
    ("settlementWatermarks", "settled", 0, 2**64 - 1),
    ("settlementWatermarks", "payoutWatermark", 0, 2**64 - 1),
    ("opened", "openSlot", 0, 2**64 - 1),
    ("payoutRedirected", "amount", 0, 2**64 - 1),
    ("channel", "version", 0, 255),
    ("channel", "bump", 0, 255),
    ("channel", "status", 0, 255),
    ("channel", "salt", 0, 2**64 - 1),
    ("channel", "deposit", 0, 2**64 - 1),
    ("channel", "closureStartedAt", -(2**63), 2**63 - 1),
    ("channel", "payerWithdrawnAt", -(2**63), 2**63 - 1),
    ("channel", "gracePeriod", 0, 2**32 - 1),
    ("channel", "openSlot", 0, 2**64 - 1),
]


@pytest.mark.parametrize("kind,field,minimum,maximum", INTEGER_FIELDS)
def test_integer_boundaries_and_strict_assignment(kind: str, field: str, minimum: int, maximum: int) -> None:
    cls = MODELS[kind]
    valid = native_input(example(kind)["input"])
    for value in (minimum, maximum):
        obj = cls.model_validate({**valid, field: value})
        assert getattr(cls.from_borsh(obj.to_borsh()), field) == value
    obj = cls.model_validate(valid)
    for value in (minimum - 1, maximum + 1, "1", 1.0, True, None):
        with pytest.raises(ValidationError):
            cls.model_validate({**valid, field: value})
        with pytest.raises(ValidationError):
            setattr(obj, field, value)


@pytest.mark.parametrize("kind,field,size", [("voucherArgs", "magic", 2), ("channel", "distributionHash", 32)])
def test_fixed_arrays_reject_wrong_lengths_and_elements(kind: str, field: str, size: int) -> None:
    valid = native_input(example(kind)["input"])
    for value in ([0] * (size - 1), [0] * (size + 1), [-1] * size, [256] * size, [True] * size, bytes(size)):
        with pytest.raises(ValidationError):
            MODELS[kind].model_validate({**valid, field: value})


@pytest.mark.parametrize(
    "value", [bytes(31), bytes(33), bytearray(32), memoryview(bytes(32)), "1" * 32, Pubkey.default()]
)
def test_native_pubkey_requires_exact_raw_bytes(value) -> None:
    valid = native_input(example("voucherArgs")["input"])
    with pytest.raises(ValidationError):
        MODELS["voucherArgs"].model_validate({**valid, "channelId": value})


def test_zero_pubkey_json_is_explicitly_converted_not_ascii_encoded() -> None:
    valid = native_input(example("voucherArgs")["input"])
    obj = MODELS["voucherArgs"].model_validate({**valid, "channelId": bytes(32)})
    value = obj.to_json()
    assert value["channelId"] == "1" * 32
    with pytest.raises(ValidationError):
        MODELS["voucherArgs"].model_validate(value)
    decoded = MODELS["voucherArgs"].from_json(value)
    assert decoded.channelId == bytes(32)
    assert decoded.to_borsh() == obj.to_borsh()


@pytest.mark.parametrize("kind", MODEL_NAMES + ("channel",))
def test_unknown_fields_are_rejected(kind: str) -> None:
    with pytest.raises(ValidationError):
        MODELS[kind].model_validate({**native_input(example(kind)["input"]), "typo": 1})


@pytest.mark.parametrize("kind,prefix", [("openArgs", bytes(28)), ("distributeArgs", b"")])
@pytest.mark.parametrize("count", [1, 2**32 - 1])
def test_vector_count_cannot_exceed_remaining_input(kind: str, prefix: bytes, count: int) -> None:
    with pytest.raises(BorshDeserializationError):
        MODELS[kind].from_borsh(prefix + count.to_bytes(4, "little"))


@pytest.mark.parametrize("name", ENUM_NAMES)
def test_unknown_enum_tags_are_rejected(name: str) -> None:
    known = {int(member) for member in ENUMS[name]}
    for tag in set(range(256)) - known:
        with pytest.raises(BorshDeserializationError):
            ENUM_WIRES[name].from_borsh(bytes([tag]))


def test_account_prefix_is_one_and_raw_status_remains_u8() -> None:
    case = example("channel")
    frozen = bytes.fromhex(case["hex"])
    assert len(frozen) == 256 and frozen[0] == 1
    cls = MODELS["channel"]
    decoded = cls.decode(frozen)
    assert decoded.to_borsh() == frozen
    without_tag = native_input(case["input"])
    without_tag.pop("discriminator")
    assert cls.model_validate(without_tag).to_borsh() == frozen
    # status is raw u8 in the IDL; accepting 255 is not a valid-state claim.
    raw_status = frozen[:3] + b"\xff" + frozen[4:]
    assert cls.decode(raw_status).status == 255
    assert cls.decode(raw_status).to_borsh() == raw_status
    for tag in (0, 2, 7, 255):
        with pytest.raises(ValidationError):
            cls.model_validate({**without_tag, "discriminator": tag})
        with pytest.raises(BorshDeserializationError):
            cls.from_borsh(bytes([tag]) + frozen[1:])


@pytest.mark.parametrize("case", FIXTURES["rejectedAccounts"], ids=lambda case: case["name"])
def test_original_rust_codec_tag_zero_is_not_an_account(case) -> None:
    # These unmodified early vectors encoded the incorrect generated Rust tag.
    frozen = bytes.fromhex(case["hex"])
    assert len(frozen) == 256 and frozen[0] == 0
    with pytest.raises(BorshDeserializationError):
        MODELS["channel"].from_borsh(frozen)


@pytest.mark.parametrize("case", FIXTURES["events"], ids=lambda case: case["name"])
def test_event_prefix_and_rust_payload(case) -> None:
    name = case["name"]
    cls = getattr(import_module(f"{PACKAGE}.events.{name}"), name[0].upper() + name[1:])
    value = native_input(case["input"])
    obj = cls.model_validate(value)
    frozen = bytes.fromhex(case["hex"])
    assert obj.discriminator == bytes(case["discriminator"])
    assert obj.to_borsh() == frozen
    assert MODELS[name].model_validate(value).to_borsh().hex() == case["payloadHex"]
    assert cls.from_borsh(frozen) == obj
    # The IDL hidden prefix is a constant and does not belong to the JSON payload.
    assert obj.to_json() == expected_json(case["input"])
    assert cls.from_json(obj.to_json()) == obj
    for length in range(len(frozen)):
        with pytest.raises(BorshDeserializationError):
            cls.from_borsh(frozen[:length])
    for invalid in (frozen + b"\x00", bytes(8) + frozen[8:]):
        with pytest.raises(BorshDeserializationError):
            cls.from_borsh(invalid)
    with pytest.raises(ValidationError):
        cls.model_validate({**value, "discriminator": bytes(8)})


def test_in_place_array_and_nested_model_mutations_are_revalidated() -> None:
    voucher = MODELS["voucherArgs"].model_validate(native_input(example("voucherArgs")["input"]))
    voucher.magic.append(0)
    with pytest.raises(ValidationError):
        voucher.to_borsh()
    case = next(case for case in CASES if case["kind"] == "openArgs" and case["input"]["recipients"])
    opened = MODELS["openArgs"].model_validate(native_input(case["input"]))
    object.__setattr__(opened.recipients[0], "bps", True)
    with pytest.raises(ValidationError):
        opened.to_borsh()
