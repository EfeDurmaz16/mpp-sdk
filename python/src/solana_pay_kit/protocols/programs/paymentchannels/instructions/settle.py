# Generated from idl/payment-channels.json. Do not edit by hand.
from typing import Annotated, TypedDict

from pyborsh import U8
from pydantic import Field
from solders.instruction import AccountMeta, Instruction
from solders.pubkey import Pubkey

from solana_pay_kit._paycore.program_client import WireModel

from ..program_id import PAYMENT_CHANNELS_PROGRAM_ADDRESS


class SettleAccounts(TypedDict):
    """Ordered account inputs for Settle."""

    channel: Pubkey
    instructionsSysvar: Pubkey


class _InstructionData(WireModel):
    discriminator: Annotated[int, U8, Field(ge=2, le=2)] = 2


def Settle(
    accounts: SettleAccounts,
    program_id: Pubkey = PAYMENT_CHANNELS_PROGRAM_ADDRESS,
    remaining_accounts: list[AccountMeta] | None = None,
) -> Instruction:
    """Build the Settle instruction from validated Borsh arguments."""
    keys = [
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
    data = _InstructionData().to_borsh()
    return Instruction(program_id, data, keys)
