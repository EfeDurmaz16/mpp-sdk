import type { InteropScenario } from "../contracts";
import type { CanonicalJsonVector } from "./charge";

// Canonical `mpp/session` interop scenarios + golden vectors.
//
// The session intent opens a payment channel and pays incrementally with
// off-chain signed vouchers, settled on-chain only at open / top-up /
// close. The harness contract (env vars, ready/result JSON shapes) mirrors
// the charge intent; the lifecycle-specific wire shapes mirror the Rust
// spine:
//   - rust/crates/mpp/src/protocol/intents/session.rs (SessionAction tags,
//     VoucherData, salt/cumulativeAmount serde adapters)
//   - rust/crates/mpp/src/program/payment_channels.rs (voucher_message_bytes
//     48-byte layout, find_channel_pda seed order)
//   - rust/crates/mpp/src/server/session.rs (deliveryId commit idempotency,
//     high-water-mark ChannelStore)
//
// This is the harness FOUNDATION: the scenario rows below describe the
// open -> voucher -> commit -> close lifecycle the cross-language matrix
// will drive once each language ships a session client/server fixture.
// The matrix runner (test/session.e2e.test.ts) is gated behind
// MPP_SESSION_INTEROP_MATRIX=1 and a live Surfpool RPC, so the default
// `pnpm test` run only exercises the golden vectors below.

// ── Golden vectors ──────────────────────────────────────────────────────

/**
 * Canonical-JSON (RFC 8785) vectors for the session wire shapes. These pin
 * the exact bytes each language SDK must produce when canonicalizing a
 * `VoucherData`, `SessionAction`, and `MeteringDirective` before signing or
 * HMAC. Key ordering is UTF-16 code-unit order; numbers follow ES6 ToString.
 *
 * Load-bearing parity points exercised here:
 *   - `cumulativeAmount` is the wire field name (NOT `cumulative`); the
 *     read-alias only applies on deserialize.
 *   - `expiresAt` is a JSON number (i64), not a string.
 *   - the `topUp` action tag is camelCase with a capital U.
 *   - `salt` serializes as a decimal STRING even though it is a u64.
 */
export const sessionCanonicalJsonVectors: readonly CanonicalJsonVector[] = [
  {
    // VoucherData: channelId (base58), cumulativeAmount (decimal string),
    // expiresAt (i64 number). Keys sort to channelId < cumulativeAmount <
    // expiresAt under UTF-16 code-unit order.
    id: "voucher-data-canonical",
    value: {
      channelId: "4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU",
      cumulativeAmount: "513",
      expiresAt: 42,
    },
    canonicalJson:
      '{"channelId":"4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU","cumulativeAmount":"513","expiresAt":42}',
    base64Url:
      "eyJjaGFubmVsSWQiOiI0ek1NQzlzcnQ1Umk1WDE0R0FnWGhhSGlpM0duUEFFRVJZUEpnWkpEbmNEVSIsImN1bXVsYXRpdmVBbW91bnQiOiI1MTMiLCJleHBpcmVzQXQiOjQyfQ",
  },
  {
    // topUp action tag must serialize with a capital U (camelCase of the
    // Rust `TopUp` variant). `newDeposit` is a base-units decimal string.
    id: "session-action-topup-tag",
    value: {
      action: "topUp",
      channelId: "4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU",
      newDeposit: "20000000",
      signature: "sig",
    },
    canonicalJson:
      '{"action":"topUp","channelId":"4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU","newDeposit":"20000000","signature":"sig"}',
    base64Url:
      "eyJhY3Rpb24iOiJ0b3BVcCIsImNoYW5uZWxJZCI6IjR6TU1DOXNydDVSaTVYMTRHQWdYaGFIaWkzR25QQUVFUllQSmdaSkRuY0RVIiwibmV3RGVwb3NpdCI6IjIwMDAwMDAwIiwic2lnbmF0dXJlIjoic2lnIn0",
  },
  {
    // SessionRequest with a default expiry. DEFAULT_SESSION_EXPIRES_AT is
    // 4_102_444_800 (2100-01-01 UTC), deliberately below
    // Number.MAX_SAFE_INTEGER so it round-trips as a JSON number.
    id: "session-request-default-expiry",
    value: {
      cap: "10000000",
      currency: "USDC",
      expiresAt: 4102444800,
      operator: "4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU",
      recipient: "4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU",
    },
    canonicalJson:
      '{"cap":"10000000","currency":"USDC","expiresAt":4102444800,"operator":"4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU","recipient":"4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU"}',
    base64Url:
      "eyJjYXAiOiIxMDAwMDAwMCIsImN1cnJlbmN5IjoiVVNEQyIsImV4cGlyZXNBdCI6NDEwMjQ0NDgwMCwib3BlcmF0b3IiOiI0ek1NQzlzcnQ1Umk1WDE0R0FnWGhhSGlpM0duUEFFRVJZUEpnWkpEbmNEVSIsInJlY2lwaWVudCI6IjR6TU1DOXNydDVSaTVYMTRHQWdYaGFIaWkzR25QQUVFUllQSmdaSkRuY0RVIn0",
  },
];

/**
 * The signed voucher byte layout. Vouchers are signed with Ed25519 over the
 * on-chain `VoucherArgs` Borsh layout, NOT over JSON:
 *
 *   channel_id (32 bytes, raw pubkey)
 *   || cumulative_amount (u64, little-endian, 8 bytes)
 *   || expires_at (i64, little-endian, 8 bytes)
 *   = 48 bytes total
 *
 * Reference: rust/crates/mpp/src/program/payment_channels.rs
 * `voucher_message_bytes` + its `voucher_message_is_program_borsh_layout`
 * test (asserts len 48, channel_id at [0..32], cumulative LE at [32..40],
 * expires_at LE at [40..48]). Get this wrong and signatures will not verify
 * against the on-chain program. The hex below was produced by the shipped
 * TypeScript `voucherMessageBytes` against `channelId` decoded from base58.
 */
export type VoucherBytesVector = {
  id: string;
  channelId: string;
  cumulativeAmount: string;
  expiresAt: number;
  // 48-byte little-endian voucher message, lowercase hex.
  hex: string;
};

export const sessionVoucherBytesVectors: readonly VoucherBytesVector[] = [
  {
    id: "voucher-bytes-513-at-42",
    channelId: "4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU",
    cumulativeAmount: "513",
    expiresAt: 42,
    hex: "3b442cb3912157f13a933d0134282d032b5ffecd01a2dbf1b7790608df002ea701020000000000002a00000000000000",
  },
  {
    id: "voucher-bytes-default-expiry",
    channelId: "4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU",
    cumulativeAmount: "1000000",
    expiresAt: 4102444800,
    hex: "3b442cb3912157f13a933d0134282d032b5ffecd01a2dbf1b7790608df002ea740420f0000000000005786f400000000",
  },
  {
    id: "voucher-bytes-zero-cumulative",
    channelId: "4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU",
    cumulativeAmount: "0",
    expiresAt: 1,
    hex: "3b442cb3912157f13a933d0134282d032b5ffecd01a2dbf1b7790608df002ea700000000000000000100000000000000",
  },
];

/**
 * `salt` is a u64 serialized as a decimal STRING on the wire (JSON numbers
 * above 2^53 are unsafe in JS intermediaries) but the deserializer accepts
 * BOTH a string and a number for ecosystem compatibility. Reference:
 * `serialize_optional_u64_as_string` /
 * `deserialize_optional_u64_from_string_or_number`
 * (rust/crates/mpp/src/protocol/intents/session.rs).
 *
 * `wire` is what every SDK MUST emit; `accepts` are the equivalent values a
 * conforming deserializer must read back to the same u64.
 */
export type SaltVector = {
  id: string;
  // The u64 value as a decimal string.
  value: string;
  // Canonical serialized form (always a string).
  wire: string;
  // Inputs a conforming deserializer must accept and normalize to `value`.
  accepts: ReadonlyArray<string | number>;
};

export const sessionSaltVectors: readonly SaltVector[] = [
  {
    id: "salt-small",
    value: "7",
    wire: "7",
    accepts: ["7", 7],
  },
  {
    // 2^53 + 1: the smallest u64 that loses precision as a JS number. The
    // string form is the only safe representation; a JS number here would
    // round to 9007199254740992. A conforming deserializer accepts the
    // string but a number input at this magnitude is already lossy, so the
    // safe-roundtrip set is the string alone.
    id: "salt-above-2pow53",
    value: "9007199254740993",
    wire: "9007199254740993",
    accepts: ["9007199254740993"],
  },
  {
    // u64::MAX. Must round-trip exactly as a string.
    id: "salt-u64-max",
    value: "18446744073709551615",
    wire: "18446744073709551615",
    accepts: ["18446744073709551615"],
  },
];

/**
 * `cumulativeAmount` is the wire field name; `cumulative` is the Rust field
 * name and an accepted read-alias. Vouchers are CUMULATIVE (the running
 * total authorized), never a per-request delta, and MUST be strictly
 * increasing. The server stores the high-water mark and computes each
 * delta itself.
 */
export type CumulativeVector = {
  id: string;
  // Wire field name a conforming serializer emits.
  wireField: "cumulativeAmount";
  // Field names a conforming deserializer accepts.
  acceptsFields: ReadonlyArray<"cumulativeAmount" | "cumulative">;
  // A strictly-increasing sequence the client emits over the session.
  sequence: readonly string[];
  // A non-increasing pair the server MUST reject (replay / regression).
  rejectsNonIncreasing: readonly [string, string];
};

export const sessionCumulativeVectors: readonly CumulativeVector[] = [
  {
    id: "cumulative-monotonic",
    wireField: "cumulativeAmount",
    acceptsFields: ["cumulativeAmount", "cumulative"],
    sequence: ["25", "75", "150", "1000"],
    rejectsNonIncreasing: ["150", "150"],
  },
];

/**
 * `MeteringDirective.deliveryId` is the idempotency key for a metered
 * commit. A duplicate `commit` for the same `deliveryId` returns
 * `CommitStatus::Replayed` with the cached receipt, NOT a new settlement.
 * First delivery returns `committed`. Reference:
 * rust/crates/mpp/src/server/session.rs (commit handler) +
 * `CommitStatus` (committed | replayed).
 */
export type DeliveryIdVector = {
  id: string;
  deliveryId: string;
  // The cumulative the committing voucher carries.
  cumulativeAmount: string;
  // Status on first commit.
  firstStatus: "committed";
  // Status on a duplicate commit with the same deliveryId.
  replayStatus: "replayed";
};

export const sessionDeliveryIdVectors: readonly DeliveryIdVector[] = [
  {
    id: "delivery-commit-then-replay",
    deliveryId: "delivery-0001",
    cumulativeAmount: "75",
    firstStatus: "committed",
    replayStatus: "replayed",
  },
];

// ── Scenarios ───────────────────────────────────────────────────────────

// Session scenarios are gated entirely behind the matrix runner; no
// language ships a session interop fixture yet, so every row carries empty
// clientIds/serverIds until the first fixture lands. The lifecycle is
// open -> 3 vouchers (one committed via a metering directive) -> top-up ->
// close, mirroring the Rust integration test in the session spec.
export const sessionScenarios: readonly InteropScenario[] = [
  {
    // Push-mode lifecycle. Client opens a payment channel (deposit funded
    // on-chain), signs cumulative vouchers per metered call, commits one
    // delivery, tops up the deposit, then closes with the final voucher.
    id: "session-push-lifecycle",
    intent: "session",
    network: "localnet",
    price: "0.001",
    amount: "1000",
    asset: "4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU",
    resourcePath: "/session",
    settlementHeader: "x-fixture-settlement",
    expectedStatus: 200,
    // No session fixture ships yet. Empty id lists keep the matrix runner
    // from pairing this scenario against any adapter until a fixture lands.
    clientIds: [],
    serverIds: [],
  },
  {
    // Idempotent commit: the client re-sends a `commit` for the same
    // deliveryId. The server MUST return CommitStatus::Replayed with the
    // cached receipt, not settle twice.
    id: "session-commit-idempotent",
    intent: "session",
    kind: "idempotent-resubmit",
    network: "localnet",
    price: "0.001",
    amount: "1000",
    asset: "4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU",
    resourcePath: "/session",
    settlementHeader: "x-fixture-settlement",
    expectedStatus: 200,
    clientIds: [],
    serverIds: [],
  },
] as const;
