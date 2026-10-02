# Generated from idl/payment-channels.json. Do not edit by hand.
from typing import Annotated, NotRequired, TypedDict

from pyborsh import U8
from pydantic import Field
from solders.instruction import AccountMeta, Instruction
from solders.pubkey import Pubkey

from solana_pay_kit._paycore.program_client import WireModel

from ..pdas.index import find_event_authority_pda
from ..program_id import PAYMENT_CHANNELS_PROGRAM_ADDRESS


class EmitEventAccounts(TypedDict):
    """Ordered account inputs for EmitEvent."""

    eventAuthority: NotRequired[Pubkey]


class _InstructionData(WireModel):
    discriminator: Annotated[int, U8, Field(ge=228, le=228)] = 228


def EmitEvent(
    accounts: EmitEventAccounts,
    program_id: Pubkey = PAYMENT_CHANNELS_PROGRAM_ADDRESS,
    remaining_accounts: list[AccountMeta] | None = None,
) -> Instruction:
    """Build the EmitEvent instruction from validated Borsh arguments."""
    keys = [
        AccountMeta(
            pubkey=accounts.get("eventAuthority", find_event_authority_pda(program_id)[0]),
            is_signer=True,
            is_writable=False,
        ),
    ]
    if remaining_accounts is not None:
        keys.extend(remaining_accounts)
    data = _InstructionData().to_borsh()
    return Instruction(program_id, data, keys)
