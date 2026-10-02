# Generated from idl/payment-channels.json. Do not edit by hand.
from typing import Annotated, TypedDict

from pyborsh import U8
from pydantic import Field
from solders.instruction import AccountMeta, Instruction
from solders.pubkey import Pubkey

from solana_pay_kit._paycore.program_client import WireModel

from ..program_id import PAYMENT_CHANNELS_PROGRAM_ADDRESS


class ReclaimAccounts(TypedDict):
    """Ordered account inputs for Reclaim."""

    channel: Pubkey
    rentPayer: Pubkey


class _InstructionData(WireModel):
    discriminator: Annotated[int, U8, Field(ge=9, le=9)] = 9


def Reclaim(
    accounts: ReclaimAccounts,
    program_id: Pubkey = PAYMENT_CHANNELS_PROGRAM_ADDRESS,
    remaining_accounts: list[AccountMeta] | None = None,
) -> Instruction:
    """Build the Reclaim instruction from validated Borsh arguments."""
    keys = [
        AccountMeta(
            pubkey=accounts["channel"],
            is_signer=False,
            is_writable=True,
        ),
        AccountMeta(
            pubkey=accounts["rentPayer"],
            is_signer=False,
            is_writable=True,
        ),
    ]
    if remaining_accounts is not None:
        keys.extend(remaining_accounts)
    data = _InstructionData().to_borsh()
    return Instruction(program_id, data, keys)
