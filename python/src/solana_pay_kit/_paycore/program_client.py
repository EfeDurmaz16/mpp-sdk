"""Validation and RPC helpers shared by generated native program clients."""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from typing import Annotated, Self, TypeVar

from pyborsh import I64, U8, U16, U32, U64, Borsh, Bytes
from pydantic import BaseModel, BeforeValidator, ConfigDict, Field, PlainSerializer, ValidationInfo
from solana.rpc.async_api import AsyncClient
from solana.rpc.commitment import Commitment
from solana.rpc.core import RPCException
from solders.pubkey import Pubkey
from solders.rpc.errors import SendTransactionPreflightFailureMessage
from solders.transaction_status import InstructionErrorCustom, TransactionErrorInstructionError

UInt8 = Annotated[int, U8, Field(ge=0, le=2**8 - 1)]
UInt16 = Annotated[int, U16, Field(ge=0, le=2**16 - 1)]
UInt32 = Annotated[int, U32, Field(ge=0, le=2**32 - 1)]
UInt64 = Annotated[int, U64, Field(ge=0, le=2**64 - 1)]
Int64 = Annotated[int, I64, Field(ge=-(2**63), le=2**63 - 1)]


def _pubkey_from_json(value: object, info: ValidationInfo) -> object:
    if info.mode == "json" and isinstance(value, str):
        return bytes(Pubkey.from_string(value))
    return value


def _pubkey_to_json(value: bytes) -> str:
    return str(Pubkey.from_bytes(value))


PubkeyBytes = Annotated[
    bytes,
    Bytes(32),
    Field(min_length=32, max_length=32),
    BeforeValidator(_pubkey_from_json),
    PlainSerializer(_pubkey_to_json, return_type=str, when_used="json"),
]


class WireModel(Borsh, BaseModel):
    """Strict generated fields, with binary encoding delegated to PyBorsh."""

    model_config = ConfigDict(
        strict=True,
        extra="forbid",
        validate_assignment=True,
        revalidate_instances="always",
    )

    def to_borsh(self) -> bytes:
        # Assignment validation cannot observe in-place list or nested mutations.
        validated = type(self).model_validate(self)
        return super(WireModel, validated).to_borsh()

    @classmethod
    def decode(cls, data: bytes) -> Self:
        return cls.from_borsh(data)

    def to_json(self) -> dict[str, object]:
        return type(self).model_validate(self).model_dump(mode="json")

    @classmethod
    def from_json(cls, value: dict[str, object]) -> Self:
        # JSON mode enables explicit base58 decoding without accepting Python strings.
        return cls.model_validate_json(json.dumps(value))


T = TypeVar("T", bound=WireModel)


async def fetch_account(
    model: type[T],
    conn: AsyncClient,
    address: Pubkey,
    commitment: Commitment | None,
    program_id: Pubkey,
) -> T | None:
    """Decode a present account only after verifying its owning program."""
    info = (await conn.get_account_info(address, commitment=commitment)).value
    if info is None:
        return None
    if info.owner != program_id:
        raise ValueError("Account does not belong to this program")
    return model.decode(info.data)


async def fetch_accounts(
    model: type[T],
    conn: AsyncClient,
    addresses: list[Pubkey],
    commitment: Commitment | None,
    program_id: Pubkey,
) -> list[T | None]:
    """Preserve request order and missing slots across RPC batches of at most 100."""
    result: list[T | None] = []
    for start in range(0, len(addresses), 100):
        batch = addresses[start : start + 100]
        infos = (await conn.get_multiple_accounts(batch, commitment=commitment)).value
        if len(infos) != len(batch):
            raise ValueError("RPC returned an unexpected number of accounts")
        for info in infos:
            if info is None:
                result.append(None)
            elif info.owner != program_id:
                raise ValueError("Account does not belong to this program")
            else:
                result.append(model.decode(info.data))
    return result


class ProgramError(Exception):
    """A generated program error with its custom code and optional RPC logs."""

    def __init__(self, code: int, msg: str, logs: list[str] | None = None) -> None:
        self.code = code
        self.msg = msg
        self.logs = logs
        super().__init__(f"{code}: {msg}")


_INVOKE = re.compile(r"Program ([1-9A-HJ-NP-Za-km-z]{32,44}) invoke \[([1-9]\d*)\]")
_FINISH = re.compile(r"Program ([1-9A-HJ-NP-Za-km-z]{32,44}) (success|failed: (.+))")
_CONTROL_PREFIX = re.compile(r"Program \S+ (?:invoke|success|failed)(?:\s|:|$)")
_CUSTOM_ERROR = re.compile(r"custom program error: (0x[0-9a-fA-F]+)")


@dataclass
class _Invocation:
    program: str
    child_failure: tuple[str | None, int | None] | None = None
    caught_codes: set[int] = field(default_factory=set)


def program_error_code(error: RPCException, program_id: Pubkey) -> tuple[int, list[str]] | None:
    """Resolve a typed custom error only when runtime logs identify its program.

    Equal errors propagated through CPI retain the child's attribution. A caller
    catching and independently reusing the same code is indistinguishable in logs,
    so it is conservatively attributed to the child rather than the caller.
    """
    if not error.args or not isinstance(error.args[0], SendTransactionPreflightFailureMessage):
        return None
    data = error.args[0].data
    if not isinstance(data.err, TransactionErrorInstructionError):
        return None
    instruction_error = data.err.err
    if not isinstance(instruction_error, InstructionErrorCustom) or not data.logs:
        return None

    stack: list[_Invocation] = []
    failure: tuple[str | None, int | None] | None = None
    for line in data.logs:
        if match := _INVOKE.fullmatch(line):
            if failure is not None or int(match[2]) != len(stack) + 1:
                return None
            if stack:
                # A subsequent invocation proves execution continued after any CPI failure.
                parent = stack[-1]
                if parent.child_failure is not None and parent.child_failure[1] is not None:
                    parent.caught_codes.add(parent.child_failure[1])
                parent.child_failure = None
            stack.append(_Invocation(match[1]))
        elif match := _FINISH.fullmatch(line):
            if failure is not None or not stack or stack[-1].program != match[1]:
                return None
            frame = stack.pop()
            if match[2] == "success":
                continue
            reason = match[3]
            custom_error = _CUSTOM_ERROR.fullmatch(reason)
            if custom_error is None and reason.startswith("custom program error:"):
                return None
            code = int(custom_error[1], 16) if custom_error is not None else None
            origin: str | None = frame.program
            if frame.child_failure is not None and frame.child_failure[1] == code:
                origin = frame.child_failure[0]
            elif code is not None and code in frame.caught_codes:
                # Reusing a caught code after further CPI execution has no clear origin.
                origin = None
            if stack:
                stack[-1].child_failure = (origin, code)
            else:
                failure = (origin, code)
        elif _CONTROL_PREFIX.match(line):
            return None

    if stack or failure is None or failure[0] != str(program_id):
        return None
    if failure[1] != instruction_error.code:
        return None
    return instruction_error.code, data.logs
