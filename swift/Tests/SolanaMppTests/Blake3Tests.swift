import Foundation
import Testing
@testable import SolanaMpp

/// BLAKE3 parity against published official test vectors and against
/// values generated from the Rust spine's `blake3` crate (the same crate
/// the payment-channels program uses).
@Suite("BLAKE3 hash-mode parity")
struct Blake3Tests {
    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    @Test
    func emptyInput() {
        // Official BLAKE3 test vector for the empty input.
        #expect(hex(Blake3.hash(Data())) ==
            "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262")
    }

    @Test
    func abc() {
        #expect(hex(Blake3.hash(Data("abc".utf8))) ==
            "6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85")
    }

    @Test
    func exactlyOneChunk1024() {
        // 1024 'a' bytes exercises the single full-chunk boundary.
        let input = Data(repeating: UInt8(ascii: "a"), count: 1024)
        #expect(hex(Blake3.hash(input)) ==
            "5a1c9e5d85d9898297037e8e24f69bb0e604a84c91c3b3ef4784a374812900d9")
    }

    @Test
    func twoChunks1025() {
        // 1025 bytes crosses the chunk boundary, exercising the CV stack.
        let input = Data(repeating: UInt8(ascii: "a"), count: 1025)
        #expect(hex(Blake3.hash(input)) ==
            "c59d2e12583df14d951e757a42f1734d355c8c5b1db6b6a33ab2bfabeed40c7d")
    }

    @Test
    func multipleChunks3000() {
        // 3000 bytes spans three chunks; locks the tree-merge ordering.
        let input = Data(repeating: UInt8(ascii: "z"), count: 3000)
        #expect(hex(Blake3.hash(input)) ==
            "f504919260eb35b94075bfd361857c0f5e70dd1e6a80e75dc178c34d46e1023b")
    }

    @Test
    func incrementalMatchesOneShot() {
        let full = Data((0..<2500).map { UInt8($0 % 256) })
        var hasher = Blake3()
        hasher.update(full.prefix(10))
        hasher.update(full.dropFirst(10).prefix(1014))
        hasher.update(full.dropFirst(1024))
        #expect(hasher.finalize() == Blake3.hash(full))
    }
}
