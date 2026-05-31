<?php

declare(strict_types=1);

namespace PayKit\Protocols\Mpp\Server\Session;

use RuntimeException;

/**
 * In-process {@see ChannelStore} for tests and single-worker development.
 *
 * Single-process only: there is no cross-process locking, so multi-worker
 * production servers must inject a shared atomic backing store instead,
 * otherwise the settled watermark can be advanced concurrently and the channel
 * over-spent. PHP request handlers are single-threaded, so within one process
 * {@see update()} reading then writing is effectively atomic.
 */
final class MemoryChannelStore implements ChannelStore
{
    /**
     * @var array<string, ChannelState>
     */
    private array $channels = [];

    public function get(string $channelId): ?ChannelState
    {
        $state = $this->channels[$channelId] ?? null;
        return $state?->copy();
    }

    public function put(string $channelId, ChannelState $state): void
    {
        $this->channels[$channelId] = $state->copy();
    }

    public function update(string $channelId, callable $mutator): ChannelState
    {
        $current = isset($this->channels[$channelId]) ? $this->channels[$channelId]->copy() : null;
        $next = $mutator($current);
        if (!$next instanceof ChannelState) {
            throw new RuntimeException('channel update mutator must return a ChannelState');
        }
        $this->channels[$channelId] = $next->copy();
        return $next->copy();
    }

    public function markFinalized(string $channelId): void
    {
        $this->update($channelId, static function (?ChannelState $state): ChannelState {
            if ($state === null) {
                throw new RuntimeException('Channel not found');
            }
            $state->finalized = true;
            return $state;
        });
    }
}
