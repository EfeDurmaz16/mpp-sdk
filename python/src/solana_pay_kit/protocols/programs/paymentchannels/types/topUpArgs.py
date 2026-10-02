# Generated from idl/payment-channels.json. Do not edit by hand.
from solana_pay_kit._paycore.program_client import UInt64, WireModel


class TopUpArgs(WireModel):
    """TopUpArgs Borsh payload."""

    amount: UInt64
