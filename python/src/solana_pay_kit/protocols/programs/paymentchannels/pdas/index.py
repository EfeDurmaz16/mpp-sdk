# Generated from idl/payment-channels.json. Do not edit by hand.
from solders.pubkey import Pubkey

from ..program_id import PAYMENT_CHANNELS_PROGRAM_ADDRESS


def find_event_authority_pda(
    program_id: Pubkey = PAYMENT_CHANNELS_PROGRAM_ADDRESS,
) -> tuple[Pubkey, int]:
    """Derive the event authority for the selected program."""
    return Pubkey.find_program_address([bytes.fromhex("6576656e745f617574686f72697479")], program_id)
