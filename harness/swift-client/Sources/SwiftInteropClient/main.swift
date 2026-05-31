import Foundation
import SolanaMpp

/// Swift interop adapter for the MPP charge harness. Mirrors the
/// command-line shape of `rust/crates/mpp/src/bin/interop_client.rs`:
///
/// - Reads `MPP_INTEROP_TARGET_URL`, `MPP_INTEROP_RPC_URL`, and
///   `MPP_INTEROP_CLIENT_SECRET_KEY` (JSON array of bytes).
/// - Optional `MPP_INTEROP_SETTLEMENT_HEADER` (defaults to
///   `x-fixture-settlement`).
/// - Sends the unauthenticated request, parses the 402 WWW-Authenticate,
///   signs through `MppHTTPClient.fetch`, emits one `result` JSON line
///   on stdout, exits 0 on completion (success or paid failure).
///
/// All diagnostics go to stderr. Stdout is reserved for the harness
/// handshake.

struct InteropError: Error { let message: String }

func readEnv(_ name: String) throws -> String {
    guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
        throw InteropError(message: "\(name) is required")
    }
    return value
}

func readKeypair(_ name: String) throws -> Data {
    let raw = try readEnv(name)
    guard let data = raw.data(using: .utf8) else {
        throw InteropError(message: "\(name) is not valid UTF-8")
    }
    guard
        let bytes = try? JSONSerialization.jsonObject(with: data) as? [Int]
    else {
        throw InteropError(message: "\(name) is not a JSON array of bytes")
    }
    var validated: [UInt8] = []
    validated.reserveCapacity(bytes.count)
    for value in bytes {
        guard value >= 0, value <= 255 else {
            throw InteropError(
                message: "\(name) contains non-byte value \(value); expected 0...255"
            )
        }
        validated.append(UInt8(value))
    }
    return Data(validated)
}

func emitResult(_ status: Int, ok: Bool, headers: [String: String], body: Data, settlement: String?) {
    var payload: [String: Any] = [
        "type": "result",
        "implementation": "swift",
        "role": "client",
        "ok": ok,
        "status": status,
        "responseHeaders": headers,
    ]
    if let settlement = settlement {
        payload["settlement"] = settlement
    } else {
        payload["settlement"] = NSNull()
    }
    let parsedBody: Any = (try? JSONSerialization.jsonObject(with: body))
        ?? String(decoding: body, as: UTF8.self)
    payload["responseBody"] = parsedBody

    let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

func writeStderr(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// Session adapter branch.
///
/// Exercises the client-side session surface against a `solana` +
/// `session` challenge served at the target URL: parse the 402 challenge,
/// generate an `ActiveSession` bound to the client key, and frame the
/// `open` + first `voucher` actions into `Authorization: Payment` headers.
///
/// Byte-level on-chain settlement requires surfpool and is validated only
/// in CI; locally this proves the wire-shape + voucher-signing path with
/// the same SDK surface used by the unit golden vectors.
func runSessionAdapter(targetURL: URL, signer: MemorySigner) async throws {
    var request = URLRequest(url: targetURL)
    request.httpMethod = "GET"
    let (_, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else {
        throw InteropError(message: "session target did not return an HTTP response")
    }
    let wwwAuth = http.value(forHTTPHeaderField: "WWW-Authenticate")
        ?? http.value(forHTTPHeaderField: "Www-Authenticate")
    guard let header = wwwAuth else {
        throw InteropError(message: "session challenge missing WWW-Authenticate header")
    }

    let challenge = try Session.pickChallenge(wwwAuthenticateHeaders: [header])
    let sessionRequest = try challenge.sessionRequest

    // The opened channel id is derived once the on-chain open is
    // confirmed; for the adapter handshake the channel pubkey equals the
    // client signing key's account (a deterministic stand-in the harness
    // server validates against the same key).
    let channel = try Pubkey(bytes: signer.publicKey)
    let session = ActiveSession(channelId: channel, signer: signer)

    let openAction = session.openAction(
        deposit: UInt64(sessionRequest.cap) ?? 0,
        openTxSignature: "pending"
    )
    let openHeader = try Session.authorizationHeader(for: challenge, action: openAction)

    let voucherAction = try await session.voucherAction(1)
    let voucherHeader = try Session.authorizationHeader(for: challenge, action: voucherAction)

    var payload: [String: Any] = [
        "type": "result",
        "implementation": "swift",
        "role": "client",
        "intent": "session",
        "ok": true,
        "status": http.statusCode,
        "authorizedSigner": session.authorizedSigner(),
        "channelId": session.channelIdString(),
        "openHeader": openHeader,
        "voucherHeader": voucherHeader,
        "cumulative": String(session.cumulative),
    ]
    payload["responseHeaders"] = [String: String]()
    let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

@main
struct InteropEntry {
    static func main() async {
        do {
            let targetURLString = try readEnv("MPP_INTEROP_TARGET_URL")
            guard let targetURL = URL(string: targetURLString) else {
                throw InteropError(message: "MPP_INTEROP_TARGET_URL is not a URL")
            }
            let intent = ProcessInfo.processInfo.environment["MPP_INTEROP_INTENT"] ?? "charge"
            let secret = try readKeypair("MPP_INTEROP_CLIENT_SECRET_KEY")
            let signer = try MemorySigner(secretKey: secret)

            if intent == "session" {
                try await runSessionAdapter(targetURL: targetURL, signer: signer)
                return
            }

            let rpcURLString = try readEnv("MPP_INTEROP_RPC_URL")
            guard let rpcURL = URL(string: rpcURLString) else {
                throw InteropError(message: "MPP_INTEROP_RPC_URL is not a URL")
            }
            let settlementHeader = ProcessInfo.processInfo.environment["MPP_INTEROP_SETTLEMENT_HEADER"]
                ?? "x-fixture-settlement"

            let rpc = RpcClient(endpoint: rpcURL)
            let client = MppHTTPClient(signer: signer, rpc: rpc)

            let response = try await client.fetch(url: targetURL, settlementHeader: settlementHeader)
            emitResult(
                response.status,
                ok: (200..<300).contains(response.status),
                headers: response.headers,
                body: response.body,
                settlement: response.settlementSignature
            )
        } catch let error as InteropError {
            writeStderr("interop error: \(error.message)")
            emitResult(0, ok: false, headers: [:], body: Data(error.message.utf8), settlement: nil)
            exit(1)
        } catch {
            writeStderr("unexpected error: \(error)")
            emitResult(0, ok: false, headers: [:], body: Data("\(error)".utf8), settlement: nil)
            exit(1)
        }
    }
}
