# Generated from idl/payment-channels.json. Do not edit by hand.
from enum import IntEnum


class PayoutBeneficiary(IntEnum):
    """PayoutBeneficiary wire tags from the IDL."""

    Recipient = 0
    Payee = 1
    Payer = 2
