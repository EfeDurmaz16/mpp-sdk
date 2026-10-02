# Generated from idl/payment-channels.json. Do not edit by hand.
from typing import Annotated, NotRequired, TypedDict

from pyborsh import U8
from pydantic import Field
from solders.instruction import AccountMeta, Instruction
from solders.pubkey import Pubkey

from solana_pay_kit._paycore.program_client import WireModel

from ..pdas.index import find_event_authority_pda
from ..program_id import PAYMENT_CHANNELS_PROGRAM_ADDRESS
from ..types.distributeArgs import DistributeArgs as DistributeArgsValue


class DistributeArgs(TypedDict):
    """Arguments for Distribute."""

    distributeArgs: DistributeArgsValue


class DistributeAccounts(TypedDict):
    """Ordered account inputs for Distribute."""

    channel: Pubkey
    payer: Pubkey
    rentPayer: Pubkey
    channelTokenAccount: Pubkey
    payerTokenAccount: Pubkey
    payeeTokenAccount: Pubkey
    treasuryTokenAccount: Pubkey
    mint: Pubkey
    tokenProgram: Pubkey
    eventAuthority: NotRequired[Pubkey]
    selfProgram: NotRequired[Pubkey]


class _InstructionData(WireModel):
    discriminator: Annotated[int, U8, Field(ge=7, le=7)] = 7
    distributeArgs: DistributeArgsValue


def Distribute(
    args: DistributeArgs,
    accounts: DistributeAccounts,
    program_id: Pubkey = PAYMENT_CHANNELS_PROGRAM_ADDRESS,
    remaining_accounts: list[AccountMeta] | None = None,
) -> Instruction:
    """Build the Distribute instruction from validated Borsh arguments."""
    keys = [
        AccountMeta(
            pubkey=accounts["channel"],
            is_signer=False,
            is_writable=True,
        ),
        AccountMeta(
            pubkey=accounts["payer"],
            is_signer=False,
            is_writable=True,
        ),
        AccountMeta(
            pubkey=accounts["rentPayer"],
            is_signer=False,
            is_writable=True,
        ),
        AccountMeta(
            pubkey=accounts["channelTokenAccount"],
            is_signer=False,
            is_writable=True,
        ),
        AccountMeta(
            pubkey=accounts["payerTokenAccount"],
            is_signer=False,
            is_writable=True,
        ),
        AccountMeta(
            pubkey=accounts["payeeTokenAccount"],
            is_signer=False,
            is_writable=True,
        ),
        AccountMeta(
            pubkey=accounts["treasuryTokenAccount"],
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
        AccountMeta(
            pubkey=accounts.get("eventAuthority", find_event_authority_pda(program_id)[0]),
            is_signer=False,
            is_writable=False,
        ),
        AccountMeta(
            pubkey=accounts.get("selfProgram", Pubkey.from_string("CHNLxYvVA28MJP9PrFuDXccuoGXAx7jBacfLEkahyGsX")),
            is_signer=False,
            is_writable=False,
        ),
    ]
    if remaining_accounts is not None:
        keys.extend(remaining_accounts)
    data = _InstructionData(
        distributeArgs=args["distributeArgs"],
    ).to_borsh()
    return Instruction(program_id, data, keys)
