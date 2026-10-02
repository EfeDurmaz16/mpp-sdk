import { afterEach, describe, expect, it, vi } from "vitest";
import { resolveAdapterCommand } from "../src/adapter-command";
import type { ImplementationDefinition } from "../src/implementations";
import { runClient, startServer } from "../src/process";

const goClient: ImplementationDefinition = {
  id: "go-x402",
  label: "Go x402 client",
  role: "client",
  command: ["native-command-must-not-run"],
  enabled: true,
  reportsAs: "go",
};

afterEach(() => vi.unstubAllEnvs());

describe("prebuilt adapter commands", () => {
  it("keeps native commands when no override is configured or its key is absent", () => {
    vi.stubEnv("PAY_KIT_HARNESS_COMMANDS", undefined);
    expect(resolveAdapterCommand(goClient)).toBe(goClient.command);
    expect(
      resolveAdapterCommand(
        goClient,
        JSON.stringify({ "server:rust": ["/nix/store/example/bin/server"] }),
      ),
    ).toBe(goClient.command);
  });

  it.each([
    "",
    "not-json",
    "null",
    "[]",
    JSON.stringify({ "client:go-typo": ["/nix/store/example/bin/client"] }),
    JSON.stringify({ "client:go-x402": [] }),
    JSON.stringify({ "client:go-x402": ["relative/client"] }),
    JSON.stringify({ "client:go-x402": ["/bin/client", 42] }),
    JSON.stringify({ "client:go-x402": ["/bin/client", "bad\0argument"] }),
  ])(
    "rejects an invalid command map before starting an adapter: %s",
    (encoded) => {
      expect(() => resolveAdapterCommand(goClient, encoded)).toThrow(
        /PAY_KIT_HARNESS_COMMANDS/,
      );
    },
  );

  it("executes the prebuilt client with literal argv and the scenario environment", async () => {
    const literal = "spaces ' quotes ; $(must-not-run)";
    vi.stubEnv(
      "PAY_KIT_HARNESS_COMMANDS",
      JSON.stringify({
        "client:go-x402": [
          process.execPath,
          "-e",
          `process.stdout.write(JSON.stringify({type:"result",implementation:"go",role:"client",ok:true,status:200,responseHeaders:{},responseBody:{argument:process.argv[1],target:process.env.X402_HARNESS_TARGET_URL,fixture:process.env.FIXTURE_VALUE}})+"\\n")`,
          literal,
        ],
      }),
    );

    const result = await runClient(goClient, "http://127.0.0.1:1234/payment", {
      FIXTURE_VALUE: "scenario-value",
      // Scenario variables do not get to choose which program is started.
      PAY_KIT_HARNESS_COMMANDS: "invalid scenario command override",
    });
    expect(result.responseBody).toEqual({
      argument: literal,
      target: "http://127.0.0.1:1234/payment",
      fixture: "scenario-value",
    });
  });

  it("still rejects a prebuilt server that reports the wrong implementation", async () => {
    vi.stubEnv(
      "PAY_KIT_HARNESS_COMMANDS",
      JSON.stringify({
        "server:rust": [
          process.execPath,
          "-e",
          `process.stdout.write(JSON.stringify({type:"ready",implementation:"typescript",role:"server",port:1})+"\\n")`,
        ],
      }),
    );
    await expect(
      startServer({
        id: "rust",
        label: "Rust server",
        role: "server",
        command: ["native-command-must-not-run"],
        enabled: true,
      }),
    ).rejects.toThrow(/Adapter identity mismatch: rust/);
  });
});
