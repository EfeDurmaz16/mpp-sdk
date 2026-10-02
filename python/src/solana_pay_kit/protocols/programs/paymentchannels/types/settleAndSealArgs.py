# Generated from idl/payment-channels.json. Do not edit by hand.
from solana_pay_kit._paycore.program_client import UInt8, WireModel


class SettleAndSealArgs(WireModel):
    """SettleAndSealArgs Borsh payload."""

    hasVoucher: UInt8
