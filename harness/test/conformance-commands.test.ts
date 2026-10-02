import { spawnSync } from "node:child_process";
import { afterEach, describe, expect, it, vi } from "vitest";
import { discoverRunners } from "../src/conformance/runners";

afterEach(() => vi.unstubAllEnvs());

describe("prebuilt conformance commands", () => {
  it("keeps native manifests when the map or a language key is absent", () => {
    vi.stubEnv("PAY_KIT_CONFORMANCE_COMMANDS", undefined);
    const native = discoverRunners();
    expect(native.find(({ language }) => language === "swift")?.command).toEqual([
      "swift",
      "run",
      "-c",
      "release",
      "mpp-conformance",
    ]);
    expect(discoverRunners("{}")).toEqual(native);
  });

  it.each([
    "not-json",
    "null",
    "[]",
    JSON.stringify({ "swift-typo": ["/bin/runner"] }),
    JSON.stringify({ swift: [] }),
    JSON.stringify({ swift: ["relative/runner"] }),
    JSON.stringify({ swift: ["/bin/runner", 42] }),
    JSON.stringify({ swift: ["/bin/runner", "bad\0argument"] }),
  ])("rejects an invalid map before returning executable commands: %s", (map) => {
    expect(() => discoverRunners(map)).toThrow(/PAY_KIT_CONFORMANCE_COMMANDS/);
  });

  it("executes a discovered override with literal argv and unchanged cwd/intents", () => {
    vi.stubEnv("PAY_KIT_CONFORMANCE_COMMANDS", undefined);
    const native = discoverRunners();
    const literal = "spaces ' quotes ; $(must-not-run)";
    vi.stubEnv(
      "PAY_KIT_CONFORMANCE_COMMANDS",
      JSON.stringify({
        swift: [
          process.execPath,
          "-e",
          "process.stdout.write(JSON.stringify({argument:process.argv[1],cwd:process.cwd()}))",
          literal,
        ],
      }),
    );
    const overridden = discoverRunners();
    const runner = overridden.find(({ language }) => language === "swift")!;
    const nativeSwift = native.find(({ language }) => language === "swift")!;
    expect(runner.cwd).toBe(nativeSwift.cwd);
    expect(runner.intents).toEqual(["charge", "x402-exact", "session"]);
    expect(overridden.filter(({ language }) => language !== "swift")).toEqual(
      native.filter(({ language }) => language !== "swift"),
    );

    const [bin, ...args] = runner.command;
    const result = spawnSync(bin, args, { cwd: runner.cwd, encoding: "utf8" });
    expect(result.error).toBeUndefined();
    expect(result.status).toBe(0);
    expect(JSON.parse(result.stdout)).toEqual({
      argument: literal,
      cwd: nativeSwift.cwd,
    });
  });
});
