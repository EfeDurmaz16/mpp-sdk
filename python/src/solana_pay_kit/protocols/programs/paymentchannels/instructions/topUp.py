# Generated from idl/payment-channels.json. Do not edit by hand.
from typing import Annotated, TypedDict

from pyborsh import U8
from pydantic import Field
from solders.instruction import AccountMeta, Instruction
from solders.pubkey import Pubkey

from solana_pay_kit._paycore.program_client import WireModel

from ..program_id import PAYMENT_CHANNELS_PROGRAM_ADDRESS
from ..types.topUpArgs import TopUpArgs as TopUpArgsValue


class TopUpArgs(TypedDict):
    """Arguments for TopUp."""

    topUpArgs: TopUpArgsValue


class TopUpAccounts(TypedDict):
    """Ordered account inputs for TopUp."""

    payer: Pubkey
    channel: Pubkey
    payerTokenAccount: Pubkey
    channelTokenAccount: Pubkey
    mint: Pubkey
    tokenProgram: Pubkey


class _InstructionData(WireModel):
    discriminator: Annotated[int, U8, Field(ge=3, le=3)] = 3
    topUpArgs: TopUpArgsValue


def TopUp(
    args: TopUpArgs,
    accounts: TopUpAccounts,
    program_id: Pubkey = PAYMENT_CHANNELS_PROGRAM_ADDRESS,
    remaining_accounts: list[AccountMeta] | None = None,
) -> Instruction:
    """Build the TopUp instruction from validated Borsh arguments."""
    keys = [
        AccountMeta(
            pubkey=accounts["payer"],
            is_signer=True,
            is_writable=True,
        ),
        AccountMeta(
            pubkey=accounts["channel"],
            is_signer=False,
            is_writable=True,
        ),
        AccountMeta(
            pubkey=accounts["payerTokenAccount"],
            is_signer=False,
            is_writable=True,
        ),
        AccountMeta(
            pubkey=accounts["channelTokenAccount"],
            is_signer=False,
            is_writable=True,
        ),
        AccountMeta(
            pubkey=accounts["mint"],
            is_signer=False,
            is_writable=False,
        ),
        AccountMeta(
            pubkey=accounts["tokenProgram"],
            is_signer=False,
            is_writable=False,
        ),
    ]
    if remaining_accounts is not None:
        keys.extend(remaining_accounts)
    data = _InstructionData(
        topUpArgs=args["topUpArgs"],
    ).to_borsh()
    return Instruction(program_id, data, keys)
