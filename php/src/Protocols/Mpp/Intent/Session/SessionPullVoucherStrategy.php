<?php

declare(strict_types=1);

namespace PayKit\Protocols\Mpp\Intent\Session;

/**
 * Voucher authority used when {@see SessionMode::Pull} is advertised.
 *
 * Separates "how the session is opened" from "who signs spend vouchers":
 *
 * - `clientVoucher`: the client signs cumulative vouchers; the operator may use
 *   them as off-chain receipts without multi-delegate setup.
 * - `operatedVoucher`: the operator signs vouchers after metering and uses
 *   multi-delegate setup for delegated token movement.
 */
enum SessionPullVoucherStrategy: string
{
    case ClientVoucher = 'clientVoucher';
    case OperatedVoucher = 'operatedVoucher';
}
