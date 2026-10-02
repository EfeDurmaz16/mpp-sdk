"""Native generated-client validation, account RPC, and error attribution contracts."""

from __future__ import annotations

import struct
from enum import IntEnum
from typing import Annotated, cast
from unittest.mock import AsyncMock, create_autospec

import pytest
from pyborsh import U8, Array, BorshDeserializationError
from pydantic import Field, ValidationError
from solana.rpc.async_api import AsyncClient
from solana.rpc.commitment import Confirmed
from solana.rpc.core import RPCException
from solders.account import Account
from solders.pubkey import Pubkey
from solders.rpc.errors import SendTransactionPreflightFailureMessage
from solders.rpc.responses import (
    GetAccountInfoResp,
    GetMultipleAccountsResp,
    RpcResponseContext,
    RpcSimulateTransactionResult,
)
from solders.transaction_status import (
    InstructionErrorCustom,
    InstructionErrorFieldless,
    TransactionErrorFieldless,
    TransactionErrorInstructionError,
)

from solana_pay_kit._paycore.program_client import (
    Int64,
    ProgramError,
    PubkeyBytes,
    UInt8,
    UInt16,
    UInt32,
    UInt64,
    WireModel,
    fetch_account,
    fetch_accounts,
    program_error_code,
)

PROGRAM = Pubkey.from_bytes(bytes([1]) * 32)
FOREIGN = Pubkey.from_bytes(bytes([2]) * 32)
ADDRESS = Pubkey.from_bytes(bytes([3]) * 32)
CONTEXT = RpcResponseContext(42)


class _Numbers(WireModel):
    u8: UInt8 = 1
    u16: UInt16 = 2
    u32: UInt32 = 3
    u64: UInt64 = 4
    i64: Int64 = -5


class _Status(IntEnum):
    OPEN = 0
    CLOSED = 1


class _Record(WireModel):
    key: PubkeyBytes
    status: _Status
    numbers: _Numbers
    values: Annotated[list[UInt8], Array(U8, 2), Field(min_length=2, max_length=2)]


class _Account(WireModel):
    amount: UInt16


def _record() -> _Record:
    return _Record(key=bytes(PROGRAM), status=_Status.CLOSED, numbers=_Numbers(), values=[0, 255])


def test_wire_encoding_matches_explicit_layout_and_json_base58() -> None:
    record = _record()
    expected = bytes(PROGRAM) + b"\x01" + struct.pack("<BHIQq", 1, 2, 3, 4, -5) + b"\x00\xff"
    assert record.to_borsh() == expected
    assert _Record.decode(expected) == record
    assert record.model_dump()["key"] == bytes(PROGRAM)
    value = record.to_json()
    assert value == {
        "key": str(PROGRAM),
        "status": 1,
        "numbers": {"u8": 1, "u16": 2, "u32": 3, "u64": 4, "i64": -5},
        "values": [0, 255],
    }
    assert _Record.from_json(value) == record
    value["key"] = str(Pubkey.default())
    # Thirty-two base58 '1' characters represent zero bytes, never ASCII '1' bytes.
    assert _Record.from_json(value).key == bytes(32)


@pytest.mark.parametrize(
    "field,bits,signed",
    [("u8", 8, False), ("u16", 16, False), ("u32", 32, False), ("u64", 64, False), ("i64", 64, True)],
)
def test_integer_widths_and_strict_input(field: str, bits: int, signed: bool) -> None:
    lower = -(2 ** (bits - 1)) if signed else 0
    upper = 2 ** (bits - int(signed)) - 1
    for boundary in (lower, upper):
        assert getattr(_Numbers.model_validate({field: boundary}), field) == boundary
    for invalid in (lower - 1, upper + 1, "1", 1.0, True):
        with pytest.raises(ValidationError):
            _Numbers.model_validate({field: invalid})
        with pytest.raises(ValidationError):
            _Numbers.from_json({field: invalid})


@pytest.mark.parametrize("invalid", [b"", bytes(31), bytes(33), bytearray(32), "1" * 32, str(PROGRAM)])
def test_python_pubkeys_require_exact_bytes(invalid: object) -> None:
    with pytest.raises(ValidationError):
        _Record.model_validate({**_record().model_dump(), "key": invalid})


@pytest.mark.parametrize(
    "field,value",
    [
        ("key", "0" * 32),
        ("key", "1" * 31),
        ("key", "1" * 33),
        ("key", 7),
        ("status", "1"),
        ("status", 2),
        ("values", [0]),
        ("values", [0, 256]),
        ("extra", 1),
    ],
)
def test_json_rejects_malformed_fields(field: str, value: object) -> None:
    with pytest.raises(ValidationError):
        _Record.from_json({**_record().to_json(), field: value})


def test_assignment_rejects_invalid_integer() -> None:
    record = _record()
    with pytest.raises(ValidationError):
        record.numbers.u8 = 256


@pytest.mark.parametrize("mutation", ["list_length", "list_value", "nested"])
def test_in_place_mutations_cannot_emit_invalid_wire(mutation: str) -> None:
    record = _record()
    if mutation == "list_length":
        record.values.append(1)
    elif mutation == "list_value":
        record.values[0] = True
    else:
        # model_copy deliberately skips validation; the wire boundary must catch it.
        object.__setattr__(record, "numbers", record.numbers.model_copy(update={"u64": True}))
    with pytest.raises(ValidationError):
        record.to_borsh()
    with pytest.raises(ValidationError):
        record.to_json()


@pytest.mark.parametrize("payload", [b"", b"\x01", b"\x01\x00\x00"])
def test_decode_rejects_truncation_and_trailing_bytes(payload: bytes) -> None:
    with pytest.raises(BorshDeserializationError):
        _Account.decode(payload)


def _rpc() -> tuple[AsyncClient, AsyncMock, AsyncMock]:
    client = create_autospec(AsyncClient, instance=True)
    return cast(AsyncClient, client), client.get_account_info, client.get_multiple_accounts


async def _fetch(client: AsyncClient, multiple: bool) -> _Account | list[_Account | None] | None:
    if multiple:
        return await fetch_accounts(_Account, client, [ADDRESS], Confirmed, PROGRAM)
    return await fetch_account(_Account, client, ADDRESS, Confirmed, PROGRAM)


@pytest.mark.parametrize("multiple", [False, True])
@pytest.mark.parametrize("missing", [False, True])
async def test_fetch_decodes_and_preserves_missing_accounts(multiple: bool, missing: bool) -> None:
    client, single, batch = _rpc()
    info = None if missing else Account(1, b"\x34\x12", PROGRAM)
    single.return_value = GetAccountInfoResp(info, CONTEXT)
    batch.return_value = GetMultipleAccountsResp([info], CONTEXT)
    expected = None if missing else _Account(amount=0x1234)
    assert await _fetch(client, multiple) == ([expected] if multiple else expected)
    if multiple:
        batch.assert_awaited_once_with([ADDRESS], commitment=Confirmed)
    else:
        single.assert_awaited_once_with(ADDRESS, commitment=Confirmed)


@pytest.mark.parametrize("size", [0, 1, 100, 101, 300, 301])
async def test_fetch_batches_at_rpc_limit_with_order_and_missing_slots(size: int) -> None:
    client, single, batch = _rpc()
    addresses = [Pubkey.from_bytes(index.to_bytes(32, "little")) for index in range(size)]
    infos = [None if index % 7 == 0 else Account(1, struct.pack("<H", index), PROGRAM) for index in range(size)]
    batch.side_effect = [GetMultipleAccountsResp(infos[start : start + 100], CONTEXT) for start in range(0, size, 100)]
    result = await fetch_accounts(_Account, client, addresses, None, PROGRAM)
    assert [None if value is None else value.amount for value in result] == [
        None if index % 7 == 0 else index for index in range(size)
    ]
    assert batch.await_count == (size + 99) // 100
    assert [call.args[0] for call in batch.await_args_list] == [
        addresses[start : start + 100] for start in range(0, size, 100)
    ]
    assert all(call.kwargs == {"commitment": None} for call in batch.await_args_list)
    single.assert_not_awaited()


@pytest.mark.parametrize("multiple", [False, True])
@pytest.mark.parametrize("wrong_owner", [False, True])
async def test_fetch_rejects_foreign_owner_and_malformed_data(multiple: bool, wrong_owner: bool) -> None:
    client, single, batch = _rpc()
    info = Account(1, b"\x00\x00" if wrong_owner else b"", FOREIGN if wrong_owner else PROGRAM)
    single.return_value = GetAccountInfoResp(info, CONTEXT)
    batch.return_value = GetMultipleAccountsResp([info], CONTEXT)
    expected_error = ValueError if wrong_owner else BorshDeserializationError
    with pytest.raises(expected_error, match="Account does not belong" if wrong_owner else None):
        await _fetch(client, multiple)


@pytest.mark.parametrize("count", [0, 2])
async def test_fetch_rejects_response_cardinality_mismatch(count: int) -> None:
    client, _, batch = _rpc()
    batch.return_value = GetMultipleAccountsResp([None] * count, CONTEXT)
    with pytest.raises(ValueError, match="unexpected number"):
        await _fetch(client, True)


@pytest.mark.parametrize("multiple", [False, True])
async def test_fetch_propagates_rpc_failure(multiple: bool) -> None:
    client, single, batch = _rpc()
    failure = RPCException("unavailable")
    single.side_effect = failure
    batch.side_effect = failure
    with pytest.raises(RPCException) as caught:
        await _fetch(client, multiple)
    assert caught.value is failure


def _error(logs: list[str] | None, code: int = 2) -> RPCException:
    return RPCException(
        SendTransactionPreflightFailureMessage(
            "simulation failed",
            RpcSimulateTransactionResult(
                err=TransactionErrorInstructionError(0, InstructionErrorCustom(code)),
                logs=logs,
            ),
        )
    )


def _invoke(program: Pubkey, depth: int = 1) -> str:
    return f"Program {program} invoke [{depth}]"


def _failed(program: Pubkey, code: int = 2) -> str:
    return f"Program {program} failed: custom program error: {code:#x}"


def test_program_error_attributes_and_message() -> None:
    logs = [_invoke(PROGRAM), _failed(PROGRAM)]
    error = ProgramError(2, "Already closed", logs)
    assert (error.code, error.msg, error.logs, str(error)) == (2, "Already closed", logs, "2: Already closed")
    assert ProgramError(2, "Already closed").logs is None


@pytest.mark.parametrize("code", [0, 2, 65535])
def test_custom_error_requires_matching_rpc_code(code: int) -> None:
    logs = [_invoke(PROGRAM), _failed(PROGRAM, code)]
    assert program_error_code(_error(logs, code), PROGRAM) == (code, logs)
    assert program_error_code(_error(logs, code + 1), PROGRAM) is None


@pytest.mark.parametrize(
    "child,parent,child_code,parent_code,expected",
    [
        (FOREIGN, PROGRAM, 2, 2, False),
        (PROGRAM, FOREIGN, 2, 2, True),
        (FOREIGN, PROGRAM, 1, 2, True),
        (PROGRAM, PROGRAM, 2, 2, True),
    ],
)
def test_cpi_failure_origin_is_preserved(
    child: Pubkey,
    parent: Pubkey,
    child_code: int,
    parent_code: int,
    expected: bool,
) -> None:
    logs = [_invoke(parent), _invoke(child, 2), _failed(child, child_code), _failed(parent, parent_code)]
    result = program_error_code(_error(logs, parent_code), PROGRAM)
    assert result == ((parent_code, logs) if expected else None)


def test_caught_cpi_failure_does_not_contaminate_later_instruction() -> None:
    logs = [
        _invoke(FOREIGN),
        _invoke(PROGRAM, 2),
        _failed(PROGRAM),
        f"Program {FOREIGN} success",
        _invoke(FOREIGN),
        _failed(FOREIGN),
    ]
    assert program_error_code(_error(logs), PROGRAM) is None
    logs[-2:] = [_invoke(PROGRAM), _failed(PROGRAM)]
    assert program_error_code(_error(logs), PROGRAM) == (2, logs)


@pytest.mark.parametrize("caught_code", [1, 2])
def test_code_reused_after_caught_cpi_and_continued_execution_is_ambiguous(caught_code: int) -> None:
    logs = [
        _invoke(PROGRAM),
        _invoke(FOREIGN, 2),
        _failed(FOREIGN, caught_code),
        _invoke(FOREIGN, 2),
        f"Program {FOREIGN} success",
        _failed(PROGRAM),
    ]
    assert program_error_code(_error(logs), PROGRAM) == (None if caught_code == 2 else (2, logs))


def test_equal_numeric_cpi_codes_with_different_hex_format_preserve_origin() -> None:
    logs = [
        _invoke(PROGRAM),
        _invoke(FOREIGN, 2),
        f"Program {FOREIGN} failed: custom program error: 0x02",
        _failed(PROGRAM),
    ]
    assert program_error_code(_error(logs), PROGRAM) is None


def test_successful_cpi_and_program_messages_do_not_spoof_failure() -> None:
    logs = [
        _invoke(PROGRAM),
        _invoke(FOREIGN, 2),
        f"Program {FOREIGN} success",
        f"Program log: {_failed(FOREIGN)}",
        f"Program log: spoof\n{_failed(FOREIGN)}",
        f"Program {PROGRAM} consumed 20 of 200000 compute units",
        _failed(PROGRAM),
    ]
    assert program_error_code(_error(logs), PROGRAM) == (2, logs)


@pytest.mark.parametrize(
    "logs",
    [
        None,
        [],
        [_failed(PROGRAM)],
        [_invoke(PROGRAM)],
        [_invoke(PROGRAM, 2), _failed(PROGRAM)],
        [_invoke(PROGRAM), _failed(FOREIGN)],
        [_invoke(PROGRAM), f"Program {PROGRAM} success"],
        [_invoke(PROGRAM), _failed(PROGRAM), _invoke(FOREIGN)],
        [_invoke(PROGRAM), _failed(PROGRAM), _failed(PROGRAM)],
        [_invoke(PROGRAM), f"Program {PROGRAM} failed: invalid account data"],
        [_invoke(PROGRAM), f"Program {PROGRAM} failed: custom program error: nope"],
        [_invoke(PROGRAM), f"Program {FOREIGN} invoke [invalid]", _failed(PROGRAM)],
    ],
)
def test_missing_incomplete_or_malformed_logs_fail_closed(logs: list[str] | None) -> None:
    assert program_error_code(_error(logs), PROGRAM) is None


@pytest.mark.parametrize(
    "error",
    [
        RPCException(),
        RPCException("custom program error: 0x2"),
        RPCException({"data": {"err": {"InstructionError": [0, {"Custom": 2}]}}}),
        RPCException(SendTransactionPreflightFailureMessage("failed", RpcSimulateTransactionResult())),
        RPCException(
            SendTransactionPreflightFailureMessage(
                "failed",
                RpcSimulateTransactionResult(
                    err=TransactionErrorFieldless.AccountNotFound,
                ),
            )
        ),
        RPCException(
            SendTransactionPreflightFailureMessage(
                "failed",
                RpcSimulateTransactionResult(
                    err=TransactionErrorInstructionError(0, InstructionErrorFieldless.InvalidAccountData),
                ),
            )
        ),
    ],
)
def test_only_typed_custom_preflight_errors_are_decoded(error: RPCException) -> None:
    assert program_error_code(error, PROGRAM) is None
