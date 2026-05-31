--[[
Typed helpers for the on-chain payment-channels program.

Hand-written adapter code that mirrors the Rust spine at
`rust/crates/mpp/src/program/payment_channels.rs`: channel PDA derivation,
associated-token derivation, distribution hashing (BLAKE3), the 48-byte
voucher signing layout, and the Ed25519 precompile instruction data.

LOAD-BEARING PARITY (must match the Rust spine + on-chain program byte for
byte, otherwise vouchers will not verify and PDAs will not match):

  - Channel PDA seeds, in order:
      "channel" || payer(32) || payee(32) || mint(32)
        || authorizedSigner(32) || salt(u64 LE, 8)
  - Voucher signing bytes (48):
      channelId(32) || cumulativeAmount(u64 LE, 8) || expiresAt(i64 LE, 8)
  - Distribution hash preimage (BLAKE3):
      len(u32 LE, 4) || (recipient(32) || bps(u16 LE, 2))*
  - Ed25519 precompile instruction data offsets match the program's
    `build_ed25519_verify_instruction`.
]]

local base58 = require('pay_kit.solana.base58')
local ata = require('pay_kit.solana.ata')
local blake3 = require('pay_kit.solana.blake3')
local instructions = require('pay_kit.solana.instructions')

local M = {}

-- Canonical payment-channels program ID deployed to Surfnet.
M.PAYMENT_CHANNELS_PROGRAM_ID = 'GuoKrzaBiZnW5DvJ3yZVE7xHqbcBvaX9SH6P6Cn9gNvc'
M.CHANNEL_SEED = 'channel'
M.EVENT_AUTHORITY_SEED = 'event_authority'
M.ED25519_PROGRAM_ID = 'Ed25519SigVerify111111111111111111111111111'
M.INSTRUCTIONS_SYSVAR_ID = 'Sysvar1nstructions1111111111111111111111111'
M.RENT_SYSVAR_ID = 'SysvarRent111111111111111111111111111111111'

-- Treasury owner used by the current payment-channels program deployment
-- (0xBEEF repeated, 32 bytes), base58-encoded for callers that need it.
local TREASURY_OWNER_BYTES = string.rep('\xBE\xEF', 16)
M.TREASURY_OWNER = base58.encode(TREASURY_OWNER_BYTES)

function M.default_program_id()
  return M.PAYMENT_CHANNELS_PROGRAM_ID
end

-- Encode a non-negative Lua-number / decimal-string integer as a fixed-width
-- little-endian byte string. Decimal strings are accepted so u64 values above
-- 2^53 stay exact (the channel salt and cumulative amount are u64).
local function encode_uint_le(value, width)
  -- Normalize to a base-256 little-endian byte array via repeated divmod on a
  -- decimal-digit array. This keeps full precision for values past 2^53.
  local digits = {}
  local s = tostring(value)
  if not s:match('^%d+$') then
    error('encode_uint_le requires a non-negative integer, got ' .. s)
  end
  for i = 1, #s do
    digits[i] = tonumber(s:sub(i, i))
  end
  local bytes = {}
  -- Repeatedly divide the decimal big-integer by 256, collecting remainders.
  local function is_zero()
    for i = 1, #digits do
      if digits[i] ~= 0 then return false end
    end
    return true
  end
  while not is_zero() do
    local remainder = 0
    for i = 1, #digits do
      local cur = remainder * 10 + digits[i]
      digits[i] = math.floor(cur / 256)
      remainder = cur % 256
    end
    bytes[#bytes + 1] = string.char(remainder)
  end
  if #bytes > width then
    error('value ' .. s .. ' does not fit in ' .. width .. ' bytes')
  end
  while #bytes < width do
    bytes[#bytes + 1] = '\0'
  end
  return table.concat(bytes)
end

M.encode_uint_le = encode_uint_le

-- Encode a possibly-negative i64 as 8 little-endian bytes (two's complement).
-- The session voucher's `expiresAt` is an i64; the default expiry sits well
-- below 2^53 so a numeric round-trip is exact here.
local function encode_i64_le(value)
  local n = math.floor(tonumber(value) or 0)
  if n >= 0 then
    return encode_uint_le(string.format('%.0f', n), 8)
  end
  -- Two's complement: 2^64 + n.
  -- Represent 2^64 as a decimal string and subtract the magnitude.
  local magnitude = string.format('%.0f', -n)
  -- 2^64 = 18446744073709551616
  local two_pow_64 = '18446744073709551616'
  -- Decimal subtraction two_pow_64 - magnitude.
  local function dec_sub(a, b)
    local ad, bd = {}, {}
    for i = #a, 1, -1 do ad[#ad + 1] = tonumber(a:sub(i, i)) end
    for i = #b, 1, -1 do bd[#bd + 1] = tonumber(b:sub(i, i)) end
    local out = {}
    local borrow = 0
    for i = 1, #ad do
      local d = ad[i] - (bd[i] or 0) - borrow
      if d < 0 then d = d + 10; borrow = 1 else borrow = 0 end
      out[i] = d
    end
    while #out > 1 and out[#out] == 0 do out[#out] = nil end
    local chars = {}
    for i = #out, 1, -1 do chars[#chars + 1] = tostring(out[i]) end
    return table.concat(chars)
  end
  return encode_uint_le(dec_sub(two_pow_64, magnitude), 8)
end

M.encode_i64_le = encode_i64_le

--- Derive the channel PDA for the given open params.
-- Seeds, in order: "channel" || payer || payee || mint || authorizedSigner
-- || salt(u64 LE). Returns (address_b58, bump).
function M.find_channel_pda(params)
  local payer = base58.decode(params.payer)
  local payee = base58.decode(params.payee)
  local mint = base58.decode(params.mint)
  local signer = base58.decode(params.authorized_signer)
  if #payer ~= 32 or #payee ~= 32 or #mint ~= 32 or #signer ~= 32 then
    error('find_channel_pda requires base58 inputs that decode to 32 bytes')
  end
  local salt_bytes = encode_uint_le(params.salt, 8)
  local program_id = params.program_id or M.default_program_id()
  return ata.find_program_address(
    { M.CHANNEL_SEED, payer, payee, mint, signer, salt_bytes },
    program_id
  )
end

--- Derive the event-authority PDA. Returns (address_b58, bump).
function M.find_event_authority_pda(program_id)
  program_id = program_id or M.default_program_id()
  return ata.find_program_address({ M.EVENT_AUTHORITY_SEED }, program_id)
end

--- Derive an associated token account address.
function M.find_associated_token_address(owner, mint, token_program)
  return ata.derive(owner, mint, token_program or instructions.TOKEN_PROGRAM)
end

--- Derive the full set of channel addresses for an open.
function M.derive_channel_addresses(params)
  local channel = M.find_channel_pda(params)
  local token_program = params.token_program or instructions.TOKEN_PROGRAM
  return {
    channel = channel,
    payer_token_account = M.find_associated_token_address(params.payer, params.mint, token_program),
    channel_token_account = M.find_associated_token_address(channel, params.mint, token_program),
    event_authority = (M.find_event_authority_pda(params.program_id)),
  }
end

--- BLAKE3 distribution hash over the recipient preimage.
-- @param recipients array of { recipient = <base58>, bps = <number> }
-- @return raw 32-byte digest string
function M.distribution_hash(recipients)
  recipients = recipients or {}
  local parts = { encode_uint_le(#recipients, 4) }
  for _, entry in ipairs(recipients) do
    local recipient = base58.decode(entry.recipient)
    if #recipient ~= 32 then
      error('distribution recipient must decode to 32 bytes')
    end
    parts[#parts + 1] = recipient
    parts[#parts + 1] = encode_uint_le(entry.bps, 2)
  end
  return blake3.hash(table.concat(parts))
end

--- The 48-byte voucher signing message:
--- channelId(32) || cumulativeAmount(u64 LE) || expiresAt(i64 LE).
-- @param channel_id base58 channel/session id (decodes to 32 bytes)
-- @param cumulative_amount decimal string or number (u64)
-- @param expires_at i64 unix timestamp
-- @return raw 48-byte message string
function M.voucher_message_bytes(channel_id, cumulative_amount, expires_at)
  local channel = base58.decode(channel_id)
  if #channel ~= 32 then
    error('voucher channelId must decode to 32 bytes')
  end
  local cumulative = encode_uint_le(cumulative_amount, 8)
  local expiry = encode_i64_le(expires_at)
  return channel .. cumulative .. expiry
end

--- Build the Ed25519 precompile verify instruction data for a voucher.
-- Mirrors `build_ed25519_verify_instruction` in the Rust spine: a single
-- signature descriptor with `instruction_index = u16::MAX` (self) and the
-- 16-byte header offsets followed by pubkey(32) || signature(64) || message.
-- @return raw instruction-data byte string (program is ED25519_PROGRAM_ID)
function M.build_ed25519_verify_instruction_data(authorized_signer, signature_bytes, message)
  local pubkey = base58.decode(authorized_signer)
  if #pubkey ~= 32 then
    error('authorizedSigner must decode to 32 bytes')
  end
  if #signature_bytes ~= 64 then
    error('signature must be 64 bytes')
  end
  local public_key_offset = 16
  local signature_offset = public_key_offset + 32
  local message_data_offset = signature_offset + 64
  local message_data_size = #message
  local current_instruction = 0xFFFF -- u16::MAX

  local function u16le(v)
    return string.char(v % 256, math.floor(v / 256) % 256)
  end

  local parts = {
    string.char(1), -- number of signatures
    string.char(0), -- padding
    u16le(signature_offset),
    u16le(current_instruction),
    u16le(public_key_offset),
    u16le(current_instruction),
    u16le(message_data_offset),
    u16le(message_data_size),
    u16le(current_instruction),
    pubkey,
    signature_bytes,
    message,
  }
  return table.concat(parts)
end

return M
