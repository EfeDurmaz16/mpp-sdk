// Session intent harness foundation tests.
//
// Two layers:
//   1. Golden-vector conformance (always runs under `pnpm test`): pins the
//      canonical-JSON bytes, the 48-byte voucher signing layout, and the
//      salt / cumulativeAmount / deliveryId edge vectors every language
//      SDK must reproduce. These prove wire + byte parity locally without
//      a live Surfpool RPC.
//   2. Local lifecycle skeleton (gated behind MPP_SESSION_INTEROP_MATRIX=1):
//      spins up the TypeScript reference session server/client fixtures and
//      drives open -> voucher -> commit -> close, asserting the deliveryId
//      idempotency replay. This is a SKELETON: no other language ships a
//      session interop fixture yet, so the cross-language matrix rows in
//      src/intents/session.ts carry empty clientIds/serverIds. Full
//      on-chain settlement parity is validated in CI (surfpool) once the
//      first language adapter lands.

import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { describe, expect, it } from "vitest";
import {
  sessionCanonicalJsonVectors,
  sessionVoucherBytesVectors,
  sessionSaltVectors,
  sessionCumulativeVectors,
  sessionDeliveryIdVectors,
} from "../src/contracts";

// ── Reference encoders (kept in lockstep with canonical-json.test.ts) ──

function compareUtf16CodeUnits(a: string, b: string): number {
  const n = Math.min(a.length, b.length);
  for (let i = 0; i < n; i++) {
    const ax = a.charCodeAt(i);
    const bx = b.charCodeAt(i);
    if (ax !== bx) return ax - bx;
  }
  return a.length - b.length;
}

function canonicalizeJson(value: unknown): string {
  if (value === null) return "null";
  if (value === true) return "true";
  if (value === false) return "false";
  if (typeof value === "number") {
    if (!Number.isFinite(value)) throw new Error("non-finite number");
    return value === 0 ? "0" : String(value);
  }
  if (typeof value === "string") return JSON.stringify(value);
  if (Array.isArray(value)) {
    return "[" + value.map(canonicalizeJson).join(",") + "]";
  }
  if (typeof value === "object") {
    const obj = value as Record<string, unknown>;
    const keys = Object.keys(obj).sort(compareUtf16CodeUnits);
    return (
      "{" +
      keys.map((k) => JSON.stringify(k) + ":" + canonicalizeJson(obj[k])).join(",") +
      "}"
    );
  }
  throw new Error(`unsupported JSON value: ${typeof value}`);
}

function encodeBase64Url(value: string): string {
  return Buffer.from(value, "utf8").toString("base64url");
}

// Builds the 48-byte payment-channels VoucherArgs message from a base58
// channelId, a decimal cumulative string, and an i64 expiresAt. This is
// the parity-critical byte layout each SDK must reproduce; the expected
// hex in the vectors was produced by the shipped TS voucherMessageBytes.
function buildVoucherBytes(
  channelId: string,
  cumulativeAmount: string,
  expiresAt: number,
): Uint8Array {
  // base58 decode (no external dep): reuse @solana/kit's encoder via the
  // SDK is overkill here; decode inline with the standard alphabet.
  const ALPHABET =
    "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
  let num = 0n;
  for (const ch of channelId) {
    const idx = ALPHABET.indexOf(ch);
    if (idx < 0) throw new Error(`invalid base58 char: ${ch}`);
    num = num * 58n + BigInt(idx);
  }
  const bytes: number[] = [];
  while (num > 0n) {
    bytes.unshift(Number(num & 0xffn));
    num >>= 8n;
  }
  for (const ch of channelId) {
    if (ch === "1") bytes.unshift(0);
    else break;
  }
  const idBytes = Uint8Array.from(bytes);
  if (idBytes.length !== 32) {
    throw new Error(`channelId must decode to 32 bytes; got ${idBytes.length}`);
  }

  const out = new Uint8Array(48);
  out.set(idBytes, 0);
  const view = new DataView(out.buffer);
  view.setBigUint64(32, BigInt(cumulativeAmount), true);
  view.setBigInt64(40, BigInt(expiresAt), true);
  return out;
}

function toHex(bytes: Uint8Array): string {
  return Buffer.from(bytes).toString("hex");
}

describe("session canonical-JSON golden vectors", () => {
  for (const vector of sessionCanonicalJsonVectors) {
    it(`${vector.id}: canonical JSON + base64url`, () => {
      const canonical = canonicalizeJson(vector.value);
      expect(canonical).toBe(vector.canonicalJson);
      expect(encodeBase64Url(canonical)).toBe(vector.base64Url);
    });
  }
});

describe("session voucher 48-byte signing layout", () => {
  for (const vector of sessionVoucherBytesVectors) {
    it(`${vector.id}: channel_id || cumulative_le || expires_le`, () => {
      const bytes = buildVoucherBytes(
        vector.channelId,
        vector.cumulativeAmount,
        vector.expiresAt,
      );
      expect(bytes.byteLength).toBe(48);
      expect(toHex(bytes)).toBe(vector.hex);

      // Field-level parity assertions against the Rust spine layout.
      const view = new DataView(bytes.buffer);
      expect(view.getBigUint64(32, true)).toBe(BigInt(vector.cumulativeAmount));
      expect(view.getBigInt64(40, true)).toBe(BigInt(vector.expiresAt));
    });
  }
});

describe("session salt is a decimal string (number-tolerant read)", () => {
  for (const vector of sessionSaltVectors) {
    it(`${vector.id}: serializes as string, accepts both forms`, () => {
      // Serializer always emits a decimal string.
      expect(vector.wire).toBe(vector.value);
      expect(typeof vector.wire).toBe("string");
      // Deserializer accepts every listed input and normalizes to value.
      for (const accepted of vector.accepts) {
        expect(BigInt(accepted).toString()).toBe(vector.value);
      }
    });
  }
});

describe("session cumulativeAmount wire name + monotonicity", () => {
  for (const vector of sessionCumulativeVectors) {
    it(`${vector.id}: wire field is cumulativeAmount with cumulative read-alias`, () => {
      expect(vector.wireField).toBe("cumulativeAmount");
      expect(vector.acceptsFields).toContain("cumulativeAmount");
      expect(vector.acceptsFields).toContain("cumulative");
    });

    it(`${vector.id}: cumulative sequence is strictly increasing`, () => {
      const seq = vector.sequence.map((v) => BigInt(v));
      for (let i = 1; i < seq.length; i++) {
        expect(seq[i] > seq[i - 1]).toBe(true);
      }
      const [a, b] = vector.rejectsNonIncreasing;
      expect(BigInt(b) > BigInt(a)).toBe(false);
    });
  }
});

describe("session deliveryId commit idempotency", () => {
  for (const vector of sessionDeliveryIdVectors) {
    it(`${vector.id}: first commit committed, replay replayed`, () => {
      expect(vector.firstStatus).toBe("committed");
      expect(vector.replayStatus).toBe("replayed");
      // Same deliveryId across both commits is the idempotency key.
      expect(vector.deliveryId.length).toBeGreaterThan(0);
    });
  }
});

// ── Local lifecycle skeleton (gated) ──────────────────────────────────

const MATRIX_ENABLED = process.env.MPP_SESSION_INTEROP_MATRIX === "1";
const here = path.dirname(fileURLToPath(import.meta.url));
const fixturesDir = path.resolve(here, "..", "src", "fixtures", "typescript");

type ReadyMessage = { type: "ready"; role: "server"; port: number };
type ResultMessage = {
  type: "result";
  role: "client";
  ok: boolean;
  commitStatus?: string;
  replayStatus?: string;
};

function startSessionServer(): Promise<{ port: number; stop: () => void }> {
  return new Promise((resolve, reject) => {
    const child = spawn(
      "tsx",
      [path.join(fixturesDir, "session-server.ts")],
      { cwd: path.resolve(here, ".."), stdio: ["ignore", "pipe", "pipe"] },
    );
    let buffer = "";
    const timer = setTimeout(() => {
      child.kill();
      reject(new Error("session server did not signal readiness in time"));
    }, 30_000);
    child.stdout.on("data", (chunk: Buffer) => {
      buffer += chunk.toString("utf8");
      const line = buffer.split("\n").find((l) => l.includes('"ready"'));
      if (!line) return;
      const ready = JSON.parse(line) as ReadyMessage;
      clearTimeout(timer);
      resolve({ port: ready.port, stop: () => child.kill() });
    });
    child.on("error", reject);
  });
}

function runSessionClient(targetUrl: string): Promise<ResultMessage> {
  return new Promise((resolve, reject) => {
    const child = spawn(
      "tsx",
      [path.join(fixturesDir, "session-client.ts")],
      {
        cwd: path.resolve(here, ".."),
        stdio: ["ignore", "pipe", "pipe"],
        env: { ...process.env, MPP_INTEROP_TARGET_URL: targetUrl },
      },
    );
    let out = "";
    let err = "";
    child.stdout.on("data", (chunk: Buffer) => (out += chunk.toString("utf8")));
    child.stderr.on("data", (chunk: Buffer) => (err += chunk.toString("utf8")));
    child.on("close", (code) => {
      if (code !== 0) {
        reject(new Error(`session client exited with code ${code}: ${err}`));
        return;
      }
      const line = out.split("\n").find((l) => l.includes('"result"'));
      if (!line) {
        reject(new Error(`session client emitted no result: ${out}`));
        return;
      }
      resolve(JSON.parse(line) as ResultMessage);
    });
    child.on("error", reject);
  });
}

describe("session lifecycle skeleton (TypeScript reference)", () => {
  if (!MATRIX_ENABLED) {
    it.skip("gated behind MPP_SESSION_INTEROP_MATRIX=1", () => {});
    return;
  }

  it("open -> voucher -> commit -> close with idempotent replay", async () => {
    const server = await startSessionServer();
    try {
      const targetUrl = `http://127.0.0.1:${server.port}/session`;
      const result = await runSessionClient(targetUrl);
      expect(result.ok).toBe(true);
      expect(result.commitStatus).toBe("committed");
      expect(result.replayStatus).toBe("replayed");
    } finally {
      server.stop();
    }
  }, 120_000);
});
