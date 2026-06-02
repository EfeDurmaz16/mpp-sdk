// SolanaPayKit umbrella: the single public surface.
//
// Three tiers underneath, enforced as separate SwiftPM targets so the
// compiler — not convention — keeps the boundaries:
//
//   - PayCore: protocol-agnostic Solana + crypto primitives (Base58,
//     Base64URL, Ed25519, transactions, ATA, RPC, signer, mints, network,
//     the shared payment error).
//   - Mpp: the Machine Payments Protocol charge client + wire types.
//   - X402: the x402 exact-scheme client + wire types.
//
// Mpp and X402 both depend on PayCore and never on each other; anything
// both need lives in PayCore. This umbrella re-exports all three so
// callers keep a single `import SolanaPayKit`.
@_exported import PayCore
@_exported import Mpp
@_exported import X402
