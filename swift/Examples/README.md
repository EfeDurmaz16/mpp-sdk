# Examples

Sample clients exercising the `SolanaPayKit` package. Each drives one
402-gated endpoint through the umbrella `SolanaPayKit` surface.

- [`iOSDemo/`](iOSDemo) — SwiftUI app: pick a currency, tap pay, and the
  app walks the full `mpp/charge/pull` flow against a local merchant
  server. The example to start from; see its
  [README](iOSDemo/README.md) for how to run it.
- [`ChargeClient/`](ChargeClient) — headless CLI that performs an
  `mpp/charge/pull` against a 402-protected endpoint.
- [`X402Client/`](X402Client) — headless CLI for the `x402/exact` scheme:
  probes a gated resource, builds the `Payment-Signature` header through a
  signer, and replays once.

`ChargeClient` and `X402Client` are source-only so the default
`swift build` stays library-only. Add an executable target to a local
`Package.swift` to run them, or use the interop adapter under
[`harness/swift-client`](../../harness/swift-client) (MPP) and
[`harness/swift-x402-client`](../../harness/swift-x402-client) (x402).
