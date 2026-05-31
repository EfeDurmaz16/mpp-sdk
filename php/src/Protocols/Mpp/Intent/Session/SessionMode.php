<?php

declare(strict_types=1);

namespace PayKit\Protocols\Mpp\Intent\Session;

/**
 * On-chain funding mechanism for a session, advertised by the server in the
 * 402 challenge and chosen by the client in its open action.
 *
 * Wire values are camelCase strings (`push`, `pull`), matching the Rust
 * `SessionMode` serde representation.
 */
enum SessionMode: string
{
    /** Payment channel backed by an on-chain escrow deposit (client-funded). */
    case Push = 'push';

    /** Operator-assisted pull session; voucher authority declared separately. */
    case Pull = 'pull';
}
