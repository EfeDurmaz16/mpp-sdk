# Session fixtures

These fixtures capture the smallest shared Solana `session` intent surface that
is already visible in the TypeScript and Rust SDKs.

They intentionally do not define full settlement behavior. The first purpose is
to keep future Python, Go, Ruby, Lua, and interop work aligned on the same wire
shape before any additional runtime logic is ported.

Current source-of-truth references:

- `typescript/packages/mpp/src/client/Session.ts`
- `rust/src/protocol/intents/session.rs`
- `solana-foundation/pay#364`
- `tempoxyz/mpp-specs#201`

The expected lifecycle is:

1. Server advertises a `session` challenge.
2. Client sends an `open` action.
3. Client sends cumulative `voucher` or `commit` actions.
4. Client or server closes/finalizes the session.

The `open` action must not be treated as the first voucher. Vouchers are
cumulative and must increase monotonically for the same session.
