# Session interop matrix: on-chain gate

The cross-language session interop scenarios in `harness/src/intents/session.ts`
(`session-push-lifecycle`, `session-commit-idempotent`) carry empty
`clientIds`/`serverIds` ON PURPOSE. They are NOT a passing matrix yet, and that
is not a false green: every real session scenario settles a payment channel
on-chain (open funds a deposit, close settles + distributes) through the
payment-channels program `GuoKrzaBiZnW5DvJ3yZVE7xHqbcBvaX9SH6P6Cn9gNvc`.

That program is not in this repo (only its codama-generated client bindings live
under `rust/crates/core/payment-channels`), it is not deployed on the mainnet
that Surfnet forks (a `getAccountInfo` against the id returns null), and the
harness has no program-deploy step. So the on-chain lifecycle cannot execute
locally or in the current CI.

## What IS validated today (off-chain, green)
- Per-language SDK unit tests for the full session surface, at each language's
  coverage gate.
- Golden-vector byte/wire parity in `harness/test/session.e2e.test.ts`: the
  48-byte voucher signing layout, canonical JSON, salt-as-decimal-string,
  `cumulativeAmount`/`cumulative` alias, `topUp` tag, deliveryId
  committed/replayed idempotency. Every language asserts against these same
  vectors, so cross-language voucher + wire parity holds transitively.

## To activate the on-chain matrix (when the program lands)
1. Obtain the payment-channels program `.so` and deploy it to Surfnet
   (`surfpool-sdk` exposes `deployProgram`) at the fixed program id, and add the
   same deploy step to the CI surfpool job.
2. Populate `clientIds`/`serverIds` on the two session scenarios with the
   language pairs whose adapters implement the session lifecycle
   (go + python are client+server; ruby/php/lua server; kotlin/swift client).
3. Drop this gate note once the matrix runs green in CI.
