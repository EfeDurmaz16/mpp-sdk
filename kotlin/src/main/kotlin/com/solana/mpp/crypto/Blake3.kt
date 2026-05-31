package com.solana.mpp.crypto

/**
 * Pure-Kotlin BLAKE3 (hash mode, default 32 byte output).
 *
 * The payment-channels program hashes its distribution preimage with
 * BLAKE3 (`rust/crates/mpp/src/program/payment_channels.rs`
 * `distribution_hash`, backed by the `blake3` crate). The JVM has no
 * system BLAKE3 and the SDK keeps a thin dependency surface, so this
 * implements the reference algorithm from the BLAKE3 spec directly,
 * mirroring the hand-rolled Swift port (`swift/Sources/SolanaMpp/Crypto/Blake3.swift`).
 *
 * Scope: incremental [update] + 32 byte [finalize] (root) in hash mode.
 * Keyed-hash and derive-key modes are not implemented because the
 * payment-channels preimage only needs the unkeyed root hash. Parity is
 * locked by Blake3Test against the published official test vectors.
 */
class Blake3 {
    private val key: IntArray = IV.copyOf()
    private val flags = 0
    private var chunkState = ChunkState(IV.copyOf(), 0L, 0)
    private val cvStack = ArrayDeque<IntArray>()

    /** Feeds more input into the hasher. */
    fun update(input: ByteArray) {
        var offset = 0
        var len = input.size
        while (len > 0) {
            if (chunkState.length() == CHUNK_LEN) {
                val chunkCv = chunkState.output().chainingValue()
                val totalChunks = chunkState.chunkCounter + 1
                addChunkChainingValue(chunkCv, totalChunks)
                chunkState = ChunkState(key.copyOf(), totalChunks, flags)
            }
            val want = CHUNK_LEN - chunkState.length()
            val take = minOf(want, len)
            chunkState.update(input, offset, take)
            offset += take
            len -= take
        }
    }

    /** Returns the 32 byte root hash. */
    fun finalize(): ByteArray {
        var output = chunkState.output()
        var remaining = cvStack.size
        while (remaining > 0) {
            remaining -= 1
            output = parentOutput(cvStack[remaining], output.chainingValue(), key, flags)
        }
        return output.rootBytes(OUT_LEN)
    }

    private fun addChunkChainingValue(newCv: IntArray, totalChunks: Long) {
        var cv = newCv
        var total = totalChunks
        while (total and 1L == 0L) {
            cv = parentOutput(cvStack.removeLast(), cv, key, flags).chainingValue()
            total = total shr 1
        }
        cvStack.addLast(cv)
    }

    private class Output(
        val inputChainingValue: IntArray,
        val blockWords: IntArray,
        val counter: Long,
        val blockLen: Int,
        val flags: Int,
    ) {
        fun chainingValue(): IntArray =
            compress(inputChainingValue, blockWords, counter, blockLen, flags).copyOf(8)

        fun rootBytes(length: Int): ByteArray {
            val out = ByteArray(length)
            var written = 0
            var outputBlockCounter = 0L
            while (written < length) {
                val words = compress(
                    inputChainingValue, blockWords, outputBlockCounter, blockLen, flags or ROOT,
                )
                for (word in words) {
                    var w = word
                    var b = 0
                    while (b < 4 && written < length) {
                        out[written] = (w and 0xff).toByte()
                        w = w ushr 8
                        written += 1
                        b += 1
                    }
                    if (written >= length) break
                }
                outputBlockCounter += 1
            }
            return out
        }
    }

    private class ChunkState(
        var chainingValue: IntArray,
        val chunkCounter: Long,
        val flags: Int,
    ) {
        private val block = ByteArray(BLOCK_LEN)
        private var blockLen = 0
        private var blocksCompressed = 0

        fun length(): Int = BLOCK_LEN * blocksCompressed + blockLen

        private fun startFlag(): Int = if (blocksCompressed == 0) CHUNK_START else 0

        fun update(input: ByteArray, start: Int, count: Int) {
            var offset = start
            var remaining = count
            while (remaining > 0) {
                if (blockLen == BLOCK_LEN) {
                    val blockWords = wordsFromLittleEndian(block)
                    chainingValue = compress(
                        chainingValue, blockWords, chunkCounter, BLOCK_LEN, flags or startFlag(),
                    ).copyOf(8)
                    blocksCompressed += 1
                    block.fill(0)
                    blockLen = 0
                }
                val want = BLOCK_LEN - blockLen
                val take = minOf(want, remaining)
                System.arraycopy(input, offset, block, blockLen, take)
                blockLen += take
                offset += take
                remaining -= take
            }
        }

        fun output(): Output {
            val blockWords = wordsFromLittleEndian(block)
            return Output(chainingValue, blockWords, chunkCounter, blockLen, flags or startFlag() or CHUNK_END)
        }
    }

    companion object {
        private const val OUT_LEN = 32
        private const val BLOCK_LEN = 64
        private const val CHUNK_LEN = 1024

        private const val CHUNK_START = 1 shl 0
        private const val CHUNK_END = 1 shl 1
        private const val PARENT = 1 shl 2
        private const val ROOT = 1 shl 3

        private val IV = intArrayOf(
            0x6A09E667, -0x4498517B, 0x3C6EF372, -0x5AB00AC6,
            0x510E527F, -0x64FA9774, 0x1F83D9AB, 0x5BE0CD19,
        )

        private val MSG_PERMUTATION = intArrayOf(
            2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8,
        )

        /** One-shot convenience: BLAKE3-256 of [data]. */
        fun hash(data: ByteArray): ByteArray {
            val hasher = Blake3()
            hasher.update(data)
            return hasher.finalize()
        }

        private fun rotr(x: Int, n: Int): Int = (x ushr n) or (x shl (32 - n))

        private fun g(state: IntArray, a: Int, b: Int, c: Int, d: Int, mx: Int, my: Int) {
            state[a] = state[a] + state[b] + mx
            state[d] = rotr(state[d] xor state[a], 16)
            state[c] = state[c] + state[d]
            state[b] = rotr(state[b] xor state[c], 12)
            state[a] = state[a] + state[b] + my
            state[d] = rotr(state[d] xor state[a], 8)
            state[c] = state[c] + state[d]
            state[b] = rotr(state[b] xor state[c], 7)
        }

        private fun roundFn(state: IntArray, m: IntArray) {
            g(state, 0, 4, 8, 12, m[0], m[1])
            g(state, 1, 5, 9, 13, m[2], m[3])
            g(state, 2, 6, 10, 14, m[4], m[5])
            g(state, 3, 7, 11, 15, m[6], m[7])
            g(state, 0, 5, 10, 15, m[8], m[9])
            g(state, 1, 6, 11, 12, m[10], m[11])
            g(state, 2, 7, 8, 13, m[12], m[13])
            g(state, 3, 4, 9, 14, m[14], m[15])
        }

        private fun compress(
            chainingValue: IntArray,
            blockWords: IntArray,
            counter: Long,
            blockLen: Int,
            flags: Int,
        ): IntArray {
            val state = intArrayOf(
                chainingValue[0], chainingValue[1], chainingValue[2], chainingValue[3],
                chainingValue[4], chainingValue[5], chainingValue[6], chainingValue[7],
                IV[0], IV[1], IV[2], IV[3],
                counter.toInt(),
                (counter ushr 32).toInt(),
                blockLen, flags,
            )
            var block = blockWords
            for (round in 0 until 7) {
                roundFn(state, block)
                if (round < 6) {
                    val permuted = IntArray(16)
                    for (i in 0 until 16) permuted[i] = block[MSG_PERMUTATION[i]]
                    block = permuted
                }
            }
            for (i in 0 until 8) {
                state[i] = state[i] xor state[i + 8]
                state[i + 8] = state[i + 8] xor chainingValue[i]
            }
            return state
        }

        private fun wordsFromLittleEndian(bytes: ByteArray): IntArray {
            val words = IntArray(bytes.size / 4)
            for (i in words.indices) {
                val base = i * 4
                words[i] = (bytes[base].toInt() and 0xff) or
                    ((bytes[base + 1].toInt() and 0xff) shl 8) or
                    ((bytes[base + 2].toInt() and 0xff) shl 16) or
                    ((bytes[base + 3].toInt() and 0xff) shl 24)
            }
            return words
        }

        private fun parentOutput(left: IntArray, right: IntArray, key: IntArray, flags: Int): Output {
            val blockWords = IntArray(16)
            for (i in 0 until 8) blockWords[i] = left[i]
            for (i in 0 until 8) blockWords[8 + i] = right[i]
            return Output(key, blockWords, 0L, BLOCK_LEN, flags or PARENT)
        }
    }
}
