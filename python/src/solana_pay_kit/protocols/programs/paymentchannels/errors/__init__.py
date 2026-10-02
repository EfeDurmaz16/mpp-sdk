# Generated from idl/payment-channels.json. Do not edit by hand.
from solana.rpc.core import RPCException
from solders.pubkey import Pubkey

from solana_pay_kit._paycore.program_client import program_error_code

from ..program_id import PAYMENT_CHANNELS_PROGRAM_ADDRESS
from .paymentChannels import CustomError, from_code


def from_tx_error(
    error: RPCException,
    program_id: Pubkey = PAYMENT_CHANNELS_PROGRAM_ADDRESS,
) -> CustomError | None:
    """Decode a custom error only when the failing program matches."""
    extracted = program_error_code(error, program_id)
    if extracted is None:
        return None
    return from_code(extracted[0], extracted[1])
