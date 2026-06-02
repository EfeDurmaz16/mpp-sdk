<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://github.com/solana-foundation/pay-kit/raw/main/docs/assets/banner-swift-dark.png">
    <source media="(prefers-color-scheme: light)" srcset="https://github.com/solana-foundation/pay-kit/raw/main/docs/assets/banner-swift-light.png">
    <img alt="Solana pay-kit — Swift" width="100%" style="border-top-left-radius: 8px; border-top-right-radius: 8px; margin-bottom: 16px;" src="https://github.com/solana-foundation/pay-kit/raw/main/docs/assets/banner-swift-light.png">
  </picture>
</div>

# SolanaPayKit

Pay stablecoins (USDC, USDT, PYUSD, ...) for any HTTP endpoint, in Swift.

One package, one surface (`SolanaPayKit`), two protocols underneath:
[x402](https://x402.org) and the
[Machine Payments Protocol](https://paymentauth.org). You do not need to
know anything about Solana to use it: pick a currency, give it your
wallet key, and pay a protected route.

This package is **client-only**. It parses a `402 Payment Required`
challenge, builds and signs the Solana transaction on device, and replays
the request with the payment header attached. Server support lives in the
TypeScript, Rust, Go, PHP, Ruby, Lua, and Python packages.

[![Swift](https://img.shields.io/badge/Swift-6.0%2B-blue)]()
[![Platforms](https://img.shields.io/badge/platforms-iOS%2016%20%7C%20macOS%2013-lightgrey)]()

## Quick start

Drive an MPP-gated endpoint with the URLSession-backed `MppHTTPClient`,
using sensible defaults (the hosted Surfpool RPC):

```swift
import SolanaPayKit

let signer = try MemorySigner(secretKey: secretKeyData) // 32-byte seed or 64-byte keypair
let client = MppHTTPClient(
    signer: signer,
    rpc: RpcClient(endpoint: URL(string: "https://402.surfnet.dev")!)
)

let response = try await client.fetch(url: URL(string: "https://api.example.com/paid")!)
print(response.status)              // 200 after the charge retry
print(response.settlementSignature) // base58 on-chain signature
```

`MppHTTPClient` sends the request, on a 402 it parses the
`WWW-Authenticate: Payment ...` challenge, builds the credential through
the signer, and replays the request once with the
`Authorization: Payment ...` header. Any non-402 status is returned
verbatim; transport errors propagate.

`currency` accepts a symbol like `"USDC"`, `"USDT"`, `"USDG"`, `"PYUSD"`,
or `"CASH"` (the SDK resolves the mint, token program, and decimals from
a built-in table), or a raw base58 mint pubkey.

## Run the example

The SwiftUI [`iOSDemo`](Examples/iOSDemo) walks the full charge flow
against a local merchant server. Start Surfpool and the bundled merchant,
then run the app in Xcode; see the
[example README](Examples/iOSDemo/README.md) for the steps. Headless CLI
examples live in [`ChargeClient`](Examples/ChargeClient) (MPP) and
[`X402Client`](Examples/X402Client) (x402).

End to end through the interop harness against any registered server:

```bash
cd harness
MPP_INTEROP_CLIENTS=swift MPP_INTEROP_SERVERS=typescript pnpm exec vitest run
```

## x402

x402 challenges advertise an `accepts` array; this client builds and
signs the `exact`-scheme `Payment-Signature` header.

| Intent | Status |
|---|:---:|
| `exact` | client |
| `upto` | — |
| `batch-settlement` | — |

## MPP

The Machine Payments Protocol charge intent over the `402 Payment
Required` flow.

| Intent | Status |
|---|:---:|
| `charge/pull` | client |
| `charge/push` | — |
| `session` | — |
| `subscription` | — |

Honest about gaps: only the MPP `charge/pull` path and the x402 `exact`
client ship today. The other intents are not implemented in Swift yet.
Crypto is hand-rolled (Base58, Ed25519, the transaction codec, PDA
derivation, the on-curve check, the JSON-RPC client) on top of Foundation
and Apple CryptoKit, with no `solana-swift` umbrella dependency; parity
with the Rust spine is locked by golden vectors in `Tests/`.

## Vocabulary

| Term | Meaning |
|---|---|
| gate | a route that requires payment before it returns `200` |
| amount | the price the route asks for, in the chosen currency |
| total | amount plus any fees the payer owes |
| price / fee | what the resource costs and what the protocol adds |
| payment | the signed transaction + header the client sends |
| protocol | x402 or MPP — the top-level dispatch |
| scheme | a protocol sub-form: x402 `exact`, MPP `charge` |
| currency | the stablecoin symbol or mint (USDC, USDT, PYUSD, ...) |
| settlement | the on-chain confirmation of the payment transaction |

## Harness

The interop adapters drive this client against the cross-language
servers. They live under
[`harness/swift-client`](../harness/swift-client) (MPP) and
[`harness/swift-x402-client`](../harness/swift-x402-client) (x402), never
inside the shipped library.

```bash
cd harness
MPP_INTEROP_CLIENTS=swift MPP_INTEROP_SERVERS=rust pnpm exec vitest run
X402_INTEROP_CLIENTS=swift-x402 X402_INTEROP_SERVERS=rust-x402 \
  MPP_INTEROP_INTENTS=x402-exact MPP_INTEROP_SCENARIOS=x402-exact-basic \
  pnpm exec vitest run test/e2e.test.ts \
  --testNamePattern "swift-x402 client pays rust-x402 server"
```

## Spec

This SDK implements the
[Solana Charge Intent draft](https://paymentauth.org/draft-solana-charge-00.html)
for the
[HTTP Payment Authentication Scheme](https://paymentauth.org), and the
[x402](https://x402.org) `exact` scheme.

## Repo layout

Three tiers, enforced as separate SwiftPM targets so the module
boundaries are checked by the compiler:

```text
swift/
├── Sources/
│   ├── PayCore/          # protocol-agnostic Solana + crypto primitives
│   │                     #   Base58, Base64URL, Ed25519, transaction codec,
│   │                     #   ATA, RPC client, signer, mints, network, error
│   ├── Mpp/              # MPP protocol (depends on PayCore only)
│   │                     #   charge client, HTTP retry, wire headers/models
│   ├── X402/             # x402 protocol (depends on PayCore only)
│   │                     #   exact payment builder, transport, wire types
│   └── SolanaPayKit/     # umbrella: re-exports all three (the public surface)
├── Tests/                # PayCoreTests / MppTests / X402Tests
└── Examples/             # iOSDemo (SwiftUI) + headless ChargeClient / X402Client
```

`Mpp` and `X402` each depend only on `PayCore` and never on each other;
anything both need lives in `PayCore`.

## Tests and coverage

```bash
cd swift
just test          # swift test with the 90% coverage gate
swift test         # plain run
```

## License

MIT
