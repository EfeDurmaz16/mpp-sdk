# Generated from idl/payment-channels.json. Do not edit by hand.
from typing import Annotated, TypedDict

from pyborsh import U8
from pydantic import Field
from solders.instruction import AccountMeta, Instruction
from solders.pubkey import Pubkey

from solana_pay_kit._paycore.program_client import WireModel

from ..program_id import PAYMENT_CHANNELS_PROGRAM_ADDRESS
from ..types.settleAndSealArgs import SettleAndSealArgs as SettleAndSealArgsValue


class SettleAndSealArgs(TypedDict):
    """Arguments for SettleAndSeal."""

    settleAndSealArgs: SettleAndSealArgsValue


class SettleAndSealAccounts(TypedDict):
    """Ordered account inputs for SettleAndSeal."""

    payee: Pubkey
    channel: Pubkey
    instructionsSysvar: Pubkey


class _InstructionData(WireModel):
    discriminator: Annotated[int, U8, Field(ge=4, le=4)] = 4
    settleAndSealArgs: SettleAndSealArgsValue


def SettleAndSeal(
    args: SettleAndSealArgs,
    accounts: SettleAndSealAccounts,
    program_id: Pubkey = PAYMENT_CHANNELS_PROGRAM_ADDRESS,
    remaining_accounts: list[AccountMeta] | None = None,
) -> Instruction:
    """Build the SettleAndSeal instruction from validated Borsh arguments."""
    keys = [
        AccountMeta(
            pubkey=accounts["payee"],
            is_signer=True,
            is_writable=False,
        ),
        AccountMeta(
            pubkey=accounts["channel"],
            is_signer=False,
            is_writable=True,
        ),
        AccountMeta(
            pubkey=accounts["instructionsSysvar"],
            is_signer=False,
            is_writable=False,
        ),
    ]
    if remaining_accounts is not None:
        keys.extend(remaining_accounts)
    data = _InstructionData(
        settleAndSealArgs=args["settleAndSealArgs"],
    ).to_borsh()
    return Instruction(program_id, data, keys)
