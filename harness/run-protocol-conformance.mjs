// Run every canonical case applicable to one manifest-backed language.
// The existing Vitest protocol suite only samples spawned-runner success cases.
import { mkdir, writeFile } from "node:fs/promises";
import { dirname } from "node:path";
import { runCase } from "./src/protocol/driver.ts";
import {
  discoverProtocolRunners,
  spawnedProtocolAdapter,
} from "./src/protocol/runners/spawn.ts";
import {
  caseRunsOnAdapter,
  collectProtocolCases,
} from "./src/protocol/vectors.ts";

const [language, reportPath, ...extra] = process.argv.slice(2);
if (!language || extra.length > 0) {
  throw new Error(
    "usage: node --import tsx run-protocol-conformance.mjs <language> [report.json]",
  );
}

const runners = discoverProtocolRunners().filter(
  (runner) => runner.language === language,
);
if (runners.length !== 1) {
  throw new Error(`expected one protocol runner for ${language}, found ${runners.length}`);
}

const cases = collectProtocolCases();
const applicable = cases.filter((testCase) => caseRunsOnAdapter(testCase, language));
if (applicable.length === 0) {
  throw new Error(`no canonical protocol cases apply to ${language}`);
}

const adapter = spawnedProtocolAdapter(runners[0]);
const results = [];
for (const testCase of cases) {
  const label = `${testCase.op} :: ${testCase.scenario}`;
  if (!caseRunsOnAdapter(testCase, language)) {
    results.push({
      op: testCase.op,
      scenario: testCase.scenario,
      status: "skipped",
      reason: "canonical adapter allowlist",
    });
    console.log(`SKIP ${language} ${label} (canonical adapter allowlist)`);
    continue;
  }
  let result;
  try {
    result = await runCase(adapter, testCase);
  } catch (error) {
    result = {
      op: testCase.op,
      scenario: testCase.scenario,
      ok: false,
      detail: error instanceof Error ? error.message : String(error),
    };
  }
  results.push({ ...result, status: result.ok ? "passed" : "failed" });
  console.log(`${result.ok ? "PASS" : "FAIL"} ${language} ${label}${result.detail ? `: ${result.detail}` : ""}`);
}

const summary = {
  language,
  total: cases.length,
  passed: results.filter((result) => result.status === "passed").length,
  failed: results.filter((result) => result.status === "failed").length,
  skipped: results.filter((result) => result.status === "skipped").length,
  results,
};
if (reportPath) {
  await mkdir(dirname(reportPath), { recursive: true });
  await writeFile(reportPath, `${JSON.stringify(summary, null, 2)}\n`);
}
console.log(JSON.stringify({ ...summary, results: undefined }));
process.exitCode = summary.failed > 0 ? 1 : 0;
