# Generated from idl/payment-channels.json. Do not edit by hand.
from typing import Annotated, NotRequired, TypedDict

from pyborsh import U8
from pydantic import Field
from solders.instruction import AccountMeta, Instruction
from solders.pubkey import Pubkey

from solana_pay_kit._paycore.program_client import WireModel

from ..pdas.index import find_event_authority_pda
from ..program_id import PAYMENT_CHANNELS_PROGRAM_ADDRESS
from ..types.openArgs import OpenArgs as OpenArgsValue


class OpenArgs(TypedDict):
    """Arguments for Open."""

    openArgs: OpenArgsValue


class OpenAccounts(TypedDict):
    """Ordered account inputs for Open."""

    payer: Pubkey
    rentPayer: Pubkey
    payee: Pubkey
    mint: Pubkey
    authorizedSigner: Pubkey
    channel: Pubkey
    payerTokenAccount: Pubkey
    channelTokenAccount: Pubkey
    tokenProgram: Pubkey
    systemProgram: NotRequired[Pubkey]
    rent: Pubkey
    associatedTokenProgram: Pubkey
    eventAuthority: NotRequired[Pubkey]
    selfProgram: NotRequired[Pubkey]


class _InstructionData(WireModel):
    discriminator: Annotated[int, U8, Field(ge=1, le=1)] = 1
    openArgs: OpenArgsValue


def Open(
    args: OpenArgs,
    accounts: OpenAccounts,
    program_id: Pubkey = PAYMENT_CHANNELS_PROGRAM_ADDRESS,
    remaining_accounts: list[AccountMeta] | None = None,
) -> Instruction:
    """Build the Open instruction from validated Borsh arguments."""
    keys = [
        AccountMeta(
            pubkey=accounts["payer"],
            is_signer=True,
            is_writable=True,
        ),
        AccountMeta(
            pubkey=accounts["rentPayer"],
            is_signer=True,
            is_writable=True,
        ),
        AccountMeta(
            pubkey=accounts["payee"],
            is_signer=False,
            is_writable=False,
        ),
        AccountMeta(
            pubkey=accounts["mint"],
            is_signer=False,
            is_writable=False,
        ),
        AccountMeta(
            pubkey=accounts["authorizedSigner"],
            is_signer=False,
            is_writable=False,
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
            pubkey=accounts["tokenProgram"],
            is_signer=False,
            is_writable=False,
        ),
        AccountMeta(
            pubkey=accounts.get("systemProgram", Pubkey.from_string("11111111111111111111111111111111")),
            is_signer=False,
            is_writable=False,
        ),
        AccountMeta(
            pubkey=accounts["rent"],
            is_signer=False,
            is_writable=False,
        ),
        AccountMeta(
            pubkey=accounts["associatedTokenProgram"],
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
        openArgs=args["openArgs"],
    ).to_borsh()
    return Instruction(program_id, data, keys)
