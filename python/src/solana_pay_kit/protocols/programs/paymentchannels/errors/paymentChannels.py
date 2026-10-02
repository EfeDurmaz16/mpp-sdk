# Generated from idl/payment-channels.json. Do not edit by hand.
from collections.abc import Callable

from solana_pay_kit._paycore.program_client import ProgramError


class CustomError(ProgramError):
    """Base class for PaymentChannels custom errors."""


class NotImplemented(CustomError):
    """IDL error 0: NotImplemented."""

    code = 0
    name = "NotImplemented"
    msg = "Not implemented"

    def __init__(self, logs: list[str] | None = None) -> None:
        super().__init__(self.code, self.msg, logs)


class MissingRequiredSignature(CustomError):
    """IDL error 1: MissingRequiredSignature."""

    code = 1
    name = "MissingRequiredSignature"
    msg = "A signature was required but not found"

    def __init__(self, logs: list[str] | None = None) -> None:
        super().__init__(self.code, self.msg, logs)


class InvalidChannelStatus(CustomError):
    """IDL error 2: InvalidChannelStatus."""

    code = 2
    name = "InvalidChannelStatus"
    msg = "Invalid channel status"

    def __init__(self, logs: list[str] | None = None) -> None:
        super().__init__(self.code, self.msg, logs)


class InvalidAccountDiscriminator(CustomError):
    """IDL error 3: InvalidAccountDiscriminator."""

    code = 3
    name = "InvalidAccountDiscriminator"
    msg = "Invalid account discriminator"

    def __init__(self, logs: list[str] | None = None) -> None:
        super().__init__(self.code, self.msg, logs)


class UnsupportedChannelVersion(CustomError):
    """IDL error 4: UnsupportedChannelVersion."""

    code = 4
    name = "UnsupportedChannelVersion"
    msg = "Unsupported channel version"

    def __init__(self, logs: list[str] | None = None) -> None:
        super().__init__(self.code, self.msg, logs)


class InvalidChannelPayer(CustomError):
    """IDL error 5: InvalidChannelPayer."""

    code = 5
    name = "InvalidChannelPayer"
    msg = "Account does not match channel payer"

    def __init__(self, logs: list[str] | None = None) -> None:
        super().__init__(self.code, self.msg, logs)


class InvalidChannelPayee(CustomError):
    """IDL error 6: InvalidChannelPayee."""

    code = 6
    name = "InvalidChannelPayee"
    msg = "Account does not match channel payee"

    def __init__(self, logs: list[str] | None = None) -> None:
        super().__init__(self.code, self.msg, logs)


class InvalidChannelMint(CustomError):
    """IDL error 7: InvalidChannelMint."""

    code = 7
    name = "InvalidChannelMint"
    msg = "Account does not match channel mint"

    def __init__(self, logs: list[str] | None = None) -> None:
        super().__init__(self.code, self.msg, logs)


class InvalidEventAuthority(CustomError):
    """IDL error 8: InvalidEventAuthority."""

    code = 8
    name = "InvalidEventAuthority"
    msg = "Invalid event authority"

    def __init__(self, logs: list[str] | None = None) -> None:
        super().__init__(self.code, self.msg, logs)


class NotEnoughAccountKeys(CustomError):
    """IDL error 9: NotEnoughAccountKeys."""

    code = 9
    name = "NotEnoughAccountKeys"
    msg = "Not enough accounts were provided"

    def __init__(self, logs: list[str] | None = None) -> None:
        super().__init__(self.code, self.msg, logs)


class InvalidChannelRentPayer(CustomError):
    """IDL error 10: InvalidChannelRentPayer."""

    code = 10
    name = "InvalidChannelRentPayer"
    msg = "Account does not match channel rent_payer"

    def __init__(self, logs: list[str] | None = None) -> None:
        super().__init__(self.code, self.msg, logs)


class ChannelAccountMismatch(CustomError):
    """IDL error 50: ChannelAccountMismatch."""

    code = 50
    name = "ChannelAccountMismatch"
    msg = "Channel account does not match derived PDA"

    def __init__(self, logs: list[str] | None = None) -> None:
        super().__init__(self.code, self.msg, logs)


class InvalidChannelTokenAccount(CustomError):
    """IDL error 51: InvalidChannelTokenAccount."""

    code = 51
    name = "InvalidChannelTokenAccount"
    msg = "Channel token account is not ATA(channel, mint, token_program)"

    def __init__(self, logs: list[str] | None = None) -> None:
        super().__init__(self.code, self.msg, logs)


class InvalidChannelTokenExtensions(CustomError):
    """IDL error 52: InvalidChannelTokenExtensions."""

    code = 52
    name = "InvalidChannelTokenExtensions"
    msg = "Channel token account has invalid extensions"

    def __init__(self, logs: list[str] | None = None) -> None:
        super().__init__(self.code, self.msg, logs)


class MintAccountMismatch(CustomError):
    """IDL error 53: MintAccountMismatch."""

    code = 53
    name = "MintAccountMismatch"
    msg = "Mint account does not match channel.mint"

    def __init__(self, logs: list[str] | None = None) -> None:
        super().__init__(self.code, self.msg, logs)


class InvalidMintTokenProgram(CustomError):
    """IDL error 54: InvalidMintTokenProgram."""

    code = 54
    name = "InvalidMintTokenProgram"
    msg = "Token program must be SPL Token or Token-2022"

    def __init__(self, logs: list[str] | None = None) -> None:
        super().__init__(self.code, self.msg, logs)


class MalformedMintTokenAccountData(CustomError):
    """IDL error 55: MalformedMintTokenAccountData."""

    code = 55
    name = "MalformedMintTokenAccountData"
    msg = "Token account or mint TLV trailer is malformed"

    def __init__(self, logs: list[str] | None = None) -> None:
        super().__init__(self.code, self.msg, logs)


class MalformedMintTokenExtensions(CustomError):
    """IDL error 56: MalformedMintTokenExtensions."""

    code = 56
    name = "MalformedMintTokenExtensions"
    msg = "Token account or mint TLV trailer is malformed"

    def __init__(self, logs: list[str] | None = None) -> None:
        super().__init__(self.code, self.msg, logs)


class PayerAccountMismatch(CustomError):
    """IDL error 57: PayerAccountMismatch."""

    code = 57
    name = "PayerAccountMismatch"
    msg = "Payer token account is not ATA(payer, token_program, mint)"

    def __init__(self, logs: list[str] | None = None) -> None:
        super().__init__(self.code, self.msg, logs)


class InvalidPayerTokenAccount(CustomError):
    """IDL error 58: InvalidPayerTokenAccount."""

    code = 58
    name = "InvalidPayerTokenAccount"
    msg = "Payer token account is invalid"

    def __init__(self, logs: list[str] | None = None) -> None:
        super().__init__(self.code, self.msg, logs)


class InvalidPayerTokenExtensions(CustomError):
    """IDL error 59: InvalidPayerTokenExtensions."""

    code = 59
    name = "InvalidPayerTokenExtensions"
    msg = "Payer token account has invalid extensions"

    def __init__(self, logs: list[str] | None = None) -> None:
        super().__init__(self.code, self.msg, logs)


class PayeeAccountMismatch(CustomError):
    """IDL error 60: PayeeAccountMismatch."""

    code = 60
    name = "PayeeAccountMismatch"
    msg = "Payee token account is not ATA(payee, token_program, mint)"

    def __init__(self, logs: list[str] | None = None) -> None:
        super().__init__(self.code, self.msg, logs)


class InvalidPayeeTokenAccount(CustomError):
    """IDL error 61: InvalidPayeeTokenAccount."""

    code = 61
    name = "InvalidPayeeTokenAccount"
    msg = "Payee token account is invalid"

    def __init__(self, logs: list[str] | None = None) -> None:
        super().__init__(self.code, self.msg, logs)


class InvalidPayeeTokenExtensions(CustomError):
    """IDL error 62: InvalidPayeeTokenExtensions."""

    code = 62
    name = "InvalidPayeeTokenExtensions"
    msg = "Payee token account has invalid extensions"

    def __init__(self, logs: list[str] | None = None) -> None:
        super().__init__(self.code, self.msg, logs)


class DepositMustBeNonZero(CustomError):
    """IDL error 200: DepositMustBeNonZero."""

    code = 200
    name = "DepositMustBeNonZero"
    msg = "Deposit must be non-zero"

    def __init__(self, logs: list[str] | None = None) -> None:
        super().__init__(self.code, self.msg, logs)


class GracePeriodMustBeNonZero(CustomError):
    """IDL error 201: GracePeriodMustBeNonZero."""

    code = 201
    name = "GracePeriodMustBeNonZero"
    msg = "Grace period must be non-zero"

    def __init__(self, logs: list[str] | None = None) -> None:
        super().__init__(self.code, self.msg, logs)


class MissingEd25519Verification(CustomError):
    """IDL error 230: MissingEd25519Verification."""

    code = 230
    name = "MissingEd25519Verification"
    msg = "Missing Ed25519 precompile ix at current-1"

    def __init__(self, logs: list[str] | None = None) -> None:
        super().__init__(self.code, self.msg, logs)


class MalformedEd25519Instruction(CustomError):
    """IDL error 231: MalformedEd25519Instruction."""

    code = 231
    name = "MalformedEd25519Instruction"
    msg = "Malformed Ed25519 precompile instruction"

    def __init__(self, logs: list[str] | None = None) -> None:
        super().__init__(self.code, self.msg, logs)


class VoucherChannelMismatch(CustomError):
    """IDL error 232: VoucherChannelMismatch."""

    code = 232
    name = "VoucherChannelMismatch"
    msg = "Voucher channel_id does not match channel PDA"

    def __init__(self, logs: list[str] | None = None) -> None:
        super().__init__(self.code, self.msg, logs)


class VoucherExpired(CustomError):
    """IDL error 233: VoucherExpired."""

    code = 233
    name = "VoucherExpired"
    msg = "Voucher expired"

    def __init__(self, logs: list[str] | None = None) -> None:
        super().__init__(self.code, self.msg, logs)


class VoucherWatermarkNotMonotonic(CustomError):
    """IDL error 234: VoucherWatermarkNotMonotonic."""

    code = 234
    name = "VoucherWatermarkNotMonotonic"
    msg = "Voucher watermark not strictly monotonic"

    def __init__(self, logs: list[str] | None = None) -> None:
        super().__init__(self.code, self.msg, logs)


class VoucherOverDeposit(CustomError):
    """IDL error 235: VoucherOverDeposit."""

    code = 235
    name = "VoucherOverDeposit"
    msg = "Voucher cumulative_amount exceeds channel deposit"

    def __init__(self, logs: list[str] | None = None) -> None:
        super().__init__(self.code, self.msg, logs)


class VoucherMessageMismatch(CustomError):
    """IDL error 236: VoucherMessageMismatch."""

    code = 236
    name = "VoucherMessageMismatch"
    msg = "Reserved (formerly: Ed25519 message does not match Borsh voucher payload)"

    def __init__(self, logs: list[str] | None = None) -> None:
        super().__init__(self.code, self.msg, logs)


class VoucherSignerMismatch(CustomError):
    """IDL error 237: VoucherSignerMismatch."""

    code = 237
    name = "VoucherSignerMismatch"
    msg = "Voucher signer does not match channel authorized_signer"

    def __init__(self, logs: list[str] | None = None) -> None:
        super().__init__(self.code, self.msg, logs)


class VoucherBadMagic(CustomError):
    """IDL error 238: VoucherBadMagic."""

    code = 238
    name = "VoucherBadMagic"
    msg = "Voucher payload magic prefix is invalid"

    def __init__(self, logs: list[str] | None = None) -> None:
        super().__init__(self.code, self.msg, logs)


class InvalidRecipientCount(CustomError):
    """IDL error 260: InvalidRecipientCount."""

    code = 260
    name = "InvalidRecipientCount"
    msg = "num_recipients outside [0, 32]"

    def __init__(self, logs: list[str] | None = None) -> None:
        super().__init__(self.code, self.msg, logs)


class InvalidSplitConfig(CustomError):
    """IDL error 261: InvalidSplitConfig."""

    code = 261
    name = "InvalidSplitConfig"
    msg = "Each shareBps must be non-zero and \u03a3bps must be at most 10_000"

    def __init__(self, logs: list[str] | None = None) -> None:
        super().__init__(self.code, self.msg, logs)


class DistributionPartsOverflow(CustomError):
    """IDL error 262: DistributionPartsOverflow."""

    code = 262
    name = "DistributionPartsOverflow"
    msg = "num_recipients outside [0, 32]"

    def __init__(self, logs: list[str] | None = None) -> None:
        super().__init__(self.code, self.msg, logs)


class DuplicateRecipient(CustomError):
    """IDL error 263: DuplicateRecipient."""

    code = 263
    name = "DuplicateRecipient"
    msg = "Distribution plan contains a duplicate recipient address"

    def __init__(self, logs: list[str] | None = None) -> None:
        super().__init__(self.code, self.msg, logs)


class DistributionAmountOverflow(CustomError):
    """IDL error 264: DistributionAmountOverflow."""

    code = 264
    name = "DistributionAmountOverflow"
    msg = "num_recipients outside [0, 32]"

    def __init__(self, logs: list[str] | None = None) -> None:
        super().__init__(self.code, self.msg, logs)


class DistributionPreimageLengthOverflow(CustomError):
    """IDL error 265: DistributionPreimageLengthOverflow."""

    code = 265
    name = "DistributionPreimageLengthOverflow"
    msg = "Distribution preimage length calculation overflow"

    def __init__(self, logs: list[str] | None = None) -> None:
        super().__init__(self.code, self.msg, logs)


class ChannelAddressMismatch(CustomError):
    """IDL error 2000: ChannelAddressMismatch."""

    code = 2000
    name = "ChannelAddressMismatch"
    msg = "Derived channel account address does not match the user provided address"

    def __init__(self, logs: list[str] | None = None) -> None:
        super().__init__(self.code, self.msg, logs)


class PayerPayeeMustDiffer(CustomError):
    """IDL error 2001: PayerPayeeMustDiffer."""

    code = 2001
    name = "PayerPayeeMustDiffer"
    msg = "Payer and payee must be different accounts"

    def __init__(self, logs: list[str] | None = None) -> None:
        super().__init__(self.code, self.msg, logs)


class InvalidAuthorizedSigner(CustomError):
    """IDL error 2002: InvalidAuthorizedSigner."""

    code = 2002
    name = "InvalidAuthorizedSigner"
    msg = "authorized_signer must be a valid Ed25519 public key"

    def __init__(self, logs: list[str] | None = None) -> None:
        super().__init__(self.code, self.msg, logs)


class OpenSlotOutOfWindow(CustomError):
    """IDL error 2003: OpenSlotOutOfWindow."""

    code = 2003
    name = "OpenSlotOutOfWindow"
    msg = "open_slot is in the future or older than the allowed slot window"

    def __init__(self, logs: list[str] | None = None) -> None:
        super().__init__(self.code, self.msg, logs)


class TopUpDepositOverflow(CustomError):
    """IDL error 2100: TopUpDepositOverflow."""

    code = 2100
    name = "TopUpDepositOverflow"
    msg = "Deposit must be non-zero"

    def __init__(self, logs: list[str] | None = None) -> None:
        super().__init__(self.code, self.msg, logs)


class SealDeadlineOverflow(CustomError):
    """IDL error 2200: SealDeadlineOverflow."""

    code = 2200
    name = "SealDeadlineOverflow"
    msg = "Deadline overflow on grace period"

    def __init__(self, logs: list[str] | None = None) -> None:
        super().__init__(self.code, self.msg, logs)


class SealGracePeriodNotElapsed(CustomError):
    """IDL error 2201: SealGracePeriodNotElapsed."""

    code = 2201
    name = "SealGracePeriodNotElapsed"
    msg = "Grace period has not elapsed yet"

    def __init__(self, logs: list[str] | None = None) -> None:
        super().__init__(self.code, self.msg, logs)


class PayerAlreadyWithdrawn(CustomError):
    """IDL error 2300: PayerAlreadyWithdrawn."""

    code = 2300
    name = "PayerAlreadyWithdrawn"
    msg = "Payer refund has already been claimed"

    def __init__(self, logs: list[str] | None = None) -> None:
        super().__init__(self.code, self.msg, logs)


class RefundCalculationOverflow(CustomError):
    """IDL error 2301: RefundCalculationOverflow."""

    code = 2301
    name = "RefundCalculationOverflow"
    msg = "Payer refund amount calculation underflow"

    def __init__(self, logs: list[str] | None = None) -> None:
        super().__init__(self.code, self.msg, logs)


class ChannelNotDistributable(CustomError):
    """IDL error 2400: ChannelNotDistributable."""

    code = 2400
    name = "ChannelNotDistributable"
    msg = "Channel is not in OPEN or SEALED"

    def __init__(self, logs: list[str] | None = None) -> None:
        super().__init__(self.code, self.msg, logs)


class TreasuryAccountMismatch(CustomError):
    """IDL error 2401: TreasuryAccountMismatch."""

    code = 2401
    name = "TreasuryAccountMismatch"
    msg = "Treasury token account is not ATA(TREASURY_OWNER, mint, token_program)"

    def __init__(self, logs: list[str] | None = None) -> None:
        super().__init__(self.code, self.msg, logs)


class InvalidTreasuryTokenAccount(CustomError):
    """IDL error 2402: InvalidTreasuryTokenAccount."""

    code = 2402
    name = "InvalidTreasuryTokenAccount"
    msg = "Treasury token account is invalid"

    def __init__(self, logs: list[str] | None = None) -> None:
        super().__init__(self.code, self.msg, logs)


class InvalidTreasuryTokenExtensions(CustomError):
    """IDL error 2403: InvalidTreasuryTokenExtensions."""

    code = 2403
    name = "InvalidTreasuryTokenExtensions"
    msg = "Treasury token account has invalid extensions"

    def __init__(self, logs: list[str] | None = None) -> None:
        super().__init__(self.code, self.msg, logs)


class RecipientAccountMismatch(CustomError):
    """IDL error 2404: RecipientAccountMismatch."""

    code = 2404
    name = "RecipientAccountMismatch"
    msg = "Recipient token account is not ATA(recipient, token_program, mint)"

    def __init__(self, logs: list[str] | None = None) -> None:
        super().__init__(self.code, self.msg, logs)


class InvalidRecipientTokenAccount(CustomError):
    """IDL error 2405: InvalidRecipientTokenAccount."""

    code = 2405
    name = "InvalidRecipientTokenAccount"
    msg = "Recipient token account is invalid"

    def __init__(self, logs: list[str] | None = None) -> None:
        super().__init__(self.code, self.msg, logs)


class InvalidRecipientTokenExtensions(CustomError):
    """IDL error 2406: InvalidRecipientTokenExtensions."""

    code = 2406
    name = "InvalidRecipientTokenExtensions"
    msg = "Recipient token account has invalid extensions"

    def __init__(self, logs: list[str] | None = None) -> None:
        super().__init__(self.code, self.msg, logs)


class InvalidDistributionHash(CustomError):
    """IDL error 2407: InvalidDistributionHash."""

    code = 2407
    name = "InvalidDistributionHash"
    msg = "Distribution hash mismatch"

    def __init__(self, logs: list[str] | None = None) -> None:
        super().__init__(self.code, self.msg, logs)


class NothingToDistribute(CustomError):
    """IDL error 2408: NothingToDistribute."""

    code = 2408
    name = "NothingToDistribute"
    msg = "No newly settled funds to distribute"

    def __init__(self, logs: list[str] | None = None) -> None:
        super().__init__(self.code, self.msg, logs)


class RecipientAccountCountMismatch(CustomError):
    """IDL error 2409: RecipientAccountCountMismatch."""

    code = 2409
    name = "RecipientAccountCountMismatch"
    msg = "Recipient ATA tail length does not match the committed plan's entry count"

    def __init__(self, logs: list[str] | None = None) -> None:
        super().__init__(self.code, self.msg, logs)


class DistributePoolOverflow(CustomError):
    """IDL error 2410: DistributePoolOverflow."""

    code = 2410
    name = "DistributePoolOverflow"
    msg = "Distribution pool calculation underflow"

    def __init__(self, logs: list[str] | None = None) -> None:
        super().__init__(self.code, self.msg, logs)


class DistributeBalanceCalculationOverflow(CustomError):
    """IDL error 2411: DistributeBalanceCalculationOverflow."""

    code = 2411
    name = "DistributeBalanceCalculationOverflow"
    msg = "Channel rent rebalance calculation underflow"

    def __init__(self, logs: list[str] | None = None) -> None:
        super().__init__(self.code, self.msg, logs)


class RentPayerBalanceOverflow(CustomError):
    """IDL error 2412: RentPayerBalanceOverflow."""

    code = 2412
    name = "RentPayerBalanceOverflow"
    msg = "Rent payer lamports overflow on channel deallocation"

    def __init__(self, logs: list[str] | None = None) -> None:
        super().__init__(self.code, self.msg, logs)


class DistributeTransferQueueOverflow(CustomError):
    """IDL error 2413: DistributeTransferQueueOverflow."""

    code = 2413
    name = "DistributeTransferQueueOverflow"
    msg = "Transfer queue capacity exceeded"

    def __init__(self, logs: list[str] | None = None) -> None:
        super().__init__(self.code, self.msg, logs)


class ChannelCloseTooEarly(CustomError):
    """IDL error 2414: ChannelCloseTooEarly."""

    code = 2414
    name = "ChannelCloseTooEarly"
    msg = "Channel cannot be fully closed until clock.slot > open_slot + OPEN_SLOT_WINDOW"

    def __init__(self, logs: list[str] | None = None) -> None:
        super().__init__(self.code, self.msg, logs)


CUSTOM_ERROR_MAP: dict[int, Callable[[list[str] | None], CustomError]] = {
    0: NotImplemented,
    1: MissingRequiredSignature,
    2: InvalidChannelStatus,
    3: InvalidAccountDiscriminator,
    4: UnsupportedChannelVersion,
    5: InvalidChannelPayer,
    6: InvalidChannelPayee,
    7: InvalidChannelMint,
    8: InvalidEventAuthority,
    9: NotEnoughAccountKeys,
    10: InvalidChannelRentPayer,
    50: ChannelAccountMismatch,
    51: InvalidChannelTokenAccount,
    52: InvalidChannelTokenExtensions,
    53: MintAccountMismatch,
    54: InvalidMintTokenProgram,
    55: MalformedMintTokenAccountData,
    56: MalformedMintTokenExtensions,
    57: PayerAccountMismatch,
    58: InvalidPayerTokenAccount,
    59: InvalidPayerTokenExtensions,
    60: PayeeAccountMismatch,
    61: InvalidPayeeTokenAccount,
    62: InvalidPayeeTokenExtensions,
    200: DepositMustBeNonZero,
    201: GracePeriodMustBeNonZero,
    230: MissingEd25519Verification,
    231: MalformedEd25519Instruction,
    232: VoucherChannelMismatch,
    233: VoucherExpired,
    234: VoucherWatermarkNotMonotonic,
    235: VoucherOverDeposit,
    236: VoucherMessageMismatch,
    237: VoucherSignerMismatch,
    238: VoucherBadMagic,
    260: InvalidRecipientCount,
    261: InvalidSplitConfig,
    262: DistributionPartsOverflow,
    263: DuplicateRecipient,
    264: DistributionAmountOverflow,
    265: DistributionPreimageLengthOverflow,
    2000: ChannelAddressMismatch,
    2001: PayerPayeeMustDiffer,
    2002: InvalidAuthorizedSigner,
    2003: OpenSlotOutOfWindow,
    2100: TopUpDepositOverflow,
    2200: SealDeadlineOverflow,
    2201: SealGracePeriodNotElapsed,
    2300: PayerAlreadyWithdrawn,
    2301: RefundCalculationOverflow,
    2400: ChannelNotDistributable,
    2401: TreasuryAccountMismatch,
    2402: InvalidTreasuryTokenAccount,
    2403: InvalidTreasuryTokenExtensions,
    2404: RecipientAccountMismatch,
    2405: InvalidRecipientTokenAccount,
    2406: InvalidRecipientTokenExtensions,
    2407: InvalidDistributionHash,
    2408: NothingToDistribute,
    2409: RecipientAccountCountMismatch,
    2410: DistributePoolOverflow,
    2411: DistributeBalanceCalculationOverflow,
    2412: RentPayerBalanceOverflow,
    2413: DistributeTransferQueueOverflow,
    2414: ChannelCloseTooEarly,
}


def from_code(code: int, logs: list[str] | None = None) -> CustomError | None:
    """Create an independent exception for a recognized program code."""
    error_type = CUSTOM_ERROR_MAP.get(code)
    return None if error_type is None else error_type(logs)
