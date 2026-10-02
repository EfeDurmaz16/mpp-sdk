# Generated from idl/payment-channels.json. Do not edit by hand.
from enum import IntEnum


class RedirectReason(IntEnum):
    """RedirectReason wire tags from the IDL."""

    UnsupportedExtension = 0
    ClosedOrMalformed = 1
    NotInitialized = 2
    ReassignedAuthority = 3
