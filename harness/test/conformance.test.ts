// Cross-SDK conformance-vector driver.
//
// Loads every vector under harness/vectors/, spawns the TypeScript
// reference runner once per vector over stdin/stdout, and asserts the
// runner output against the vector's `expect` block. The oracle is the
// DECODED SEMANTIC SHAPE for build/verify vectors and EXACT BYTES for
// canonical-bytes vectors.
//
// This suite is deterministic and RPC-free: it needs no surfpool, no
// loopback socket, and no live validator. Only the TS reference runner
// ships in this change; runners for the other SDKs are a tracked
// follow-up (see harness/vectors/README.md), at which point this driver
// gains a `RUNNERS` table and asserts every runner agrees per vector.

import { spawn } from "node:child_process";
import { readdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { address } from "@solana/kit";
import { findAssociatedTokenPda } from "@solana-program/token";
import { describe, expect, it } from "vitest";
import type {
  ConformanceVector,
  RunnerResult,
  TransactionShape,
} from "../src/conformance/schema";

const here = dirname(fileURLToPath(import.meta.url));
const vectorsDir = join(here, "..", "vectors");
const tsRunner = join(here, "..", "src", "conformance", "ts-runner.ts");
const kotlinRunner = join(
  here,
  "..",
  "..",
  "kotlin",
  "build",
  "install",
  "conformance-runner",
  "bin",
  "conformance-runner",
);

function loadVectors(): ConformanceVector[] {
  const files = readdirSync(vectorsDir).filter((name) => name.endsWith(".json"));
  const vectors: ConformanceVector[] = [];
  for (const file of files) {
    const parsed = JSON.parse(
      readFileSync(join(vectorsDir, file), "utf8"),
    ) as ConformanceVector[];
    for (const vector of parsed) {
      vectors.push(vector);
    }
  }
  return vectors;
}

// One CLI per SDK over stdin/stdout. The TS reference runner is invoked
// via tsx; other languages register their own command here. The Kotlin
// runner is the `application` plugin start script produced by
// `gradle installDist`, so the suite invokes plain `java` per vector
// instead of paying gradle startup on every spawn.
const RUNNERS: Record<string, string[]> = {
  typescript: ["pnpm", "exec", "node", "--import", "tsx", tsRunner],
  kotlin: [kotlinRunner],
};

// Per-runner working directory. Defaults to the harness root. Runners that
// resolve their own files (the Kotlin start script resolves its lib/ relative
// to its own location, so the harness root is fine) can override here.
const RUNNER_CWD: Record<string, string> = {};

function runVector(
  command: string[],
  vector: ConformanceVector,
  cwd: string,
): Promise<RunnerResult> {
  const [bin, ...args] = command;
  return new Promise((resolve, reject) => {
    const child = spawn(bin, args, { cwd });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => (stdout += chunk.toString()));
    child.stderr.on("data", (chunk) => (stderr += chunk.toString()));
    child.on("error", reject);
    child.on("close", (code) => {
      if (code !== 0) {
        reject(
          new Error(
            `runner exited with code ${code} for vector ${vector.id}; stderr: ${stderr}`,
          ),
        );
        return;
      }
      const line = stdout.trim().split("\n").filter(Boolean).pop();
      if (!line) {
        reject(new Error(`runner produced no output for vector ${vector.id}`));
        return;
      }
      try {
        resolve(JSON.parse(line) as RunnerResult);
      } catch (error) {
        reject(
          new Error(
            `failed to parse runner output for ${vector.id}: ${line}\n${String(error)}`,
          ),
        );
      }
    });
    child.stdin.write(JSON.stringify(vector));
    child.stdin.end();
  });
}

async function assertShape(
  expected: TransactionShape,
  actual: TransactionShape | undefined,
): Promise<void> {
  expect(actual, "runner did not emit a transactionShape").toBeDefined();
  if (!actual) return;

  if (expected.feePayer !== undefined) {
    expect(actual.feePayer).toBe(expected.feePayer);
  }

  if (expected.maxComputeUnitLimit !== undefined) {
    expect(actual.maxComputeUnitLimit).toBeLessThanOrEqual(
      expected.maxComputeUnitLimit,
    );
  }
  if (expected.maxComputeUnitPrice !== undefined) {
    expect(BigInt(actual.maxComputeUnitPrice ?? "0")).toBeLessThanOrEqual(
      BigInt(expected.maxComputeUnitPrice),
    );
  }

  for (const forbidden of expected.forbiddenPrograms ?? []) {
    for (const transfer of actual.transfers ?? []) {
      expect(
        transfer.tokenProgram,
        `forbidden program ${forbidden} appeared in a transfer`,
      ).not.toBe(forbidden);
    }
  }

  if (expected.memo !== undefined) {
    expect(new Set(actual.memo ?? [])).toEqual(new Set(expected.memo));
  }

  if (expected.transfers !== undefined) {
    expect(actual.transfers, "transfer count mismatch").toHaveLength(
      expected.transfers.length,
    );
    for (const wanted of expected.transfers) {
      // Resolve the expected on-chain destination: SPL transfers land in
      // the recipient's ATA, so derive it from destinationOwner + mint +
      // tokenProgram. SOL transfers go straight to the destination.
      let wantedDestination = wanted.destination;
      if (
        wanted.kind === "spl" &&
        wanted.destinationOwner &&
        wanted.mint &&
        wanted.tokenProgram
      ) {
        const [ata] = await findAssociatedTokenPda({
          mint: address(wanted.mint),
          owner: address(wanted.destinationOwner),
          tokenProgram: address(wanted.tokenProgram),
        });
        wantedDestination = ata;
      }
      const match = (actual.transfers ?? []).find(
        (t) =>
          t.kind === wanted.kind &&
          t.amount === wanted.amount &&
          (wantedDestination === undefined || t.destination === wantedDestination) &&
          (wanted.mint === undefined || t.mint === wanted.mint) &&
          (wanted.decimals === undefined || t.decimals === wanted.decimals) &&
          (wanted.tokenProgram === undefined ||
            t.tokenProgram === wanted.tokenProgram),
      );
      expect(
        match,
        `no transfer matched ${JSON.stringify(wanted)} (dest ${wantedDestination}); got ${JSON.stringify(actual.transfers)}`,
      ).toBeDefined();
    }
  }
}

const vectors = loadVectors();

describe("cross-SDK conformance vectors", () => {
  it("loaded at least the seeded vector classes", () => {
    expect(vectors.length).toBeGreaterThanOrEqual(10);
    const modes = new Set(vectors.map((v) => v.mode));
    expect(modes.has("build-transaction")).toBe(true);
    expect(modes.has("verify-transaction")).toBe(true);
    expect(modes.has("canonical-bytes")).toBe(true);
  });

  for (const [language, command] of Object.entries(RUNNERS)) {
    const runnerCwd = RUNNER_CWD[language] ?? join(here, "..");
    describe(`${language} reference runner`, () => {
      for (const vector of vectors) {
        it(`${vector.id} (${vector.mode}) -> ${vector.expect.outcome}`, async (ctx) => {
          const result = await runVector(command, vector, runnerCwd);
          expect(result.id).toBe(vector.id);

          // A runner whose SDK role does not cover this vector's mode (e.g.
          // a client-only SDK asked to verify-transaction) returns the
          // `unsupported-mode` sentinel. SKIP rather than fail: the vector is
          // simply outside this language's surface, not a divergence.
          if (result.outcome === "unsupported-mode") {
            ctx.skip();
            return;
          }

          expect(
            result.outcome,
            `expected ${vector.expect.outcome} but runner said ${result.outcome}: ${result.error ?? ""}`,
          ).toBe(vector.expect.outcome);

          if (vector.expect.outcome === "reject") {
            return;
          }

          if (vector.mode === "canonical-bytes") {
            const wanted = vector.expect.exactBytes;
            expect(wanted, "canonical-bytes vector missing expect.exactBytes").toBeDefined();
            if (wanted?.canonicalJson !== undefined) {
              expect(result.exactBytes?.canonicalJson).toBe(wanted.canonicalJson);
            }
            if (wanted?.base64Url !== undefined) {
              expect(result.exactBytes?.base64Url).toBe(wanted.base64Url);
            }
            if (wanted?.bytes !== undefined) {
              expect(result.exactBytes?.bytes).toEqual(wanted.bytes);
            }
            return;
          }

          if (vector.expect.transactionShape) {
            await assertShape(vector.expect.transactionShape, result.transactionShape);
          }
        }, 60_000);
      }
    });
  }
});
