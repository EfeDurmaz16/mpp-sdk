// Conformance-vector schema for the deterministic cross-SDK parity layer.
//
// A vector is a single declarative case that every SDK's conformance
// runner must agree on. The oracle is the DECODED SEMANTIC SHAPE of a
// built/verified transaction (fee payer, transfer set, forbidden
// programs, compute caps, memo) -- NOT raw transaction bytes, because
// signatures and account ordering can legitimately differ across SDKs
// while still conforming. The one exception is the `canonical-bytes`
// mode, which DOES pin exact bytes for header / JCS / base64url vectors
// where byte-for-byte agreement is the whole point.
//
// See harness/vectors/README.md for authoring guidance.

export type VectorMode = "build-transaction" | "verify-transaction" | "canonical-bytes";

export type VectorOutcome = "accept" | "reject";

export type VectorSplit = {
  recipient: string;
  amount: string;
  ataCreationRequired?: boolean;
  memo?: string;
};

// The decoded charge offer/request a build/verify vector operates on.
// Field omission is intentional and meaningful: a missing `decimals`
// must default to 6, a missing `tokenProgram` must default by currency,
// etc. Runners MUST NOT inject defaults the SDK would not.
export type VectorChargeRequest = {
  amount: string;
  currency: string;
  externalId?: string;
  recipient?: string;
  // Top-level precedence twins. When present these win over the
  // methodDetails copies; a vector can set conflicting values to pin
  // which one the SDK honors.
  payTo?: string;
  asset?: string;
  methodDetails?: {
    network?: string;
    decimals?: number;
    tokenProgram?: string;
    recentBlockhash?: string;
    feePayer?: boolean;
    feePayerKey?: string;
    splits?: VectorSplit[];
  };
  // Build-time compute budget overrides. Used by reject vectors that
  // exercise the server-side compute-unit-price / limit caps: the runner
  // builds a transaction carrying these values, then the verify path must
  // reject it.
  computeUnitLimit?: number;
  computeUnitPrice?: string;
};

export type VectorRpcFixtures = {
  // Pinned blockhash so the build path needs no live RPC.
  recentBlockhash?: string;
  // mint pubkey -> owning token program. Lets the build/verify path
  // resolve a token program without an RPC getAccountInfo call when the
  // vector omits methodDetails.tokenProgram.
  mintOwners?: Record<string, string>;
};

export type TransactionShape = {
  feePayer?: string;
  transfers?: Array<{
    kind: "spl" | "sol";
    destination?: string;
    destinationOwner?: string;
    mint?: string;
    amount: string;
    decimals?: number;
    tokenProgram?: string;
  }>;
  // Programs that MUST NOT appear in the transaction.
  forbiddenPrograms?: string[];
  maxComputeUnitLimit?: number;
  maxComputeUnitPrice?: string;
  memo?: string[];
};

export type VectorExpect = {
  outcome: VectorOutcome;
  // For build/verify accept vectors: the decoded semantic shape to assert.
  transactionShape?: TransactionShape;
  // For canonical-bytes vectors: the exact bytes the SDK must produce.
  exactBytes?: {
    canonicalJson?: string;
    base64Url?: string;
    // Raw byte array (e.g. a 48-byte vector) the runner emits as numbers.
    bytes?: number[];
  };
  // Optional human-readable reason for reject vectors; not asserted, just
  // documents the divergence class.
  rejectReason?: string;
};

export type VectorInput = {
  // build-transaction / verify-transaction
  request?: VectorChargeRequest;
  // verify-transaction: the base64 wire transaction to verify. When
  // omitted, the runner builds one from `request` first (so a single
  // vector can assert "build then verify accepts the build output").
  transaction?: string;
  // Ed25519 secret key (64-byte array) for the transfer authority / signer.
  signerSecretKey?: number[];
  rpcFixtures?: VectorRpcFixtures;
  // canonical-bytes: the JSON value to canonicalize, OR the raw input for
  // a base64url / fixed-width byte vector.
  value?: unknown;
  // canonical-bytes: a base58 or hex string the runner base64url-encodes.
  encodeBase64Url?: { hexBytes?: string; utf8?: string };
};

export type ConformanceVector = {
  id: string;
  intent: "charge" | "x402-exact";
  mode: VectorMode;
  description?: string;
  input: VectorInput;
  expect: VectorExpect;
};

// A runner may report that it does not support a vector's mode (e.g. a
// server-only SDK has no client transaction builder, so it cannot satisfy a
// build-transaction vector). The driver SKIPS such vectors for that SDK
// rather than failing them.
export type RunnerOutcome = VectorOutcome | "unsupported-mode";

// The result a runner emits to stdout for one vector.
export type RunnerResult = {
  id: string;
  outcome: RunnerOutcome;
  // Present on build/verify accept. The decoded semantic shape.
  transactionShape?: TransactionShape;
  // Present on canonical-bytes.
  exactBytes?: {
    canonicalJson?: string;
    base64Url?: string;
    bytes?: number[];
  };
  // Present on reject: the runner's reject message (for diagnostics).
  error?: string;
};
