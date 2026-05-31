import http from "node:http";
import { verifySignature, getBase58Encoder, signatureBytes } from "@solana/kit";
import { voucherMessageBytes } from "@solana/mpp/client";

// TypeScript reference session SERVER fixture (foundation).
//
// Mirrors rust/crates/mpp/src/server/session.rs: a stateful channel store
// that tracks the per-session high-water mark, the authorized signer, and
// the committed deliveries. Unlike the charge replay store this is a
// richer atomic read-modify-write store keyed by sessionId (the channel
// PDA for push sessions).
//
// This fixture is NOT yet registered in the interop matrix
// (src/implementations.ts) and its scenario rows carry empty
// clientIds/serverIds. It exists so the wire shapes + the ready/result
// protocol are pinned for the first language adapter to pair against, and
// so the local e2e skeleton (test/session.e2e.test.ts) has a real server
// to drive.

type SignedVoucher = {
  data: {
    channelId: string;
    cumulativeAmount: string;
    expiresAt: number;
    nonce?: number;
  };
  signature: string;
};

type CommitStatus = "committed" | "replayed";

type ChannelState = {
  sessionId: string;
  authorizedSigner: string;
  cumulative: bigint;
  deposit: bigint;
  // deliveryId -> cached receipt for idempotent commit replay.
  deliveries: Map<string, { amount: bigint; cumulative: bigint }>;
};

/**
 * Atomic read-modify-write channel store. Session lifecycle state lives
 * here (NOT the stateless charge replay store). A real implementation
 * would back this with a mutex/transaction per sessionId; the single
 * Node event loop gives us serialized access for the reference fixture.
 */
class ChannelStore {
  readonly #channels = new Map<string, ChannelState>();

  open(state: ChannelState): void {
    this.#channels.set(state.sessionId, state);
  }

  get(sessionId: string): ChannelState | undefined {
    return this.#channels.get(sessionId);
  }
}

async function verifyVoucher(
  voucher: SignedVoucher,
  authorizedSigner: string,
): Promise<boolean> {
  const message = voucherMessageBytes(voucher.data);
  const sig = signatureBytes(getBase58Encoder().encode(voucher.signature));
  const publicKeyBytes = new Uint8Array(
    getBase58Encoder().encode(authorizedSigner),
  );
  const key = await crypto.subtle.importKey(
    "raw",
    publicKeyBytes,
    "Ed25519",
    false,
    ["verify"],
  );
  return verifySignature(key, sig, message);
}

function readBody(request: http.IncomingMessage): Promise<string> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    request.on("data", (chunk: Buffer) => chunks.push(chunk));
    request.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    request.on("error", reject);
  });
}

function main(): void {
  const minVoucherDelta = BigInt(process.env.MPP_INTEROP_MIN_VOUCHER_DELTA ?? "1");
  const store = new ChannelStore();

  const server = http.createServer(async (request, response) => {
    try {
      const body = await readBody(request);
      const action = body ? (JSON.parse(body) as { action?: string }) : {};

      if (action.action === "open") {
        const open = action as unknown as {
          channelId: string;
          authorizedSigner: string;
          deposit: string;
        };
        store.open({
          sessionId: open.channelId,
          authorizedSigner: open.authorizedSigner,
          cumulative: 0n,
          deposit: BigInt(open.deposit ?? "0"),
          deliveries: new Map(),
        });
        response.writeHead(200, { "content-type": "application/json" });
        response.end(JSON.stringify({ status: "opened", sessionId: open.channelId }));
        return;
      }

      if (action.action === "voucher" || action.action === "commit") {
        const payload = action as unknown as {
          deliveryId?: string;
          voucher: SignedVoucher;
        };
        const voucher = payload.voucher;
        const state = store.get(voucher.data.channelId);
        if (!state) {
          response.writeHead(402, { "content-type": "application/json" });
          response.end(JSON.stringify({ code: "unknown_session" }));
          return;
        }

        // Idempotent commit: a duplicate deliveryId returns the cached
        // receipt with status "replayed", never a second settlement.
        if (payload.deliveryId) {
          const cached = state.deliveries.get(payload.deliveryId);
          if (cached) {
            response.writeHead(200, { "content-type": "application/json" });
            response.end(
              JSON.stringify({
                deliveryId: payload.deliveryId,
                amount: cached.amount.toString(),
                cumulative: cached.cumulative.toString(),
                status: "replayed" satisfies CommitStatus,
              }),
            );
            return;
          }
        }

        const ok = await verifyVoucher(voucher, state.authorizedSigner);
        const cumulative = BigInt(voucher.data.cumulativeAmount);
        const delta = cumulative - state.cumulative;
        if (
          !ok ||
          cumulative <= state.cumulative ||
          delta < minVoucherDelta ||
          cumulative > state.deposit
        ) {
          response.writeHead(402, { "content-type": "application/json" });
          response.end(JSON.stringify({ code: "voucher_rejected" }));
          return;
        }

        state.cumulative = cumulative;
        if (payload.deliveryId) {
          state.deliveries.set(payload.deliveryId, { amount: delta, cumulative });
        }
        response.writeHead(200, { "content-type": "application/json" });
        response.end(
          JSON.stringify({
            deliveryId: payload.deliveryId ?? null,
            amount: delta.toString(),
            cumulative: cumulative.toString(),
            status: "committed" satisfies CommitStatus,
          }),
        );
        return;
      }

      if (action.action === "topUp") {
        const topUp = action as unknown as {
          channelId: string;
          newDeposit: string;
        };
        const state = store.get(topUp.channelId);
        if (!state) {
          response.writeHead(402, { "content-type": "application/json" });
          response.end(JSON.stringify({ code: "unknown_session" }));
          return;
        }
        state.deposit = BigInt(topUp.newDeposit);
        response.writeHead(200, { "content-type": "application/json" });
        response.end(JSON.stringify({ status: "topped_up", deposit: state.deposit.toString() }));
        return;
      }

      if (action.action === "close") {
        const close = action as unknown as { channelId: string };
        const state = store.get(close.channelId);
        response.writeHead(200, { "content-type": "application/json" });
        response.end(
          JSON.stringify({
            status: "closed",
            cumulative: (state?.cumulative ?? 0n).toString(),
          }),
        );
        return;
      }

      response.writeHead(404, { "content-type": "application/json" });
      response.end(JSON.stringify({ error: "unknown_action" }));
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      response.writeHead(500, { "content-type": "application/json" });
      response.end(JSON.stringify({ error: message }));
    }
  });

  server.listen(0, "127.0.0.1", () => {
    const address = server.address();
    if (!address || typeof address === "string") {
      throw new Error("Failed to bind TypeScript interop session server");
    }
    console.log(
      JSON.stringify({
        type: "ready",
        implementation: "typescript",
        role: "server",
        port: address.port,
        capabilities: ["session"],
      }),
    );
  });

  const shutdown = () => {
    server.close(() => process.exit(0));
  };
  process.on("SIGTERM", shutdown);
  process.on("SIGINT", shutdown);
}

main();
