import Foundation
import Testing
@testable import PayCore

@Suite("MemorySigner")
struct MemorySignerTests {
    @Test
    func secretKeyInitDerivesPublicKeyAndAddress() throws {
        let seed = Data(repeating: 3, count: 32)
        let signer = try MemorySigner(secretKey: seed)

        #expect(signer.publicKey.count == 32)
        // address is the base58 of the public key
        #expect(signer.address == Base58.encode(signer.publicKey))
    }

    @Test
    func secretKeyInitSignsAVerifiableSignature() async throws {
        let seed = Data(repeating: 9, count: 32)
        let signer = try MemorySigner(secretKey: seed)
        let message = Data("charge".utf8)

        let signature = try await signer.sign(message: message)

        #expect(signature.count == 64)
        #expect(
            try Ed25519.verify(
                signature: signature,
                message: message,
                publicKey: signer.publicKey
            )
        )
    }

    @Test
    func cannedSignatureInitReturnsTheSameSignatureEveryCall() async throws {
        let publicKey = Data(repeating: 1, count: 32)
        let canned = Data(repeating: 7, count: 64)
        let signer = MemorySigner(
            publicKey: publicKey,
            address: "Address1111",
            signature: canned
        )

        #expect(signer.publicKey == publicKey)
        #expect(signer.address == "Address1111")
        #expect(try await signer.sign(message: Data("a".utf8)) == canned)
        #expect(try await signer.sign(message: Data("b".utf8)) == canned)
    }

    @Test
    func customHandlerInitRoutesThroughTheClosure() async throws {
        let publicKey = Data(repeating: 2, count: 32)
        let signer = MemorySigner(
            publicKey: publicKey,
            address: "Address2222"
        ) { message in
            Data(message.reversed())
        }

        let out = try await signer.sign(message: Data([1, 2, 3]))
        #expect(out == Data([3, 2, 1]))
    }
}
