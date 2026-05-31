import Foundation

/// Pure-Swift BLAKE3 (hash mode, default 32-byte output).
///
/// The payment-channels program hashes its distribution preimage with
/// BLAKE3 (`rust/crates/mpp/src/program/payment_channels.rs`
/// `distribution_hash`, backed by the `blake3` crate). Swift has no
/// system BLAKE3 and the SDK keeps zero external dependencies, so this
/// implements the reference algorithm from the BLAKE3 spec directly.
///
/// Scope: incremental `update` + 32-byte `finalize` (root) in hash mode.
/// Keyed-hash and derive-key modes are not implemented because the
/// payment-channels preimage only needs the unkeyed root hash. Parity is
/// locked by `Blake3Tests` against the published official test vectors.
public struct Blake3 {
    private static let outLen = 32
    private static let keyLen = 32
    private static let blockLen = 64
    private static let chunkLen = 1024

    // Domain-flag bits.
    private static let chunkStart: UInt32 = 1 << 0
    private static let chunkEnd: UInt32 = 1 << 1
    private static let parent: UInt32 = 1 << 2
    private static let root: UInt32 = 1 << 3

    private static let iv: [UInt32] = [
        0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A,
        0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19,
    ]

    private static let msgPermutation: [Int] = [
        2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8,
    ]

    private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 {
        (x >> n) | (x << (32 - n))
    }

    private static func g(_ state: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int, _ mx: UInt32, _ my: UInt32) {
        state[a] = state[a] &+ state[b] &+ mx
        state[d] = rotr(state[d] ^ state[a], 16)
        state[c] = state[c] &+ state[d]
        state[b] = rotr(state[b] ^ state[c], 12)
        state[a] = state[a] &+ state[b] &+ my
        state[d] = rotr(state[d] ^ state[a], 8)
        state[c] = state[c] &+ state[d]
        state[b] = rotr(state[b] ^ state[c], 7)
    }

    private static func roundFn(_ state: inout [UInt32], _ m: [UInt32]) {
        g(&state, 0, 4, 8, 12, m[0], m[1])
        g(&state, 1, 5, 9, 13, m[2], m[3])
        g(&state, 2, 6, 10, 14, m[4], m[5])
        g(&state, 3, 7, 11, 15, m[6], m[7])
        g(&state, 0, 5, 10, 15, m[8], m[9])
        g(&state, 1, 6, 11, 12, m[10], m[11])
        g(&state, 2, 7, 8, 13, m[12], m[13])
        g(&state, 3, 4, 9, 14, m[14], m[15])
    }

    /// The BLAKE3 compression function. Returns the 16-word output state.
    private static func compress(
        chainingValue: [UInt32],
        blockWords: [UInt32],
        counter: UInt64,
        blockLen: UInt32,
        flags: UInt32
    ) -> [UInt32] {
        var state: [UInt32] = [
            chainingValue[0], chainingValue[1], chainingValue[2], chainingValue[3],
            chainingValue[4], chainingValue[5], chainingValue[6], chainingValue[7],
            iv[0], iv[1], iv[2], iv[3],
            UInt32(truncatingIfNeeded: counter),
            UInt32(truncatingIfNeeded: counter >> 32),
            blockLen, flags,
        ]
        var block = blockWords

        for round in 0..<7 {
            roundFn(&state, block)
            if round < 6 {
                var permuted = [UInt32](repeating: 0, count: 16)
                for i in 0..<16 {
                    permuted[i] = block[msgPermutation[i]]
                }
                block = permuted
            }
        }

        for i in 0..<8 {
            state[i] ^= state[i + 8]
            state[i + 8] ^= chainingValue[i]
        }
        return state
    }

    private static func wordsFromLittleEndian(_ bytes: [UInt8]) -> [UInt32] {
        var words = [UInt32](repeating: 0, count: bytes.count / 4)
        for i in 0..<words.count {
            let base = i * 4
            words[i] = UInt32(bytes[base])
                | (UInt32(bytes[base + 1]) << 8)
                | (UInt32(bytes[base + 2]) << 16)
                | (UInt32(bytes[base + 3]) << 24)
        }
        return words
    }

    // ── Output (extensible) ────────────────────────────────────────────

    private struct Output {
        var inputChainingValue: [UInt32]
        var blockWords: [UInt32]
        var counter: UInt64
        var blockLen: UInt32
        var flags: UInt32

        func chainingValue() -> [UInt32] {
            Array(
                compress(
                    chainingValue: inputChainingValue,
                    blockWords: blockWords,
                    counter: counter,
                    blockLen: blockLen,
                    flags: flags
                )[0..<8]
            )
        }

        func rootBytes(length: Int) -> [UInt8] {
            var out = [UInt8]()
            out.reserveCapacity(length)
            var outputBlockCounter: UInt64 = 0
            while out.count < length {
                let words = compress(
                    chainingValue: inputChainingValue,
                    blockWords: blockWords,
                    counter: outputBlockCounter,
                    blockLen: blockLen,
                    flags: flags | root
                )
                for word in words {
                    out.append(UInt8(truncatingIfNeeded: word))
                    out.append(UInt8(truncatingIfNeeded: word >> 8))
                    out.append(UInt8(truncatingIfNeeded: word >> 16))
                    out.append(UInt8(truncatingIfNeeded: word >> 24))
                    if out.count >= length { break }
                }
                outputBlockCounter += 1
            }
            return Array(out.prefix(length))
        }
    }

    // ── Chunk state ────────────────────────────────────────────────────

    private struct ChunkState {
        var chainingValue: [UInt32]
        var chunkCounter: UInt64
        var block: [UInt8]
        var blockLen: Int
        var blocksCompressed: Int
        var flags: UInt32

        init(key: [UInt32], chunkCounter: UInt64, flags: UInt32) {
            self.chainingValue = key
            self.chunkCounter = chunkCounter
            self.block = [UInt8](repeating: 0, count: Blake3.blockLen)
            self.blockLen = 0
            self.blocksCompressed = 0
            self.flags = flags
        }

        var length: Int { Blake3.blockLen * blocksCompressed + blockLen }

        func startFlag() -> UInt32 {
            blocksCompressed == 0 ? Blake3.chunkStart : 0
        }

        mutating func update(_ input: ArraySlice<UInt8>) {
            var remaining = input
            while !remaining.isEmpty {
                if blockLen == Blake3.blockLen {
                    let blockWords = Blake3.wordsFromLittleEndian(block)
                    chainingValue = Array(
                        Blake3.compress(
                            chainingValue: chainingValue,
                            blockWords: blockWords,
                            counter: chunkCounter,
                            blockLen: UInt32(Blake3.blockLen),
                            flags: flags | startFlag()
                        )[0..<8]
                    )
                    blocksCompressed += 1
                    block = [UInt8](repeating: 0, count: Blake3.blockLen)
                    blockLen = 0
                }
                let want = Blake3.blockLen - blockLen
                let take = min(want, remaining.count)
                let start = remaining.startIndex
                for i in 0..<take {
                    block[blockLen + i] = remaining[start + i]
                }
                blockLen += take
                remaining = remaining[(start + take)...]
            }
        }

        func output() -> Output {
            let blockWords = Blake3.wordsFromLittleEndian(block)
            return Output(
                inputChainingValue: chainingValue,
                blockWords: blockWords,
                counter: chunkCounter,
                blockLen: UInt32(blockLen),
                flags: flags | startFlag() | Blake3.chunkEnd
            )
        }
    }

    private static func parentOutput(
        left: [UInt32],
        right: [UInt32],
        key: [UInt32],
        flags: UInt32
    ) -> Output {
        var blockWords = [UInt32](repeating: 0, count: 16)
        for i in 0..<8 { blockWords[i] = left[i] }
        for i in 0..<8 { blockWords[8 + i] = right[i] }
        return Output(
            inputChainingValue: key,
            blockWords: blockWords,
            counter: 0,
            blockLen: UInt32(blockLen),
            flags: flags | parent
        )
    }

    private static func parentChainingValue(
        left: [UInt32],
        right: [UInt32],
        key: [UInt32],
        flags: UInt32
    ) -> [UInt32] {
        parentOutput(left: left, right: right, key: key, flags: flags).chainingValue()
    }

    // ── Hasher ─────────────────────────────────────────────────────────

    private var chunkState: ChunkState
    private let key: [UInt32]
    private var cvStack: [[UInt32]] = []
    private let flags: UInt32

    public init() {
        self.key = Blake3.iv
        self.flags = 0
        self.chunkState = ChunkState(key: Blake3.iv, chunkCounter: 0, flags: 0)
    }

    private mutating func addChunkChainingValue(_ newCV: [UInt32], totalChunks: UInt64) {
        var cv = newCV
        var total = totalChunks
        while total & 1 == 0 {
            cv = Blake3.parentChainingValue(left: cvStack.removeLast(), right: cv, key: key, flags: flags)
            total >>= 1
        }
        cvStack.append(cv)
    }

    public mutating func update(_ data: Data) {
        update(Array(data))
    }

    public mutating func update(_ input: [UInt8]) {
        var remaining = input[...]
        while !remaining.isEmpty {
            if chunkState.length == Blake3.chunkLen {
                let chunkCV = chunkState.output().chainingValue()
                let totalChunks = chunkState.chunkCounter + 1
                addChunkChainingValue(chunkCV, totalChunks: totalChunks)
                chunkState = ChunkState(key: key, chunkCounter: totalChunks, flags: flags)
            }
            let want = Blake3.chunkLen - chunkState.length
            let take = min(want, remaining.count)
            let start = remaining.startIndex
            chunkState.update(remaining[start..<(start + take)])
            remaining = remaining[(start + take)...]
        }
    }

    public func finalize() -> Data {
        var output = chunkState.output()
        var parentNodesRemaining = cvStack.count
        while parentNodesRemaining > 0 {
            parentNodesRemaining -= 1
            output = Blake3.parentOutput(
                left: cvStack[parentNodesRemaining],
                right: output.chainingValue(),
                key: key,
                flags: flags
            )
        }
        return Data(output.rootBytes(length: Blake3.outLen))
    }

    /// One-shot convenience: BLAKE3-256 of `data`.
    public static func hash(_ data: Data) -> Data {
        var hasher = Blake3()
        hasher.update(data)
        return hasher.finalize()
    }
}
