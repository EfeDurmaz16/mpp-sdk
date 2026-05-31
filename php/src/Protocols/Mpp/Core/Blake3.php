<?php

declare(strict_types=1);

namespace PayKit\Protocols\Mpp\Core;

/**
 * Pure-PHP BLAKE3 (default 256-bit output, no key, no derive-key).
 *
 * The payment-channels program commits split recipients with a BLAKE3 hash of
 * the distribution preimage (`len(u32 LE) || (recipient(32) || bps(u16 LE))*`).
 * The Rust spine derives that hash with the `blake3` crate
 * (`rust/crates/mpp/src/program/payment_channels.rs::distribution_hash`); PHP
 * has no native BLAKE3 in `hash_algos()`, so this implements the unkeyed hash
 * directly from the BLAKE3 specification.
 *
 * Only the hashing surface needed by the session intent is implemented:
 * arbitrary-length input, fixed 32-byte output, no keyed/KDF modes and no
 * extendable-output (XOF) beyond 32 bytes. Everything is 32-bit-word math kept
 * inside PHP integers with explicit `& 0xFFFFFFFF` masking so it is correct on
 * both 32-bit and 64-bit builds.
 *
 * @see https://github.com/BLAKE3-team/BLAKE3-specs BLAKE3 specification
 */
final class Blake3
{
    private const OUT_LEN = 32;
    private const BLOCK_LEN = 64;
    private const CHUNK_LEN = 1024;

    private const CHUNK_START = 1 << 0;
    private const CHUNK_END = 1 << 1;
    private const PARENT = 1 << 2;
    private const ROOT = 1 << 3;

    /** @var list<int> */
    private const IV = [
        0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A,
        0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19,
    ];

    /** @var list<int> */
    private const MSG_PERMUTATION = [2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8];

    private function __construct()
    {
    }

    /**
     * Compute the 32-byte BLAKE3 hash of the input bytes.
     */
    public static function hash(string $input): string
    {
        $chainingValue = self::IV;
        $len = strlen($input);

        // Single-chunk fast path covers the entire session distribution
        // preimage (under 1024 bytes) but the chunk-tree code below handles
        // arbitrary input for parity with the Rust reference.
        if ($len <= self::CHUNK_LEN) {
            $cv = self::hashChunk($input, 0, self::ROOT);
            return self::wordsToBytes($cv);
        }

        // General case: hash every 1024-byte chunk into a chaining value, then
        // combine them into a balanced binary tree. The root node's compression
        // carries the ROOT flag, so it is computed last and separately. Session
        // distribution preimages never reach this path (they fit one chunk),
        // but it is implemented for full parity with the Rust reference.
        /** @var list<list<int>> $chunkCvs */
        $chunkCvs = [];
        $chunkCounter = 0;
        $offset = 0;
        while ($offset < $len) {
            $chunk = substr($input, $offset, self::CHUNK_LEN);
            $offset += self::CHUNK_LEN;
            $chunkCvs[] = self::hashChunk($chunk, $chunkCounter, 0);
            $chunkCounter += 1;
        }

        return self::wordsToBytes(self::mergeRoot($chunkCvs, 0, count($chunkCvs)));
    }

    /**
     * Merge chunk chaining values [$start, $end) into a single node. The
     * top-level call returns the ROOT output words; interior nodes return
     * chaining values. The left subtree always covers the largest power of two
     * strictly less than the span, matching the BLAKE3 tree layout.
     *
     * @param list<list<int>> $chunkCvs
     * @return list<int>
     */
    private static function mergeRoot(array $chunkCvs, int $start, int $end): array
    {
        return self::mergeNode($chunkCvs, $start, $end, self::ROOT);
    }

    /**
     * @param list<list<int>> $chunkCvs
     * @return list<int>
     */
    private static function mergeNode(array $chunkCvs, int $start, int $end, int $rootFlag): array
    {
        $count = $end - $start;
        if ($count === 1) {
            return $chunkCvs[$start];
        }
        $leftSpan = 1;
        while ($leftSpan * 2 < $count) {
            $leftSpan *= 2;
        }
        $mid = $start + $leftSpan;
        $left = self::mergeNode($chunkCvs, $start, $mid, 0);
        $right = self::mergeNode($chunkCvs, $mid, $end, 0);
        return self::parentCv($left, $right, self::IV, $rootFlag);
    }

    /**
     * Hash one chunk (up to 1024 bytes) and return its 8-word chaining value
     * (or root output words when ROOT is set in $extraFlags).
     *
     * @return list<int>
     */
    private static function hashChunk(string $chunk, int $chunkCounter, int $extraFlags): array
    {
        $cv = self::IV;
        $len = strlen($chunk);
        $blockCount = (int) ceil(max($len, 1) / self::BLOCK_LEN);

        for ($i = 0; $i < $blockCount; $i++) {
            $block = substr($chunk, $i * self::BLOCK_LEN, self::BLOCK_LEN);
            $blockLen = strlen($block);
            $flags = 0;
            if ($i === 0) {
                $flags |= self::CHUNK_START;
            }
            if ($i === $blockCount - 1) {
                $flags |= self::CHUNK_END | $extraFlags;
            }
            $block = str_pad($block, self::BLOCK_LEN, "\x00");
            $words = self::compress($cv, $block, $chunkCounter, $blockLen, $flags);
            // Chaining value is the first 8 output words.
            $cv = array_slice($words, 0, 8);
            if (($flags & self::ROOT) !== 0) {
                return $cv;
            }
        }

        return $cv;
    }

    /**
     * Compute a parent node chaining value from two child chaining values.
     *
     * @param list<int> $leftCv
     * @param list<int> $rightCv
     * @param list<int> $key
     * @return list<int>
     */
    private static function parentCv(array $leftCv, array $rightCv, array $key, int $flags): array
    {
        $blockWords = array_merge($leftCv, $rightCv);
        $block = '';
        foreach ($blockWords as $word) {
            $block .= pack('V', $word & 0xFFFFFFFF);
        }
        $words = self::compress($key, $block, 0, self::BLOCK_LEN, self::PARENT | $flags);
        return array_slice($words, 0, 8);
    }

    /**
     * BLAKE3 compression function. Returns 16 output words.
     *
     * @param list<int> $chainingValue 8 words
     * @return list<int>
     */
    private static function compress(
        array $chainingValue,
        string $block,
        int $counter,
        int $blockLen,
        int $flags
    ): array {
        $m = array_values(unpack('V16', $block));

        $counterLow = $counter & 0xFFFFFFFF;
        $counterHigh = ($counter >> 32) & 0xFFFFFFFF;

        $state = [
            $chainingValue[0], $chainingValue[1], $chainingValue[2], $chainingValue[3],
            $chainingValue[4], $chainingValue[5], $chainingValue[6], $chainingValue[7],
            self::IV[0], self::IV[1], self::IV[2], self::IV[3],
            $counterLow, $counterHigh, $blockLen & 0xFFFFFFFF, $flags & 0xFFFFFFFF,
        ];

        for ($round = 0; $round < 7; $round++) {
            self::round($state, $m);
            $m = self::permute($m);
        }

        for ($i = 0; $i < 8; $i++) {
            $state[$i] = ($state[$i] ^ $state[$i + 8]) & 0xFFFFFFFF;
            $state[$i + 8] = ($state[$i + 8] ^ $chainingValue[$i]) & 0xFFFFFFFF;
        }

        return $state;
    }

    /**
     * @param array<int,int> $state 16 words (modified in place)
     * @param array<int,int> $m 16 message words
     */
    private static function round(array &$state, array $m): void
    {
        // Columns
        self::g($state, 0, 4, 8, 12, $m[0], $m[1]);
        self::g($state, 1, 5, 9, 13, $m[2], $m[3]);
        self::g($state, 2, 6, 10, 14, $m[4], $m[5]);
        self::g($state, 3, 7, 11, 15, $m[6], $m[7]);
        // Diagonals
        self::g($state, 0, 5, 10, 15, $m[8], $m[9]);
        self::g($state, 1, 6, 11, 12, $m[10], $m[11]);
        self::g($state, 2, 7, 8, 13, $m[12], $m[13]);
        self::g($state, 3, 4, 9, 14, $m[14], $m[15]);
    }

    /**
     * @param array<int,int> $state modified in place
     */
    private static function g(array &$state, int $a, int $b, int $c, int $d, int $mx, int $my): void
    {
        $state[$a] = ($state[$a] + $state[$b] + $mx) & 0xFFFFFFFF;
        $state[$d] = self::rotr($state[$d] ^ $state[$a], 16);
        $state[$c] = ($state[$c] + $state[$d]) & 0xFFFFFFFF;
        $state[$b] = self::rotr($state[$b] ^ $state[$c], 12);
        $state[$a] = ($state[$a] + $state[$b] + $my) & 0xFFFFFFFF;
        $state[$d] = self::rotr($state[$d] ^ $state[$a], 8);
        $state[$c] = ($state[$c] + $state[$d]) & 0xFFFFFFFF;
        $state[$b] = self::rotr($state[$b] ^ $state[$c], 7);
    }

    private static function rotr(int $value, int $bits): int
    {
        $value &= 0xFFFFFFFF;
        return (($value >> $bits) | ($value << (32 - $bits))) & 0xFFFFFFFF;
    }

    /**
     * @param list<int> $m
     * @return list<int>
     */
    private static function permute(array $m): array
    {
        $out = [];
        foreach (self::MSG_PERMUTATION as $index) {
            $out[] = $m[$index];
        }
        return $out;
    }

    /**
     * @param list<int> $words 8 words
     */
    private static function wordsToBytes(array $words): string
    {
        $out = '';
        for ($i = 0; $i < self::OUT_LEN / 4; $i++) {
            $out .= pack('V', $words[$i] & 0xFFFFFFFF);
        }
        return $out;
    }
}
