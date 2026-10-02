# Generated from idl/payment-channels.json. Do not edit by hand.
from solana_pay_kit._paycore.program_client import PubkeyBytes, UInt64, WireModel


class Opened(WireModel):
    """Opened Borsh payload."""

    channel: PubkeyBytes
    openSlot: UInt64
