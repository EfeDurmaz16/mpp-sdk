import { generateKeyPairSigner } from "@solana/kit";
import { ActiveSession } from "@solana/mpp/client";

// TypeScript reference session CLIENT fixture (foundation).
//
// Mirrors rust/crates/mpp/src/client/session.rs +
// session_consumer.rs: generate an ephemeral authorizedSigner keypair,
// open the channel, then sign cumulative vouchers per metered call. Each
// voucher carries the monotonically-increasing TOTAL (not the delta);
// the server stores the high-water mark and derives the delta. The
// signed bytes are the 48-byte payment-channels VoucherArgs layout, NOT
// the JSON (see ActiveSession.prepareIncrement -> voucherMessageBytes).
//
// Not yet registered in the interop matrix; the scenario rows carry empty
// clientIds/serverIds. The flow here is the reference for the first
// language adapter and the local e2e skeleton.

type ResultMessage = {
  type: "result";
  implementation: "typescript";
  role: "client";
  ok: boolean;
  status: number;
  cumulative: string;
  commitStatus?: string;
  replayStatus?: string;
};

async function post(url: string, payload: unknown): Promise<Response> {
  return fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(payload),
  });
}

async function main(): Promise<void> {
  const targetUrl = process.env.MPP_INTEROP_TARGET_URL;
  if (!targetUrl) {
    throw new Error("MPP_INTEROP_TARGET_URL is required");
  }

  // The session channel id is provided by the harness (the on-chain
  // channel PDA in a real run). For the foundation fixture the harness
  // funds a deposit large enough to cover the cumulative vouchers below.
  const channelId =
    process.env.MPP_INTEROP_CHANNEL_ID ??
    "4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU";
  const deposit = process.env.MPP_INTEROP_DEPOSIT ?? "10000000";

  // Ephemeral session signing key; its pubkey is the authorizedSigner.
  const signer = await generateKeyPairSigner();
  const session = new ActiveSession({ channelId, signer });

  // open
  const openResponse = await post(targetUrl, {
    action: "open",
    mode: "push",
    channelId,
    authorizedSigner: signer.address,
    deposit,
  });

  // voucher 1 (off-chain increment, recorded after server accepts)
  const v1 = await session.prepareIncrement(25);
  const v1Response = await post(targetUrl, { action: "voucher", voucher: v1 });
  if (v1Response.ok) session.recordVoucher(v1);

  // voucher 2 committed against a metering directive (deliveryId).
  const deliveryId = process.env.MPP_INTEROP_DELIVERY_ID ?? "delivery-0001";
  const v2 = await session.prepareIncrement(50);
  const commitResponse = await post(targetUrl, {
    action: "commit",
    deliveryId,
    voucher: v2,
  });
  const commitBody = (await commitResponse.json()) as { status?: string };
  if (commitResponse.ok) session.recordVoucher(v2);

  // duplicate commit with the same deliveryId must be idempotent.
  const replayResponse = await post(targetUrl, {
    action: "commit",
    deliveryId,
    voucher: v2,
  });
  const replayBody = (await replayResponse.json()) as { status?: string };

  // top-up raises the deposit cap on-chain; signature is a stub here.
  await post(targetUrl, {
    action: "topUp",
    channelId,
    newDeposit: "20000000",
    signature: "stub",
  });

  // voucher 3 after top-up.
  const v3 = await session.prepareIncrement(100);
  const v3Response = await post(targetUrl, { action: "voucher", voucher: v3 });
  if (v3Response.ok) session.recordVoucher(v3);

  // close with the final voucher.
  const closeResponse = await post(targetUrl, {
    action: "close",
    channelId,
    voucher: v3,
  });

  const ok =
    openResponse.ok &&
    v1Response.ok &&
    commitResponse.ok &&
    v3Response.ok &&
    closeResponse.ok;

  const result: ResultMessage = {
    type: "result",
    implementation: "typescript",
    role: "client",
    ok,
    status: closeResponse.status,
    cumulative: session.cumulativeAmount,
    commitStatus: commitBody.status,
    replayStatus: replayBody.status,
  };
  console.log(JSON.stringify(result));
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
