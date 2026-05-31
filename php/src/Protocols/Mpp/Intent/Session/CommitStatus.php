<?php

declare(strict_types=1);

namespace PayKit\Protocols\Mpp\Intent\Session;

/**
 * Commit receipt status. `committed` is the first successful commit for a
 * delivery; `replayed` is an idempotent replay of a previously accepted commit.
 */
enum CommitStatus: string
{
    case Committed = 'committed';
    case Replayed = 'replayed';
}
