"""Typed helpers for the payment-channels program.

Hand-written adapter code mirroring the Rust spine at
``rust/crates/mpp/src/program/payment_channels.rs``: PDA derivation, associated
token derivation, blake3 distribution hashing, voucher bytes, and convenience
instruction builders.

Load-bearing parity:

* voucher message bytes = ``channel_id(32) || cumulative(u64 LE) ||
  expires_at(i64 LE)`` = 48 bytes, signed with Ed25519.
* channel PDA seeds = ``b"channel" || payer || payee || mint ||
  authorized_signer || salt(u64 LE)``.
* ``distribution_hash`` = blake3 over ``count(u32 LE) || (recipient ||
  bps(u16 LE)) * count``.
"""

from __future__ import annotations

from dataclasses import dataclass, field

import blake3

from solana_mpp.protocol.solana import ASSOCIATED_TOKEN_PROGRAM

# Canonical payment-channels program ID deployed to Surfnet.
PAYMENT_CHANNELS_PROGRAM_ID = "GuoKrzaBiZnW5DvJ3yZVE7xHqbcBvaX9SH6P6Cn9gNvc"

# Channel PDA seed prefix.
CHANNEL_SEED = b"channel"

# Event authority PDA seed prefix.
EVENT_AUTHORITY_SEED = b"event_authority"

# Ed25519 precompile program ID.
ED25519_PROGRAM_ID = "Ed25519SigVerify111111111111111111111111111"

# Instructions sysvar ID.
INSTRUCTIONS_SYSVAR_ID = "Sysvar1nstructions1111111111111111111111111"

# Rent sysvar ID.
RENT_SYSVAR_ID = "SysvarRent111111111111111111111111111111111"


def default_program_id() -> str:
    """Return the canonical payment-channels program ID (base58)."""
    return PAYMENT_CHANNELS_PROGRAM_ID


@dataclass
class Distribution:
    """A split recipient and its share in basis points."""

    recipient: str
    bps: int


def _pubkey_bytes(value: str) -> bytes:
    """Decode a base58 pubkey string into its 32 raw bytes."""
    from solders.pubkey import Pubkey

    raw = bytes(Pubkey.from_string(value))
    if len(raw) != 32:
        raise ValueError(f"pubkey {value} is not 32 bytes")
    return raw


def find_channel_pda(
    payer: str,
    payee: str,
    mint: str,
    authorized_signer: str,
    salt: int,
    program_id: str | None = None,
) -> tuple[str, int]:
    """Derive the channel PDA address and bump.

    Seeds: ``b"channel" || payer || payee || mint || authorized_signer ||
    salt(u64 LE)``. Mirrors ``find_channel_pda`` on the Rust spine.
    """
    from solders.pubkey import Pubkey

    program = Pubkey.from_string(program_id or PAYMENT_CHANNELS_PROGRAM_ID)
    seeds = [
        CHANNEL_SEED,
        _pubkey_bytes(payer),
        _pubkey_bytes(payee),
        _pubkey_bytes(mint),
        _pubkey_bytes(authorized_signer),
        salt.to_bytes(8, "little"),
    ]
    pda, bump = Pubkey.find_program_address(seeds, program)
    return str(pda), bump


def find_event_authority_pda(program_id: str | None = None) -> tuple[str, int]:
    """Derive the event authority PDA address and bump."""
    from solders.pubkey import Pubkey

    program = Pubkey.from_string(program_id or PAYMENT_CHANNELS_PROGRAM_ID)
    pda, bump = Pubkey.find_program_address([EVENT_AUTHORITY_SEED], program)
    return str(pda), bump


def find_associated_token_address(owner: str, mint: str, token_program: str) -> tuple[str, int]:
    """Derive the associated token account address and bump."""
    from solders.pubkey import Pubkey

    ata_program = Pubkey.from_string(ASSOCIATED_TOKEN_PROGRAM)
    seeds = [_pubkey_bytes(owner), _pubkey_bytes(token_program), _pubkey_bytes(mint)]
    pda, bump = Pubkey.find_program_address(seeds, ata_program)
    return str(pda), bump


@dataclass
class OpenChannelParams:
    """Parameters for the payment-channels ``Open`` instruction."""

    payer: str
    payee: str
    mint: str
    authorized_signer: str
    salt: int
    deposit: int
    grace_period: int
    token_program: str
    recipients: list[Distribution] = field(default_factory=list)
    program_id: str | None = None


@dataclass
class ChannelAddresses:
    """Derived addresses for a channel open."""

    channel: str
    payer_token_account: str
    channel_token_account: str
    event_authority: str


def derive_channel_addresses(params: OpenChannelParams) -> ChannelAddresses:
    """Derive every address needed for a channel open."""
    program_id = params.program_id or PAYMENT_CHANNELS_PROGRAM_ID
    channel, _ = find_channel_pda(
        params.payer,
        params.payee,
        params.mint,
        params.authorized_signer,
        params.salt,
        program_id,
    )
    payer_token_account, _ = find_associated_token_address(params.payer, params.mint, params.token_program)
    channel_token_account, _ = find_associated_token_address(channel, params.mint, params.token_program)
    event_authority, _ = find_event_authority_pda(program_id)
    return ChannelAddresses(
        channel=channel,
        payer_token_account=payer_token_account,
        channel_token_account=channel_token_account,
        event_authority=event_authority,
    )


def distribution_hash(recipients: list[Distribution]) -> bytes:
    """Compute the blake3 distribution hash committed at channel open.

    Preimage: ``count(u32 LE) || (recipient(32) || bps(u16 LE)) * count``.
    Mirrors ``distribution_hash`` on the Rust spine exactly.
    """
    hasher = blake3.blake3()
    hasher.update(len(recipients).to_bytes(4, "little"))
    for recipient in recipients:
        hasher.update(_pubkey_bytes(recipient.recipient))
        hasher.update(recipient.bps.to_bytes(2, "little"))
    return hasher.digest()


def voucher_message_bytes(channel_id: str, cumulative_amount: int, expires_at: int) -> bytes:
    """Serialize the payment-channels VoucherArgs bytes signed by Ed25519.

    Layout: ``channel_id(32) || cumulative_amount(u64 LE) || expires_at(i64 LE)``
    = 48 bytes. Get this wrong and signatures will not verify against the
    on-chain program.
    """
    return (
        _pubkey_bytes(channel_id)
        + cumulative_amount.to_bytes(8, "little", signed=False)
        + expires_at.to_bytes(8, "little", signed=True)
    )
