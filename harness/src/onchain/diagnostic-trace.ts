import { createHash } from "node:crypto";
import { getAddressDecoder } from "@solana/kit";
import type { Surfnet } from "@solana/surfpool";
import { decodeWire } from "./diagnostic-wire.js";

const loader = "BPFLoaderUpgradeab1e11111111111111111111111";
const address = "[1-9A-HJ-NP-Za-km-z]{32,44}";
const runtimeLog = new RegExp(`^Program ${address} (?:invoke \\[\\d+\\]|success|consumed \\d+ of \\d+ compute units|failed: [A-Za-z0-9 :_-]{1,120})$`);
const labels = /InvalidProgramForExecution|invalid program for execution|not executable|unsupported program id|program account not found|AccountNotFound|account not found|failed to (?:fetch|retrieve|load)|BlockhashNotFound|blockhash not found|Too Many Requests|rate limit|429|timed? ?out|connection reset|ECONNRESET|ECONNREFUSED|UND_ERR_SOCKET/gi;

interface Account {
  owner?: string;
  executable?: boolean;
  data?: [string, string];
}

function emit(event: string, detail: object) {
  console.log("[surfnet-diag] " + JSON.stringify({ at: new Date().toISOString(), event, ...detail }));
}

function metadata(pubkey: string, account: Account | null) {
  if (!account) return { pubkey, present: false };
  const bytes = Buffer.from(account.data?.[0] ?? "", "base64");
  const tag = account.owner === loader && bytes.length >= 4 ? bytes.readUInt32LE(0) : undefined;
  const code = tag === 3 && bytes.length >= 45 ? bytes.subarray(45) : undefined;
  return { pubkey, present: true, owner: account.owner, executable: account.executable, size: bytes.length, tag,
    programData: tag === 2 && bytes.length >= 36 ? getAddressDecoder().decode(bytes.subarray(4, 36)) : undefined,
    deployedSlot: code ? bytes.readBigUInt64LE(4).toString() : undefined,
    elfMagic: code?.subarray(0, 4).toString("hex"), codeSha256: code && createHash("sha256").update(code).digest("hex") };
}

// Only runtime-generated lines are retained. Arbitrary program messages, memos,
// account contents, and signed wire bytes must never reach the diagnostic logs.
function runtimeLogs(lines: unknown): string[] | null {
  return Array.isArray(lines) ? lines.filter((line) => typeof line === "string" && runtimeLog.test(line)) : null;
}

function errorFields(err: unknown): unknown {
  // Solana's transaction errors are short enum names or tagged objects/tuples.
  if (typeof err === "string") return /^[A-Za-z][A-Za-z0-9]{0,59}$/.test(err) ? err : err.match(labels) ?? "other";
  if (typeof err === "number" || err == null) return err;
  if (Array.isArray(err)) return err.slice(0, 3).map(errorFields);
  if (typeof err === "object") return Object.fromEntries(Object.entries(err)
    .filter(([key]) => /^[A-Z][a-zA-Z0-9]{0,59}$/.test(key)).map(([key, value]) => [key, errorFields(value)]));
  return "other";
}

export function traceSurfnet(surfnet: Surfnet, programs: string[]) {
  const previousFetch = globalThis.fetch;
  const origin = new URL(surfnet.rpcUrl).origin;
  const known = new Set(programs);
  let sequence = 0;

  function events(stage: string, batch: ReturnType<Surfnet["drainEvents"]>) {
    const counts: Record<string, number> = {};
    for (const item of batch) {
      counts[item.kind] = (counts[item.kind] ?? 0) + 1;
      const clues = [item.errorMessage, item.message].join(" ").match(labels);
      const logs = runtimeLogs(item.logs);
      if (item.accountPubkey || clues || item.errorMessage || /error|warn|fail/i.test(item.kind)) {
        const addresses = [item.errorMessage, item.message].join(" ").match(new RegExp(`\\b${address}\\b`, "g"));
        emit("event-detail", { stage, kind: item.kind, timestamp: item.timestamp, account: item.accountPubkey, addresses, clues, logs });
      }
    }
    if (batch.length) emit("events", { stage, counts });
  }

  async function snapshot(programIds: string[], id: number) {
    // Reads may populate Surfnet's account cache. Gather no extra RPC state until
    // the failed response and pending native events have both been recorded.
    async function rpc(method: string, params: unknown[]) {
      const response = await previousFetch(surfnet.rpcUrl, { method: "POST", signal: AbortSignal.timeout(3500),
        headers: { "content-type": "application/json" }, body: JSON.stringify({ jsonrpc: "2.0", id, method, params }) });
      return response.json();
    }
    const keys = [...new Set([...known, ...programIds])];
    const [accounts, slot] = await Promise.allSettled([
      rpc("getMultipleAccounts", [keys, { encoding: "base64", commitment: "processed" }]),
      rpc("getSlot", [{ commitment: "processed" }]),
    ]);
    const values: Array<Account | null> | undefined = accounts.status === "fulfilled" ? accounts.value.result?.value : undefined;
    const observed = values?.map((value, i) => metadata(keys[i], value));
    emit("post-error-snapshot", { id, commitment: "processed", slot: slot.status === "fulfilled" ? slot.value.result : null,
      contextSlot: accounts.status === "fulfilled" ? accounts.value.result?.context?.slot : null,
      accounts: observed ?? null, readError: accounts.status === "fulfilled" ? accounts.value.error?.code : "fetch" });
    const extra = [...new Set((observed ?? []).flatMap(item => item.programData && !keys.includes(item.programData) ? [item.programData] : []))];
    if (extra.length) {
      const result = await rpc("getMultipleAccounts", [extra, { encoding: "base64", commitment: "processed" }]);
      emit("post-error-programdata", { id, contextSlot: result.result?.context?.slot,
        accounts: result.result?.value?.map((value: Account | null, i: number) => metadata(extra[i], value)) ?? null, readError: result.error?.code });
    }
  }

  const tracedFetch: typeof fetch = async (input, init) => {
    const request = typeof input === "object" && "url" in input ? input : null;
    const target = request?.url ?? String(input);
    if (!target.startsWith(origin) || new URL(target).origin !== origin) return previousFetch(input, init);
    let call: { method?: string; params?: unknown[] } = {};
    try {
      const raw = typeof init?.body === "string" ? init.body : await request?.clone().text();
      if (raw) call = JSON.parse(raw);
    } catch { /* Ignore non-JSON traffic. */ }
    const method = call?.method;
    if (method !== "simulateTransaction" && method !== "sendTransaction") return previousFetch(input, init);
    const id = ++sequence;
    const encoded = call.params?.[0];
    const wire = typeof encoded === "string" ? decodeWire(encoded) : { version: null, programIds: [] };
    let response: Response;
    try {
      response = await previousFetch(input, init);
    } catch (error) {
      emit("transport-error", { id, method, wire, clues: String((error as Error).cause ?? error).match(labels) });
      throw error;
    }
    try {
      const json = await response.clone().json();
      const value = json.result?.value ?? json.error?.data;
      const rawLogs = value?.logs ?? value?.logMessages;
      const failed = !response.ok || Boolean(json.error || value?.err);
      const logs = runtimeLogs(rawLogs);
      emit("rpc", { id, method, wire, http: response.status, slot: json.result?.context?.slot ?? json.error?.data?.context?.slot,
        failed, rpcCode: json.error?.code, messageClues: json.error?.message?.match(labels), err: errorFields(value?.err),
        runtimeLogCount: Array.isArray(rawLogs) ? rawLogs.length : null,
        logs: failed ? logs : logs?.filter(line => line.endsWith("invoke [1]")) });
      if (failed) {
        events(`rpc-${id}-failure`, surfnet.drainEvents());
        const invoked = (logs ?? []).map(line => line.split(" ")[1]);
        await snapshot([...wire.programIds, ...invoked], id);
      }
    } catch {
      emit("diagnostic-read-error", { id, method, http: response.status });
    }
    return response;
  };
  globalThis.fetch = tracedFetch;

  return {
    events,
    ready(pubkey: string, account: Account) {
      const state = metadata(pubkey, account);
      if (state.programData) known.add(state.programData);
      emit("ready", state);
    },
    stop() {
      if (globalThis.fetch === tracedFetch) globalThis.fetch = previousFetch;
      events("stop", surfnet.drainEvents());
    },
  };
}
