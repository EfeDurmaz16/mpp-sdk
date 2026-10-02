# Generated from idl/payment-channels.json. Do not edit by hand.
from solana_pay_kit._paycore.program_client import UInt64, WireModel


class SettlementWatermarks(WireModel):
    """SettlementWatermarks Borsh payload."""

    settled: UInt64
    payoutWatermark: UInt64
