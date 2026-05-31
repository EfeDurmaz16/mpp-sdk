--[[
MPP session intent wire types.

Mirrors the Rust spine at `rust/crates/mpp/src/protocol/intents/session.rs`.
The session intent opens a payment channel so a client can pay incrementally
with off-chain signed cumulative vouchers, settled on-chain only at
open / top-up / close.

LOAD-BEARING WIRE PARITY (must match Rust + the TypeScript package):

  - `cumulativeAmount` is the wire field name; `cumulative` is accepted as a
    read alias on decode. Serialization always emits `cumulativeAmount`.
  - `salt` serializes as a decimal STRING (JSON numbers > 2^53 are unsafe in
    JS intermediaries) but decode tolerates both string and number.
  - The `topup` action tag is `topUp` (capital U) on the wire.
  - `DEFAULT_SESSION_EXPIRES_AT == 4102444800` (2100-01-01 UTC), chosen to
    stay below Number.MAX_SAFE_INTEGER.
  - Voucher SIGNING bytes are Borsh, not JSON: the JSON carries channelId
    (base58), cumulativeAmount (string), expiresAt (i64); the signed bytes
    are channelId(32) || cumulative(u64 LE) || expiresAt(i64 LE). See
    `pay_kit.solana.payment_channels.voucher_message_bytes`.

This module is pure data shaping (encode/decode helpers + constructors). The
server lifecycle lives in `pay_kit.protocols.mpp.server.session_handler`.
]]

local payment_channels = require('pay_kit.solana.payment_channels')

local M = {}

-- 2100-01-01T00:00:00Z. Below Number.MAX_SAFE_INTEGER on purpose.
M.DEFAULT_SESSION_EXPIRES_AT = 4102444800

-- ── Session modes ──

M.MODE_PUSH = 'push'
M.MODE_PULL = 'pull'

M.PULL_STRATEGY_CLIENT_VOUCHER = 'clientVoucher'
M.PULL_STRATEGY_OPERATED_VOUCHER = 'operatedVoucher'

-- ── Commit status ──

M.COMMIT_STATUS_COMMITTED = 'committed'
M.COMMIT_STATUS_REPLAYED = 'replayed'

-- Strip nil-valued fields so encoders that walk pairs() do not emit them.
-- The Rust spine uses `skip_serializing_if = Option::is_none`; this is the
-- Lua equivalent. (We build tables with only present keys, so this is mostly
-- a guard for callers that pass explicit nils.)
local function prune(tbl)
  for k, v in pairs(tbl) do
    if v == nil then
      tbl[k] = nil
    end
  end
  return tbl
end

--- Build a SessionRequest table (the payload embedded in a 402 challenge).
-- Required: cap (string), currency, operator, recipient.
-- Optional: decimals, network, splits, program_id, description, external_id,
-- min_voucher_delta, modes, pull_voucher_strategy, recent_blockhash.
-- Empty splits/modes and nil optionals are omitted, matching the Rust
-- `skip_serializing_if` behavior.
function M.session_request(opts)
  opts = opts or {}
  local req = { cap = tostring(opts.cap), currency = opts.currency }
  req.operator = opts.operator
  req.recipient = opts.recipient
  if opts.decimals ~= nil then req.decimals = opts.decimals end
  if opts.network ~= nil then req.network = opts.network end
  if opts.splits and #opts.splits > 0 then req.splits = opts.splits end
  if opts.program_id ~= nil then req.programId = opts.program_id end
  if opts.description ~= nil then req.description = opts.description end
  if opts.external_id ~= nil then req.externalId = opts.external_id end
  if opts.min_voucher_delta ~= nil then req.minVoucherDelta = tostring(opts.min_voucher_delta) end
  if opts.modes and #opts.modes > 0 then req.modes = opts.modes end
  if opts.pull_voucher_strategy ~= nil then req.pullVoucherStrategy = opts.pull_voucher_strategy end
  if opts.recent_blockhash ~= nil then req.recentBlockhash = opts.recent_blockhash end
  return req
end

-- ── OpenPayload ──

--- Construct a push (payment-channel) open payload from a signed-tx signature.
function M.open_push(channel_id, deposit, authorized_signer, signature)
  return {
    action = 'open',
    mode = M.MODE_PUSH,
    channelId = channel_id,
    deposit = tostring(deposit),
    authorizedSigner = authorized_signer,
    signature = signature,
  }
end

--- Construct a full payment-channel push open payload (carries payer/payee/
--- mint/salt/gracePeriod). `mode` defaults to push.
function M.open_payment_channel(opts)
  local p = {
    action = 'open',
    mode = opts.mode or M.MODE_PUSH,
    channelId = opts.channel_id,
    deposit = tostring(opts.deposit),
    payer = opts.payer,
    payee = opts.payee,
    mint = opts.mint,
    salt = M.encode_salt(opts.salt),
    gracePeriod = opts.grace_period,
    authorizedSigner = opts.authorized_signer,
    signature = opts.signature,
  }
  if opts.transaction ~= nil then p.transaction = opts.transaction end
  return prune(p)
end

--- Construct a pull (operated-voucher SPL delegation) open payload.
function M.open_pull(token_account, approved_amount, owner, authorized_signer, signature)
  return {
    action = 'open',
    mode = M.MODE_PULL,
    tokenAccount = token_account,
    approvedAmount = tostring(approved_amount),
    owner = owner,
    authorizedSigner = authorized_signer,
    signature = signature,
  }
end

--- `salt` always serializes as a decimal string. Accepts number or string.
function M.encode_salt(salt)
  if salt == nil then return nil end
  return tostring(salt)
end

--- Tolerant salt decode: accepts string or number, returns a decimal string
--- (preserving u64 precision past 2^53 when the input is already a string).
function M.decode_salt(salt)
  if salt == nil then return nil end
  if type(salt) == 'number' then
    return string.format('%.0f', salt)
  end
  return tostring(salt)
end

--- The session id used as the channel-store key.
--- Push: channelId. Pull-no-channel: tokenAccount.
function M.session_id(payload)
  if payload.channelId and payload.channelId ~= '' then
    return payload.channelId
  end
  if payload.mode == M.MODE_PULL and payload.tokenAccount and payload.tokenAccount ~= '' then
    return payload.tokenAccount
  end
  error('open payload missing channelId or tokenAccount')
end

--- Deposit / approved amount for an open, as a decimal string.
function M.deposit_amount(payload)
  local raw = payload.deposit
  if raw == nil and payload.mode == M.MODE_PULL then
    raw = payload.approvedAmount
  end
  if raw == nil or tostring(raw) == '' then
    error('open payload missing deposit or approvedAmount')
  end
  raw = tostring(raw)
  if not raw:match('^%d+$') then
    error('invalid deposit amount: ' .. raw)
  end
  return raw
end

-- ── Vouchers ──

--- Read the cumulative amount from a voucher's data, accepting either the
--- `cumulativeAmount` wire name or the `cumulative` read alias.
function M.voucher_cumulative(data)
  local raw = data.cumulativeAmount
  if raw == nil then raw = data.cumulative end
  if raw == nil then
    error('voucher data missing cumulativeAmount')
  end
  return tostring(raw)
end

--- Serialize a VoucherData table to the canonical wire shape. Always emits
--- `cumulativeAmount` (never the `cumulative` alias).
function M.voucher_data(channel_id, cumulative_amount, expires_at, nonce)
  local data = {
    channelId = channel_id,
    cumulativeAmount = tostring(cumulative_amount),
    expiresAt = expires_at,
  }
  if nonce ~= nil then data.nonce = nonce end
  return data
end

--- The 48-byte Ed25519 signing message for a voucher data table.
function M.voucher_message_bytes(data)
  return payment_channels.voucher_message_bytes(
    data.channelId,
    M.voucher_cumulative(data),
    data.expiresAt
  )
end

-- ── Action payload constructors (client-side; useful for tests/harness) ──

function M.voucher_action(signed_voucher)
  return { action = 'voucher', voucher = signed_voucher }
end

function M.commit_action(delivery_id, signed_voucher)
  return { action = 'commit', deliveryId = delivery_id, voucher = signed_voucher }
end

function M.topup_action(channel_id, new_deposit, signature)
  return {
    action = 'topUp',
    channelId = channel_id,
    newDeposit = tostring(new_deposit),
    signature = signature,
  }
end

function M.close_action(channel_id, signed_voucher)
  local a = { action = 'close', channelId = channel_id }
  if signed_voucher ~= nil then a.voucher = signed_voucher end
  return a
end

return M
