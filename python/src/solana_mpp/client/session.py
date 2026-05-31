"""Client-side session intent implementation.

Tracks an open payment channel and signs cumulative vouchers for each API
call. Vouchers are Ed25519-signed over the on-chain Borsh voucher layout used
by the payment-channels program.

Mirrors the Rust spine at ``rust/crates/mpp/src/client/session.rs``.

The ``signer`` is any object exposing ``pubkey()`` and ``sign_message(bytes)``
that returns a 64-byte Ed25519 signature (e.g. ``solders.keypair.Keypair``).
"""

from __future__ import annotations

from typing import Any

from solana_mpp.protocol.session import (
    DEFAULT_SESSION_EXPIRES_AT,
    ClosePayload,
    OpenPayload,
    SessionActionPayload,
    SignedVoucher,
    TopUpPayload,
    VoucherData,
    VoucherPayload,
    session_action_to_dict,
)

# Default voucher expiry: 2100-01-01T00:00:00Z. Below JavaScript's max safe
# integer so JSON intermediaries do not round it before decoding.
DEFAULT_VOUCHER_EXPIRES_AT = DEFAULT_SESSION_EXPIRES_AT

# Push / pull session submission modes (re-exported for ergonomics).
SESSION_MODE_PUSH = "push"
SESSION_MODE_PULL = "pull"


def _signer_pubkey_b58(signer: Any) -> str:
    return str(signer.pubkey())


def _signature_b58(signer: Any, message: bytes) -> str:
    """Sign ``message`` and return the base58 signature.

    ``solders`` signers return a ``Signature`` whose ``str()`` is base58.
    """
    return str(signer.sign_message(message))


class ActiveSession:
    """Tracks the client-side state of an active payment session.

    Holds a signer (its public key becomes the ``authorizedSigner``) and
    advances the cumulative watermark with each signed voucher.
    """

    def __init__(self, channel_id: str, signer: Any, expires_at: int = DEFAULT_VOUCHER_EXPIRES_AT) -> None:
        self.channel_id = channel_id
        self.cumulative = 0
        self._nonce = 0
        self._expires_at = expires_at
        self._signer = signer

    def set_expires_at(self, expires_at: int) -> None:
        """Update the expiry used for subsequent vouchers."""
        self._expires_at = expires_at

    def authorized_signer(self) -> str:
        """The authorized signer public key (base58)."""
        return _signer_pubkey_b58(self._signer)

    def channel_id_str(self) -> str:
        """Channel ID as base58."""
        return self.channel_id

    def prepare_voucher(self, cumulative: int) -> SignedVoucher:
        """Prepare a signed voucher without advancing the local watermark.

        Useful for ack/commit transports: if sending the commit fails the
        client can retry the same cumulative without its state drifting ahead
        of the server.
        """
        if cumulative <= self.cumulative:
            raise ValueError(
                f"Voucher cumulative {cumulative} must exceed current watermark {self.cumulative}"
            )
        data = VoucherData(
            channel_id=self.channel_id_str(),
            cumulative=str(cumulative),
            expires_at=self._expires_at,
            nonce=self._nonce + 1,
        )
        signature = _signature_b58(self._signer, data.message_bytes())
        return SignedVoucher(data=data, signature=signature)

    def prepare_increment(self, amount: int) -> SignedVoucher:
        """Prepare a voucher adding ``amount`` without advancing the watermark."""
        return self.prepare_voucher(self.cumulative + amount)

    def record_voucher(self, voucher: SignedVoucher) -> None:
        """Record a prepared voucher as accepted by the server."""
        cumulative = int(voucher.data.cumulative)
        if cumulative <= self.cumulative:
            raise ValueError(
                f"Voucher cumulative {cumulative} must exceed current watermark {self.cumulative}"
            )
        self.cumulative = cumulative
        self._nonce = max(self._nonce, voucher.data.nonce if voucher.data.nonce is not None else self._nonce + 1)

    def sign_voucher(self, cumulative: int) -> SignedVoucher:
        """Sign a voucher with an absolute cumulative amount and advance state."""
        voucher = self.prepare_voucher(cumulative)
        self.record_voucher(voucher)
        return voucher

    def sign_increment(self, amount: int) -> SignedVoucher:
        """Sign a voucher adding ``amount`` to the current cumulative."""
        return self.sign_voucher(self.cumulative + amount)

    def voucher_action(self, amount: int) -> SessionActionPayload:
        """Build a ``voucher`` action wrapping a freshly-signed increment."""
        return VoucherPayload(voucher=self.sign_increment(amount))

    def close_action(self, final_increment: int | None = None) -> SessionActionPayload:
        """Build a ``close`` action for cooperative channel close.

        If ``final_increment`` is a positive int, signs one last voucher for
        the remaining balance before closing.
        """
        voucher: SignedVoucher | None = None
        if final_increment is not None and final_increment > 0:
            voucher = self.sign_increment(final_increment)
        return ClosePayload(channel_id=self.channel_id_str(), voucher=voucher)

    def open_action(self, deposit: int, open_tx_signature: str) -> SessionActionPayload:
        """Build an ``open`` action for push mode."""
        return OpenPayload.push(
            self.channel_id_str(),
            str(deposit),
            self.authorized_signer(),
            open_tx_signature,
        )

    def open_payment_channel_action(
        self,
        deposit: int,
        payer: str,
        payee: str,
        mint: str,
        salt: int,
        grace_period: int,
        open_tx_signature: str,
    ) -> SessionActionPayload:
        """Build an ``open`` action for the payment-channels program (push)."""
        return self.open_payment_channel_action_with_mode(
            SESSION_MODE_PUSH, deposit, payer, payee, mint, salt, grace_period, open_tx_signature
        )

    def open_payment_channel_action_with_mode(
        self,
        mode: str,
        deposit: int,
        payer: str,
        payee: str,
        mint: str,
        salt: int,
        grace_period: int,
        open_tx_signature: str,
    ) -> SessionActionPayload:
        """Build a payment-channel ``open`` action with an explicit mode."""
        return OpenPayload.payment_channel_with_mode(
            mode,
            self.channel_id_str(),
            str(deposit),
            payer,
            payee,
            mint,
            salt,
            grace_period,
            self.authorized_signer(),
            open_tx_signature,
        )

    def open_pull_action(self, approved_amount: int, owner: str, approve_tx_signature: str) -> SessionActionPayload:
        """Build an ``open`` action for pull mode (SPL token delegation)."""
        return OpenPayload.pull(
            self.channel_id_str(),  # token account used as the session identifier
            str(approved_amount),
            owner,
            self.authorized_signer(),
            approve_tx_signature,
        )

    def topup_action(self, new_deposit: int, topup_tx_signature: str) -> SessionActionPayload:
        """Build a ``topup`` action after a top-up transaction."""
        return TopUpPayload(
            channel_id=self.channel_id_str(),
            new_deposit=str(new_deposit),
            signature=topup_tx_signature,
        )


def action_to_dict(payload: SessionActionPayload) -> dict[str, Any]:
    """Serialize a session action payload as a tagged wire object."""
    return session_action_to_dict(payload)
