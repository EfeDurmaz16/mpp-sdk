# Conformance vectors

Deterministic, RPC-free cross-SDK parity layer. Each vector is a single
declarative case that every SDK's conformance runner must agree on. The
driver (`harness/test/conformance.test.ts`) spawns one runner process per
SDK per vector over stdin/stdout and asserts the runner output against the
vector's `expect` block.

This layer exists to catch the parity divergences the surfpool matrix
structurally cannot: it only ever exercises canonical, all-fields-present,
happy-path offers, so field-omission defaults, top-level-vs-extra
precedence, compute caps, fee-payer guards, transferChecked decimals, and
canonical-byte encodings slip through green. The vectors encode those
divergence classes directly.

It does NOT replace on-chain settlement tests. Pure build/verify misses
RPC mint-owner resolution, real Token-2022 extension behavior, rent/ATA
effects, fee-payer lamport drain, simulation/broadcast failures, and
confirmation. Those stay in the surfpool matrix.

## Oracle

- `build-transaction` / `verify-transaction`: the oracle is the DECODED
  SEMANTIC SHAPE, not raw transaction bytes. Signatures and account
  ordering can legitimately differ across SDKs while still conforming.
- `canonical-bytes`: the oracle IS exact bytes, because byte-for-byte
  agreement (canonical JSON / JCS, base64url, fixed-width byte encodings)
  is the whole point.

## Schema

Types live in `harness/src/conformance/schema.ts`. A vector:

```jsonc
{
  "id": "charge-spl-field-omitted-defaults",
  "intent": "charge",                 // "charge" | "x402-exact"
  "mode": "build-transaction",        // build-transaction | verify-transaction | canonical-bytes
  "description": "...",
  "input": {
    "request": {                      // decoded charge offer
      "amount": "1000",
      "currency": "<mint or 'sol'>",
      "recipient": "<pubkey>",
      // top-level precedence twins (win over methodDetails copies):
      "asset": "<mint>",
      "payTo": "<pubkey>",
      "computeUnitLimit": 200000,     // build-time overrides for cap rejects
      "computeUnitPrice": "1",
      "methodDetails": {
        "network": "localnet",
        "decimals": 6,                // omit to test the default (6)
        "tokenProgram": "...",        // omit to test default-by-currency
        "recentBlockhash": "11111111111111111111111111111111",
        "feePayer": false,
        "feePayerKey": "<pubkey>",
        "splits": [{ "recipient": "...", "amount": "250", "ataCreationRequired": true, "memo": "..." }]
      }
    },
    "transaction": "<base64 wire tx>", // verify-transaction: verify this instead of building
    "signerSecretKey": [/* 64-byte ed25519 */],
    "rpcFixtures": {
      "recentBlockhash": "...",
      "mintOwners": { "<mint>": "<token program>" }
    },
    "value": { /* canonical-bytes: JSON value to canonicalize */ },
    "encodeBase64Url": { "hexBytes": "00010203...", "utf8": "..." }
  },
  "expect": {
    "outcome": "accept",              // "accept" | "reject"
    "transactionShape": {             // accept build/verify
      "feePayer": "<pubkey>",
      "transfers": [
        { "kind": "spl", "destinationOwner": "<owner>", "mint": "...", "amount": "750", "decimals": 6, "tokenProgram": "..." },
        { "kind": "sol", "destination": "<pubkey>", "amount": "1000000" }
      ],
      "forbiddenPrograms": ["..."],
      "maxComputeUnitLimit": 200000,
      "maxComputeUnitPrice": "5000000",
      "memo": ["..."]
    },
    "exactBytes": { "canonicalJson": "...", "base64Url": "...", "bytes": [/* ints */] },
    "rejectReason": "..."             // reject: documentation only, not asserted
  }
}
```

Notes:

- Offline determinism: build/verify vectors must supply
  `methodDetails.recentBlockhash` (and either `methodDetails.tokenProgram`
  or `rpcFixtures.mintOwners`, or rely on default-by-currency) so the
  build path never reaches a live RPC.
- SPL transfers land in the recipient's ATA. Express the expected
  transfer with `destinationOwner`; the driver derives the ATA. SOL
  transfers use `destination` directly.
- `maxComputeUnitLimit` / `maxComputeUnitPrice` are upper bounds, asserted
  with `<=`.

## Runner contract

One CLI per SDK, identical stdin/stdout contract:

- stdin: one vector as JSON.
- stdout: one `RunnerResult` line as JSON (`{ id, outcome, transactionShape?, exactBytes?, error? }`).
- A runner that cannot build/verify a vector emits `outcome: "reject"`
  with the SDK's error message in `error`.

The TS reference runner is `harness/src/conformance/ts-runner.ts`. It
drives the real `@solana/mpp` client build (`buildChargeTransaction`),
server verify (`verifyChargeTransaction`), and the JCS reference encoder.

## Seeded vectors (this change)

13 vectors across the divergence classes from the audit:

- `charge-defaults.json` — field-omitted defaults (decimals=6, token
  program by currency), Token-2022-by-currency, SOL-native build.
- `charge-precedence.json` — top-level-vs-extra precedence (asset over
  currency, payTo over recipient).
- `charge-rejects.json` — compute-unit-price over 5_000_000 reject,
  fee-payer-as-authority reject, transferChecked decimals mismatch reject,
  splits-consume-amount reject.
- `charge-envelope.json` — full charge envelope accept (primary + split +
  idempotent ATA creation + memo).
- `canonical-bytes.json` — RFC 8785 JCS canonical JSON + base64url,
  48-byte base64url, UTF-8 base64url.

## Per-SDK runner follow-up

The TypeScript reference runner and the Lua server-only runner ship in
this layer. Each remaining SDK gets its own conformance runner CLI
honoring the same stdin/stdout contract, registered in the `RUNNERS`
table in `harness/test/conformance.test.ts`. Tracked follow-up, one per
SDK:

- Rust (`solana-mpp` / `solana-x402` conformance bin)
- Go (`go/...` conformance command)
- PHP (`php/...`)
- Ruby (`ruby/...`)
- Lua (`lua/cmd/conformance/main.lua`) — landed; server-only role
- Python (`python/...`)
- Swift (`swift/...`)
- Kotlin (`kotlin/...`)

Once a runner lands, the driver asserts it against every vector with no
vector changes: add the command to `RUNNERS` and the matrix expands
automatically.

### Role-restricted runners and `unsupported-mode`

Not every SDK plays every role. A server-only SDK (e.g. Lua) ships the
pre-broadcast verifier and the canonical encoders but no client-side
transaction builder, so it cannot run `build-transaction` vectors, nor
`verify-transaction` vectors that expect the runner to BUILD the
transaction first. For those a runner emits

```json
{ "id": "...", "outcome": "unsupported-mode", "error": "..." }
```

and the driver SKIPs (does not fail) that vector for that runner. This is
distinct from `reject`, which is a genuine, asserted policy decision. The
Lua runner therefore conforms to the 3 `canonical-bytes` vectors plus any
`verify-transaction` vector that ships a concrete `input.transaction`,
and skips the build-dependent rest.
