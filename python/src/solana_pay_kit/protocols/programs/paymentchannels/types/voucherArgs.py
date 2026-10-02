# Generated from idl/payment-channels.json. Do not edit by hand.
from typing import Annotated

from pyborsh import U8, Array
from pydantic import Field

from solana_pay_kit._paycore.program_client import Int64, PubkeyBytes, UInt8, UInt64, WireModel


class VoucherArgs(WireModel):
    """VoucherArgs Borsh payload."""

    magic: Annotated[list[UInt8], Array(U8, 2), Field(min_length=2, max_length=2)]
    channelId: PubkeyBytes
    cumulativeAmount: UInt64
    expiresAt: Int64
