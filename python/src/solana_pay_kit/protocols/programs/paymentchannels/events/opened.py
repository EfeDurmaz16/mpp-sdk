# Generated from idl/payment-channels.json. Do not edit by hand.
from typing import Annotated

from pyborsh import Bytes
from pydantic import Field, field_validator

from solana_pay_kit._paycore.program_client import PubkeyBytes, UInt64, WireModel

DISCRIMINATOR = bytes.fromhex("a6ac61094d4cbd6d")


class Opened(WireModel):
    """Opened event including its constant wire prefix."""

    discriminator: Annotated[bytes, Bytes(8), Field(min_length=8, max_length=8, exclude=True, repr=False)] = (
        DISCRIMINATOR
    )
    channel: PubkeyBytes
    openSlot: UInt64

    @field_validator("discriminator")
    @classmethod
    def _validate_discriminator(cls, value: bytes) -> bytes:
        if value != DISCRIMINATOR:
            raise ValueError("Invalid event discriminator")
        return value
