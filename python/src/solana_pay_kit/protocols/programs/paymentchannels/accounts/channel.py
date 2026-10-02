# Generated from idl/payment-channels.json. Do not edit by hand.
from typing import Annotated, Self

from pyborsh import U8, Array
from pydantic import Field
from solana.rpc.async_api import AsyncClient
from solana.rpc.commitment import Commitment
from solders.pubkey import Pubkey

from solana_pay_kit._paycore.program_client import (
    Int64,
    PubkeyBytes,
    UInt8,
    UInt32,
    UInt64,
    WireModel,
    fetch_account,
    fetch_accounts,
)

from ..program_id import PAYMENT_CHANNELS_PROGRAM_ADDRESS
from ..types.settlementWatermarks import SettlementWatermarks


class Channel(WireModel):
    """Channel account including its leading account discriminator."""

    discriminator: Annotated[int, U8, Field(ge=1, le=1)] = 1
    version: UInt8
    bump: UInt8
    status: UInt8
    salt: UInt64
    deposit: UInt64
    settlement: SettlementWatermarks
    closureStartedAt: Int64
    payerWithdrawnAt: Int64
    gracePeriod: UInt32
    distributionHash: Annotated[list[UInt8], Array(U8, 32), Field(min_length=32, max_length=32)]
    payer: PubkeyBytes
    payee: PubkeyBytes
    authorizedSigner: PubkeyBytes
    mint: PubkeyBytes
    rentPayer: PubkeyBytes
    openSlot: UInt64

    @classmethod
    def decode(cls, data: bytes) -> Self:
        """Decode and validate the complete account bytes."""
        return cls.from_borsh(data)

    @classmethod
    async def fetch(
        cls,
        conn: AsyncClient,
        address: Pubkey,
        commitment: Commitment | None = None,
        program_id: Pubkey = PAYMENT_CHANNELS_PROGRAM_ADDRESS,
    ) -> Self | None:
        """Fetch one account and verify its owner and wire data."""
        return await fetch_account(cls, conn, address, commitment, program_id)

    @classmethod
    async def fetch_multiple(
        cls,
        conn: AsyncClient,
        addresses: list[Pubkey],
        commitment: Commitment | None = None,
        program_id: Pubkey = PAYMENT_CHANNELS_PROGRAM_ADDRESS,
    ) -> list[Self | None]:
        """Fetch ordered accounts, preserving missing account positions."""
        return await fetch_accounts(cls, conn, addresses, commitment, program_id)
