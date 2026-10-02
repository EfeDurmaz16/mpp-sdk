# Generated from idl/payment-channels.json. Do not edit by hand.
from solana_pay_kit._paycore.program_client import UInt32, UInt64, WireModel

from .distributionEntry import DistributionEntry


class OpenArgs(WireModel):
    """OpenArgs Borsh payload."""

    salt: UInt64
    deposit: UInt64
    gracePeriod: UInt32
    openSlot: UInt64
    recipients: list[DistributionEntry]
