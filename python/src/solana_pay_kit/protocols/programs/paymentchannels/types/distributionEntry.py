# Generated from idl/payment-channels.json. Do not edit by hand.
from solana_pay_kit._paycore.program_client import PubkeyBytes, UInt16, WireModel


class DistributionEntry(WireModel):
    """DistributionEntry Borsh payload."""

    recipient: PubkeyBytes
    bps: UInt16
