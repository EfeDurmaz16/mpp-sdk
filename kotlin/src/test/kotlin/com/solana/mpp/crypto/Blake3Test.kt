package com.solana.mpp.crypto

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals

/**
 * BLAKE3 hash-mode parity against the published official test vectors and
 * values generated from the Rust spine's `blake3` crate (the same crate the
 * payment-channels program uses). Mirrors the Swift Blake3Tests.
 */
class Blake3Test {
    private fun hex(bytes: ByteArray): String =
        bytes.joinToString("") { "%02x".format(it.toInt() and 0xff) }

    @Test
    fun emptyInput() {
        assertEquals(
            "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262",
            hex(Blake3.hash(ByteArray(0))),
        )
    }

    @Test
    fun abc() {
        assertEquals(
            "6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85",
            hex(Blake3.hash("abc".encodeToByteArray())),
        )
    }

    @Test
    fun exactlyOneChunk1024() {
        val input = ByteArray(1024) { 'a'.code.toByte() }
        assertEquals(
            "5a1c9e5d85d9898297037e8e24f69bb0e604a84c91c3b3ef4784a374812900d9",
            hex(Blake3.hash(input)),
        )
    }

    @Test
    fun twoChunks1025() {
        val input = ByteArray(1025) { 'a'.code.toByte() }
        assertEquals(
            "c59d2e12583df14d951e757a42f1734d355c8c5b1db6b6a33ab2bfabeed40c7d",
            hex(Blake3.hash(input)),
        )
    }

    @Test
    fun multipleChunks3000() {
        val input = ByteArray(3000) { 'z'.code.toByte() }
        assertEquals(
            "f504919260eb35b94075bfd361857c0f5e70dd1e6a80e75dc178c34d46e1023b",
            hex(Blake3.hash(input)),
        )
    }

    @Test
    fun incrementalMatchesOneShot() {
        val full = ByteArray(2500) { (it % 256).toByte() }
        val hasher = Blake3()
        hasher.update(full.copyOfRange(0, 10))
        hasher.update(full.copyOfRange(10, 1024))
        hasher.update(full.copyOfRange(1024, full.size))
        assertContentEquals(Blake3.hash(full), hasher.finalize())
    }
}
