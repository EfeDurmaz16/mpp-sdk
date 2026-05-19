"""Solana session intent protocol types.

This module mirrors the shared session wire shape already present in the
TypeScript and Rust SDKs. It intentionally stops at schema and validation:
signing, voucher byte serialization, channel settlement, and server lifecycle
handling should land as separate changes.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import StrEnum
from typing import Any, Literal

DEFAULT_SESSION_EXPIRES_AT = 4_102_444_800


class SessionMode(StrEnum):
    """On-chain funding mechanism for a session."""

    PUSH = "push"
    PULL = "pull"


class SessionPullVoucherStrategy(StrEnum):
    """Voucher authority used when pull-mode sessions are advertised."""

    CLIENT_VOUCHER = "clientVoucher"
    OPERATED_VOUCHER = "operatedVoucher"


def _require_positive_base_units(value: str, field_name: str) -> None:
    try:
        parsed = int(value)
    except ValueError as exc:
        raise ValueError(f"{field_name} must be a base-unit integer string") from exc
    if parsed <= 0:
        raise ValueError(f"{field_name} must be positive")


@dataclass(frozen=True)
class SessionSplit:
    """A basis-point split distributed when a session settles."""

    recipient: str
    bps: int

    def validate(self) -> None:
        if not self.recipient:
            raise ValueError("split recipient is required")
        if not 0 < self.bps <= 10_000:
            raise ValueError("split bps must be between 1 and 10000")

    def to_dict(self) -> dict[str, Any]:
        return {"recipient": self.recipient, "bps": self.bps}

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> SessionSplit:
        split = cls(recipient=data.get("recipient", ""), bps=int(data.get("bps", 0)))
        split.validate()
        return split


@dataclass(frozen=True)
class SessionRequest:
    """Request embedded in a Solana session challenge."""

    cap: str
    currency: str
    operator: str
    recipient: str
    decimals: int | None = None
    network: str = ""
    splits: list[SessionSplit] = field(default_factory=list)
    program_id: str = ""
    description: str = ""
    external_id: str = ""
    min_voucher_delta: str = ""
    modes: list[SessionMode] = field(default_factory=list)
    pull_voucher_strategy: SessionPullVoucherStrategy | None = None
    recent_blockhash: str = ""

    def validate(self) -> None:
        _require_positive_base_units(self.cap, "cap")
        if not self.currency:
            raise ValueError("currency is required")
        if not self.operator:
            raise ValueError("operator is required")
        if not self.recipient:
            raise ValueError("recipient is required")
        if self.decimals is not None and not 0 <= self.decimals <= 255:
            raise ValueError("decimals must be between 0 and 255")
        for split in self.splits:
            split.validate()
        if self.min_voucher_delta:
            _require_positive_base_units(self.min_voucher_delta, "minVoucherDelta")
        if SessionMode.PULL in self.modes and self.pull_voucher_strategy is None:
            raise ValueError("pullVoucherStrategy is required when pull mode is advertised")

    def to_dict(self) -> dict[str, Any]:
        self.validate()
        data: dict[str, Any] = {
            "cap": self.cap,
            "currency": self.currency,
            "operator": self.operator,
            "recipient": self.recipient,
        }
        if self.decimals is not None:
            data["decimals"] = self.decimals
        if self.network:
            data["network"] = self.network
        if self.splits:
            data["splits"] = [split.to_dict() for split in self.splits]
        if self.program_id:
            data["programId"] = self.program_id
        if self.description:
            data["description"] = self.description
        if self.external_id:
            data["externalId"] = self.external_id
        if self.min_voucher_delta:
            data["minVoucherDelta"] = self.min_voucher_delta
        if self.modes:
            data["modes"] = [mode.value for mode in self.modes]
        if self.pull_voucher_strategy is not None:
            data["pullVoucherStrategy"] = self.pull_voucher_strategy.value
        if self.recent_blockhash:
            data["recentBlockhash"] = self.recent_blockhash
        return data

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> SessionRequest:
        request = cls(
            cap=data.get("cap", ""),
            currency=data.get("currency", ""),
            operator=data.get("operator", ""),
            recipient=data.get("recipient", ""),
            decimals=data.get("decimals"),
            network=data.get("network", ""),
            splits=[SessionSplit.from_dict(split) for split in data.get("splits", [])],
            program_id=data.get("programId", ""),
            description=data.get("description", ""),
            external_id=data.get("externalId", ""),
            min_voucher_delta=data.get("minVoucherDelta", ""),
            modes=[SessionMode(mode) for mode in data.get("modes", [])],
            pull_voucher_strategy=(
                SessionPullVoucherStrategy(data["pullVoucherStrategy"])
                if data.get("pullVoucherStrategy")
                else None
            ),
            recent_blockhash=data.get("recentBlockhash", ""),
        )
        request.validate()
        return request


@dataclass(frozen=True)
class VoucherData:
    """Canonical signed voucher content."""

    channel_id: str
    cumulative_amount: str
    expires_at: int = DEFAULT_SESSION_EXPIRES_AT
    nonce: int | None = None

    def validate(self) -> None:
        if not self.channel_id:
            raise ValueError("channelId is required")
        _require_positive_base_units(self.cumulative_amount, "cumulativeAmount")
        if self.expires_at <= 0:
            raise ValueError("expiresAt must be positive")
        if self.nonce is not None and self.nonce < 0:
            raise ValueError("nonce cannot be negative")

    def to_dict(self) -> dict[str, Any]:
        self.validate()
        data: dict[str, Any] = {
            "channelId": self.channel_id,
            "cumulativeAmount": self.cumulative_amount,
            "expiresAt": self.expires_at,
        }
        if self.nonce is not None:
            data["nonce"] = self.nonce
        return data

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> VoucherData:
        voucher = cls(
            channel_id=data.get("channelId", ""),
            cumulative_amount=data.get("cumulativeAmount", data.get("cumulative", "")),
            expires_at=int(data.get("expiresAt", DEFAULT_SESSION_EXPIRES_AT)),
            nonce=data.get("nonce"),
        )
        voucher.validate()
        return voucher


@dataclass(frozen=True)
class SignedVoucher:
    """Signed cumulative voucher."""

    data: VoucherData
    signature: str

    def validate(self) -> None:
        self.data.validate()
        if not self.signature:
            raise ValueError("signature is required")

    def to_dict(self) -> dict[str, Any]:
        self.validate()
        return {"data": self.data.to_dict(), "signature": self.signature}

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> SignedVoucher:
        voucher = cls(data=VoucherData.from_dict(data.get("data", {})), signature=data.get("signature", ""))
        voucher.validate()
        return voucher


@dataclass(frozen=True)
class MeteringDirective:
    """Server-issued metering directive attached to delivered work."""

    delivery_id: str
    session_id: str
    amount: str
    currency: str
    sequence: int
    expires_at: int
    commit_url: str = ""
    proof: str = ""

    def validate(self) -> None:
        if not self.delivery_id:
            raise ValueError("deliveryId is required")
        if not self.session_id:
            raise ValueError("sessionId is required")
        _require_positive_base_units(self.amount, "amount")
        if not self.currency:
            raise ValueError("currency is required")
        if self.sequence < 0:
            raise ValueError("sequence cannot be negative")
        if self.expires_at <= 0:
            raise ValueError("expiresAt must be positive")

    def to_dict(self) -> dict[str, Any]:
        self.validate()
        data: dict[str, Any] = {
            "deliveryId": self.delivery_id,
            "sessionId": self.session_id,
            "amount": self.amount,
            "currency": self.currency,
            "sequence": self.sequence,
            "expiresAt": self.expires_at,
        }
        if self.commit_url:
            data["commitUrl"] = self.commit_url
        if self.proof:
            data["proof"] = self.proof
        return data


@dataclass(frozen=True)
class CommitReceipt:
    """Result returned after a delivery commit is accepted."""

    delivery_id: str
    session_id: str
    amount: str
    cumulative: str
    status: Literal["committed", "replayed"]

    def validate(self) -> None:
        if not self.delivery_id:
            raise ValueError("deliveryId is required")
        if not self.session_id:
            raise ValueError("sessionId is required")
        _require_positive_base_units(self.amount, "amount")
        _require_positive_base_units(self.cumulative, "cumulative")
        if self.status not in ("committed", "replayed"):
            raise ValueError("status must be committed or replayed")

    def to_dict(self) -> dict[str, Any]:
        self.validate()
        return {
            "deliveryId": self.delivery_id,
            "sessionId": self.session_id,
            "amount": self.amount,
            "cumulative": self.cumulative,
            "status": self.status,
        }
