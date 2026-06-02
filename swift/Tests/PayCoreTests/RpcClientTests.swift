import Foundation
import Testing
@testable import PayCore

/// URLProtocol that returns a canned status + body keyed by a per-session
/// header, so concurrent tests do not race on shared static state.
private final class InjectingProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responses: [String: (Int, String)] = [:]
    nonisolated(unsafe) static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let key = request.value(forHTTPHeaderField: "X-Stub-Key") ?? ""
        Self.lock.lock()
        let (status, body) = Self.responses[key] ?? (200, "{}")
        Self.lock.unlock()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("RpcClient JSON-RPC parsing")
struct RpcClientTests {
    /// Each call gets a unique key so the canned response is isolated even
    /// when suites run in parallel.
    private func makeClient(status: Int, json: String) -> RpcClient {
        let key = UUID().uuidString
        InjectingProtocol.lock.lock()
        InjectingProtocol.responses[key] = (status, json)
        InjectingProtocol.lock.unlock()

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [InjectingProtocol.self]
        config.httpAdditionalHeaders = ["X-Stub-Key": key]
        let session = URLSession(configuration: config)
        return RpcClient(endpoint: URL(string: "https://rpc.example")!, urlSession: session)
    }

    @Test
    func getLatestBlockhashParsesResult() async throws {
        let blockhash = Base58.encode(Data(repeating: 0, count: 32))
        let client = makeClient(
            status: 200,
            json: "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"value\":{\"blockhash\":\"\(blockhash)\"}}}"
        )
        let result = try await client.getLatestBlockhash()
        #expect(result.base58 == blockhash)
        #expect(result.bytes.count == 32)
    }

    @Test
    func getLatestBlockhashRejectsNon32ByteHash() async {
        let shortHash = Base58.encode(Data(repeating: 0, count: 4))
        let client = makeClient(
            status: 200,
            json: "{\"result\":{\"value\":{\"blockhash\":\"\(shortHash)\"}}}"
        )
        await #expect(throws: PayCoreError.self) {
            _ = try await client.getLatestBlockhash()
        }
    }

    @Test
    func getAccountOwnerReadsOwnerField() async throws {
        let client = makeClient(
            status: 200,
            json: "{\"result\":{\"value\":{\"owner\":\"TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA\"}}}"
        )
        let owner = try await client.getAccountOwner(pubkeyBase58: "anything")
        #expect(owner == "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA")
    }

    @Test
    func rpcErrorBodyBecomesRpcFailure() async {
        let client = makeClient(
            status: 200,
            json: "{\"error\":{\"code\":-32002,\"message\":\"blockhash not found\"}}"
        )
        await #expect(throws: PayCoreError.self) {
            _ = try await client.sendTransaction("dGVzdA==")
        }
    }

    @Test
    func httpErrorStatusBecomesRpcFailure() async {
        let client = makeClient(status: 500, json: "{}")
        await #expect(throws: PayCoreError.self) {
            _ = try await client.getLatestBlockhash()
        }
    }

    @Test
    func sendTransactionReturnsSignature() async throws {
        let client = makeClient(
            status: 200,
            json: "{\"result\":\"5xSig\"}"
        )
        let sig = try await client.sendTransaction("dGVzdA==", skipPreflight: true)
        #expect(sig == "5xSig")
    }
}
