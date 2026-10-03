import { defineConfig } from "vitest/config";
import base from "./vitest.config";

// Explicit allowlist: no validator, live RPC, adapter builds or listening ports.
// Synthetic process fixtures remain isolated in their own Vitest workers.
export const pureTestFiles = [
  "test/adapter-command.test.ts",
  "test/adapter-identity.test.ts",
  "test/canonical-json.test.ts",
  "test/compute-budget-caps.test.ts",
  "test/conformance-commands.test.ts",
  "test/guards.test.ts",
  "test/intent-selection.test.ts",
  "test/process.test.ts",
  "test/x402-amount-base-units.test.ts",
  "test/x402-v1-exact.test.ts",
];

export default defineConfig({
  ...base,
  test: {
    ...base.test,
    include: pureTestFiles,
    fileParallelism: true,
    maxWorkers: 2,
    isolate: true,
  },
});
