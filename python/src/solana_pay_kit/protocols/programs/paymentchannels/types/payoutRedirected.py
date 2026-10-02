# Generated from idl/payment-channels.json. Do not edit by hand.
from solana_pay_kit._paycore.program_client import PubkeyBytes, UInt64, WireModel

from .payoutBeneficiary import PayoutBeneficiary
from .redirectReason import RedirectReason


class PayoutRedirected(WireModel):
    """PayoutRedirected Borsh payload."""

    channel: PubkeyBytes
    owner: PubkeyBytes
    amount: UInt64
    beneficiary: PayoutBeneficiary
    reason: RedirectReason
