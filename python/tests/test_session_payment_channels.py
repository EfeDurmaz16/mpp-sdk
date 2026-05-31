"""Golden-vector tests for the payment-channels program helpers.

These byte-layout assertions are the load-bearing parity contract with the
Rust spine (``rust/crates/mpp/src/program/payment_channels.rs``) and the
on-chain program. Interop byte-parity against other languages can only be
fully validated in CI (surfpool); these golden vectors prove parity locally.
"""

from __future__ import annotations

import blake3
from solders.pubkey import Pubkey

from solana_mpp.protocol.payment_channels import (
    CHANNEL_SEED,
    PAYMENT_CHANNELS_PROGRAM_ID,
    Distribution,
    default_program_id,
    distribution_hash,
    find_channel_pda,
    voucher_message_bytes,
)


def _pk(byte: int) -> str:
    return str(Pubkey(bytes([byte] * 32)))


def test_voucher_message_is_program_borsh_layout():
    """Layout: channel_id(32) || cumulative(u64 LE) || expires_at(i64 LE) = 48."""
    raw = voucher_message_bytes(_pk(9), 42, 1234)
    assert len(raw) == 48
    assert raw[:32] == bytes([9] * 32)
    assert raw[32:40] == (42).to_bytes(8, "little")
    assert raw[40:48] == (1234).to_bytes(8, "little", signed=True)


def test_voucher_message_golden_hex():
    # Frozen golden: deterministic byte string for channel pk(9), cumulative
    # 42, expires_at 1234. Any change to the signing layout breaks signatures
    # against the on-chain program.
    raw = voucher_message_bytes(_pk(9), 42, 1234)
    expected = "09" * 32 + "2a00000000000000" + "d204000000000000"
    assert raw.hex() == expected


def test_voucher_message_handles_negative_expiry():
    raw = voucher_message_bytes(_pk(1), 0, -1)
    assert raw[40:48] == (-1).to_bytes(8, "little", signed=True)


def test_voucher_message_differs_by_cumulative():
    a = voucher_message_bytes(_pk(6), 100, 42)
    b = voucher_message_bytes(_pk(6), 200, 42)
    assert a != b


def test_distribution_hash_matches_blake3_preimage_shape():
    recipients = [Distribution(_pk(1), 7_500), Distribution(_pk(2), 2_500)]
    hasher = blake3.blake3()
    hasher.update((2).to_bytes(4, "little"))
    hasher.update(bytes([1] * 32))
    hasher.update((7_500).to_bytes(2, "little"))
    hasher.update(bytes([2] * 32))
    hasher.update((2_500).to_bytes(2, "little"))
    assert distribution_hash(recipients) == hasher.digest()


def test_distribution_hash_golden_hex():
    recipients = [Distribution(_pk(1), 7_500), Distribution(_pk(2), 2_500)]
    assert distribution_hash(recipients).hex() == "2c00d870359f0a4861c420eaeffdf7a7d6b2cd281024ee69e1f12f743e04c416"


def test_distribution_hash_empty_recipients():
    hasher = blake3.blake3()
    hasher.update((0).to_bytes(4, "little"))
    assert distribution_hash([]) == hasher.digest()


def test_channel_pda_is_stable_and_recreatable():
    program_id = default_program_id()
    assert program_id == PAYMENT_CHANNELS_PROGRAM_ID
    channel, bump = find_channel_pda(_pk(1), _pk(2), _pk(3), _pk(4), 99)
    seeds = [
        CHANNEL_SEED,
        bytes([1] * 32),
        bytes([2] * 32),
        bytes([3] * 32),
        bytes([4] * 32),
        (99).to_bytes(8, "little"),
        bytes([bump]),
    ]
    expected = Pubkey.create_program_address(seeds, Pubkey.from_string(program_id))
    assert channel == str(expected)


def test_channel_pda_golden():
    channel, bump = find_channel_pda(_pk(1), _pk(2), _pk(3), _pk(4), 99)
    assert channel == "H4q6bNCrC8R1ieNqoWuMz5V4VmQPLYFhYqTKzsPCejgf"
    assert bump == 254
