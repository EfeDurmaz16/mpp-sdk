# PHP Server-Side Support Notes

This note records the initial PHP research for future MPP server-side support.
It does not add a PHP package or dependency yet.

Date checked: 2026-05-19

## Scope

PHP should start as server-side only for MPP.

The first PHP work should focus on:

- generating MPP charge/session/subscription challenges
- parsing and validating authorization payloads
- decoding/verifying Solana payment evidence where practical
- exposing framework-neutral middleware helpers later

Client-side credential construction can stay out of scope.

## SolDapper/solana-php

Repository:

- `https://github.com/SolDapper/solana-php`
- package: `solana-php/solana-sdk`
- license: MIT
- default branch: `master`
- latest observed push: 2026-04-25
- latest release: none observed through GitHub releases
- package requirements: PHP `^8.0`, `ext-sodium`, `ext-mbstring`, `ext-gmp`

The library is useful enough to keep on the shortlist for PHP server-side MPP
because it includes the primitives that a verifier or server adapter will
eventually need:

- public keys and keypairs
- Ed25519 signing primitives through Sodium
- PDA derivation
- Borsh encoding/decoding
- legacy and v0 Solana transactions
- SPL token and associated-token-account instruction builders
- Solana RPC client
- transaction confirmation helpers
- Solana Pay URL helpers and payment lookup

It also claims byte-level validation against JavaScript and Rust references for
transactions, Borsh, SPL token instructions, Solana Pay URLs, and devnet payment
flows. Those claims are promising, but should be verified locally before it
becomes a production dependency in `mpp-sdk`.

## Dependency Position

Do not add `solana-php/solana-sdk` as the first PHP PR.

The safer sequence is:

1. create a tiny PHP package skeleton with composer metadata, autoloading, and
   unit test wiring
2. model MPP challenge and authorization envelope types without Solana RPC
3. add deterministic tests for malformed auth payloads and unsupported methods
4. evaluate `solana-php/solana-sdk` behind an internal adapter interface
5. only add the dependency if it removes real transaction/signature verification
   complexity

This keeps the first PHP PR reviewable and avoids committing to an external API
before the package boundary is clear.

## Proposed Package Boundary

Candidate layout:

```text
php/
  composer.json
  src/
    Challenge.php
    Credential.php
    Intent/
      Charge.php
      Session.php
      Subscription.php
    Server/
      Verifier.php
      Middleware.php
    Solana/
      SolanaVerifier.php
      SolanaPhpAdapter.php
  tests/
```

The public API should stay framework-neutral. If framework integrations are
needed later, they should wrap the core package rather than own protocol logic.

## Open Questions

- Should PHP verify Solana transaction evidence directly in the first server
  adapter, or should it initially delegate verification through a callback like
  Lua does?
- Should PHP support only `charge` first, or should `session` and
  `subscription` schemas land at the same time as inert server-side models?
- Does the maintainer prefer PHP to depend on `solana-php/solana-sdk`, or keep
  the initial package dependency-free until a verifier needs Solana primitives?
- Should PHP enter the interop matrix as server-only once it can emit challenges,
  or only after it can verify paid credentials end-to-end?

## Recommended First PHP Slice

Start with a dependency-free PHP package skeleton plus server-side `charge`
challenge and credential parsing tests.

That slice should not perform Solana RPC verification yet. It should establish
the package shape, test command, JSON/header parsing behavior, and failure
messages. The following PR can introduce a verifier adapter and decide whether
`solana-php/solana-sdk` is the right dependency.
