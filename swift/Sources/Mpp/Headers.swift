import Foundation
import PayCore

public enum MppHeaders {
    public static let paymentScheme = "Payment"

    public static func parseWWWAuthenticate(_ header: String) throws -> PaymentChallenge {
        let rest = try paymentSchemePayload(header)
        let params = try parseAuthParams(rest)

        guard let request = params["request"], !request.isEmpty else {
            throw MppError.missingField("request")
        }
        guard let id = params["id"], !id.isEmpty else {
            throw MppError.missingField("id")
        }
        guard let realm = params["realm"], !realm.isEmpty else {
            throw MppError.missingField("realm")
        }
        guard let method = params["method"], !method.isEmpty else {
            throw MppError.missingField("method")
        }
        guard let intent = params["intent"], !intent.isEmpty else {
            throw MppError.missingField("intent")
        }

        return try PaymentChallenge(
            id: id,
            realm: realm,
            method: method,
            intent: intent,
            request: request,
            expires: params["expires"],
            digest: params["digest"],
            opaque: params["opaque"]
        )
    }

    /// Parse every `Payment` challenge carried across one or more
    /// `WWW-Authenticate` header values, splitting combined values that pack
    /// multiple `Payment ...` challenges into a single header line.
    ///
    /// Mirrors the rust `parse_www_authenticate_all`
    /// (`rust/crates/mpp/src/protocol/core/headers.rs:70`): each header value
    /// is split at quote-aware `Payment`-scheme boundaries, then each chunk
    /// is parsed. Chunks that fail to parse are dropped, matching the
    /// client's tolerant selection behaviour.
    public static func parseWWWAuthenticateAll(_ headers: [String]) -> [PaymentChallenge] {
        var result: [PaymentChallenge] = []
        for header in headers {
            for chunk in splitPaymentChallengeValues(header) {
                if let challenge = try? parseWWWAuthenticate(chunk) {
                    result.append(challenge)
                }
            }
        }
        return result
    }

    /// Split a single `WWW-Authenticate` value into its constituent
    /// `Payment ...` challenge substrings. A boundary is a `Payment` token
    /// (case-insensitive) followed by whitespace, located outside any quoted
    /// string and either at the start of the value or right after a comma.
    /// Mirrors the rust `split_payment_challenge_values`.
    static func splitPaymentChallengeValues(_ header: String) -> [String] {
        let chars = Array(header)
        var starts: [Int] = []
        var inQuote = false
        var escaped = false
        var i = 0
        let scheme = Array(paymentScheme)

        func isSchemeStart(_ index: Int) -> Bool {
            let end = index + scheme.count
            guard end < chars.count else { return false }
            for offset in 0..<scheme.count {
                if String(chars[index + offset]).lowercased()
                    != String(scheme[offset]).lowercased() {
                    return false
                }
            }
            guard chars[end].isWhitespace else { return false }
            var previous = index
            while previous > 0, chars[previous - 1].isWhitespace {
                previous -= 1
            }
            return previous == 0 || chars[previous - 1] == ","
        }

        while i < chars.count {
            let char = chars[i]
            if inQuote {
                if escaped {
                    escaped = false
                } else if char == "\\" {
                    escaped = true
                } else if char == "\"" {
                    inQuote = false
                }
                i += 1
                continue
            }
            if char == "\"" {
                inQuote = true
                i += 1
                continue
            }
            if isSchemeStart(i) {
                starts.append(i)
                i += scheme.count
                continue
            }
            i += 1
        }

        var chunks: [String] = []
        for (index, start) in starts.enumerated() {
            let end = index + 1 < starts.count ? starts[index + 1] : chars.count
            var chunk = String(chars[start..<end])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            while chunk.hasSuffix(",") {
                chunk = String(chunk.dropLast())
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if !chunk.isEmpty {
                chunks.append(chunk)
            }
        }
        return chunks
    }

    public static func formatAuthorization(_ credential: PaymentCredential) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(credential)
        return "\(paymentScheme) \(Base64URL.encode(data))"
    }

    private static func paymentSchemePayload(_ header: String) throws -> String {
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix(paymentScheme.lowercased()) else {
            throw MppError.invalidPaymentScheme
        }
        let index = trimmed.index(trimmed.startIndex, offsetBy: paymentScheme.count)
        return String(trimmed[index...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseAuthParams(_ value: String) throws -> [String: String] {
        var params: [String: String] = [:]
        var index = value.startIndex

        while index < value.endIndex {
            while index < value.endIndex, value[index].isWhitespace || value[index] == "," {
                index = value.index(after: index)
            }
            if index == value.endIndex {
                break
            }

            let keyStart = index
            while index < value.endIndex, value[index] != "=" {
                index = value.index(after: index)
            }
            guard index < value.endIndex else {
                throw MppError.invalidHeader
            }
            let key = value[keyStart..<index].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else {
                throw MppError.invalidHeader
            }
            index = value.index(after: index)

            while index < value.endIndex, value[index].isWhitespace {
                index = value.index(after: index)
            }
            guard index < value.endIndex, value[index] == "\"" else {
                throw MppError.invalidHeader
            }
            index = value.index(after: index)

            var decoded = ""
            var escaped = false
            var closed = false
            while index < value.endIndex {
                let char = value[index]
                index = value.index(after: index)
                if escaped {
                    decoded.append(char)
                    escaped = false
                } else if char == "\\" {
                    escaped = true
                } else if char == "\"" {
                    closed = true
                    break
                } else {
                    decoded.append(char)
                }
            }
            guard closed, !escaped else {
                throw MppError.invalidHeader
            }
            params[key] = decoded
        }

        return params
    }
}
