# Generated from idl/payment-channels.json. Do not edit by hand.
from enum import IntEnum


class ChannelStatus(IntEnum):
    """ChannelStatus wire tags from the IDL."""

    Open = 0
    Sealed = 1
    Closing = 2
    Distributed = 3
