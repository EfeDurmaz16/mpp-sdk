# Generated from idl/payment-channels.json. Do not edit by hand.
from solana_pay_kit._paycore.program_client import WireModel

from .distributionEntry import DistributionEntry


class DistributeArgs(WireModel):
    """DistributeArgs Borsh payload."""

    recipients: list[DistributionEntry]
