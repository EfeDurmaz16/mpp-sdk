<?php

declare(strict_types=1);

namespace PayKit\Protocols\Mpp\Server\Session;

/**
 * Channel state store for the session intent.
 *
 * Unlike the charge replay store (which only needs at-most-once
 * {@see \PayKit\Store\Store::putIfAbsent}), the session server tracks evolving
 * lifecycle state and advances a settled watermark across many requests. The
 * watermark advance, delivery reservation, and commit must be atomic
 * read-modify-write operations so concurrent vouchers cannot double-spend.
 *
 * Mirrors the Rust `ChannelStore` trait (`rust/crates/mpp/src/store.rs`).
 * Production multi-worker deployments must back this with a store that performs
 * the {@see update()} mutation atomically (Redis WATCH/MULTI, Postgres
 * SELECT ... FOR UPDATE, etc.); the bundled {@see MemoryChannelStore} is
 * single-process only.
 */
interface ChannelStore
{
    public function get(string $channelId): ?ChannelState;

    public function put(string $channelId, ChannelState $state): void;

    /**
     * Atomically read the current state, apply the mutator, and persist the
     * returned state. The mutator receives the current state (or null when the
     * channel is unknown) and must return the new {@see ChannelState}. The
     * mutator may throw to abort the update; the store must not persist a
     * partial change in that case. Returns the persisted state.
     *
     * @param callable(ChannelState|null): ChannelState $mutator
     */
    public function update(string $channelId, callable $mutator): ChannelState;

    public function markFinalized(string $channelId): void;
}
