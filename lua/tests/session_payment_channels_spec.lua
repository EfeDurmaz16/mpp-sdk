-- Golden-vector coverage for pay_kit.solana.payment_channels + blake3.
--
-- Vectors pinned against the Rust spine
-- (rust/crates/mpp/src/program/payment_channels.rs::tests) and the official
-- BLAKE3 reference test vectors. Interop byte-parity is fully validated only
-- in CI (surfpool); these vectors prove parity locally.

local helpers = require('tests.test_helper')
local pc = require('pay_kit.solana.payment_channels')
local blake3 = require('pay_kit.solana.blake3')
local base58 = require('pay_kit.solana.base58')

local function hex(s)
  return (s:gsub('.', function(c) return string.format('%02x', c:byte()) end))
end

local function pk(byte)
  return base58.encode(string.rep(string.char(byte), 32))
end

-- ── BLAKE3 official test vectors ──

helpers.test('blake3: empty input matches reference', function()
  helpers.assert_equal(hex(blake3.hash('')),
    'af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262')
end)

helpers.test('blake3: "abc" matches reference', function()
  helpers.assert_equal(hex(blake3.hash('abc')),
    '6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85')
end)

helpers.test('blake3: 1024-byte multi-block chunk matches reference', function()
  local t = {}
  for i = 0, 1023 do t[#t + 1] = string.char(i % 251) end
  helpers.assert_equal(hex(blake3.hash(table.concat(t))),
    '42214739f095a406f3fc83deb889744ac00df831c10daa55189b5d121c855af7')
end)

helpers.test('blake3: 2048-byte multi-chunk tree matches reference', function()
  local t = {}
  for i = 0, 2047 do t[#t + 1] = string.char(i % 251) end
  helpers.assert_equal(hex(blake3.hash(table.concat(t))),
    'e776b6028c7cd22a4d0ba182a8bf62205d2ef576467e838ed6f2529b85fba24a')
end)

-- ── Voucher signing bytes (48-byte layout) ──

helpers.test('voucher_message_bytes: 48-byte program Borsh layout', function()
  local msg = pc.voucher_message_bytes(pk(9), 42, 1234)
  helpers.assert_equal(#msg, 48)
  helpers.assert_equal(hex(msg:sub(1, 32)), string.rep('09', 32))
  -- 42 as u64 LE.
  helpers.assert_equal(hex(msg:sub(33, 40)), '2a00000000000000')
  -- 1234 as i64 LE.
  helpers.assert_equal(hex(msg:sub(41, 48)), 'd204000000000000')
end)

helpers.test('voucher_message_bytes: differs by cumulative', function()
  local a = pc.voucher_message_bytes(pk(6), 100, 42)
  local b = pc.voucher_message_bytes(pk(6), 200, 42)
  helpers.assert_true(a ~= b, 'expected different message bytes')
end)

helpers.test('voucher_message_bytes: deterministic', function()
  local a = pc.voucher_message_bytes(pk(5), 1000, 42)
  local b = pc.voucher_message_bytes(pk(5), 1000, 42)
  helpers.assert_equal(hex(a), hex(b))
end)

helpers.test('voucher_message_bytes: u64 cumulative above 2^53 stays exact', function()
  -- 18446744073709551615 = u64::MAX -> all-FF cumulative bytes.
  local msg = pc.voucher_message_bytes(pk(1), '18446744073709551615', 0)
  helpers.assert_equal(hex(msg:sub(33, 40)), string.rep('ff', 8))
end)

helpers.test('encode_i64_le: negative one is two-complement all-FF', function()
  helpers.assert_equal(hex(pc.encode_i64_le(-1)), string.rep('ff', 8))
end)

-- ── Distribution hash (BLAKE3 preimage) ──

helpers.test('distribution_hash: matches program preimage shape', function()
  local dh = pc.distribution_hash({
    { recipient = pk(1), bps = 7500 },
    { recipient = pk(2), bps = 2500 },
  })
  -- Independently rebuild the preimage: len(u32 LE) || (pk||bps u16 LE)*.
  local preimage = string.char(2, 0, 0, 0)
    .. string.rep(string.char(1), 32) .. string.char(7500 % 256, math.floor(7500 / 256))
    .. string.rep(string.char(2), 32) .. string.char(2500 % 256, math.floor(2500 / 256))
  helpers.assert_equal(hex(dh), hex(blake3.hash(preimage)))
end)

helpers.test('distribution_hash: empty recipients hashes the u32 zero length', function()
  helpers.assert_equal(hex(pc.distribution_hash({})), hex(blake3.hash(string.char(0, 0, 0, 0))))
end)

-- ── Channel PDA seed order ──

helpers.test('find_channel_pda: stable and off-curve (32-byte address)', function()
  local params = {
    payer = pk(1), payee = pk(2), mint = pk(3), authorized_signer = pk(4),
    salt = 99, program_id = pc.default_program_id(),
  }
  local addr, bump = pc.find_channel_pda(params)
  helpers.assert_equal(#base58.decode(addr), 32)
  helpers.assert_true(bump >= 0 and bump <= 255, 'bump in range')
  -- Determinism.
  local addr2 = pc.find_channel_pda(params)
  helpers.assert_equal(addr, addr2)
end)

helpers.test('find_channel_pda: salt changes the address', function()
  local base_params = {
    payer = pk(1), payee = pk(2), mint = pk(3), authorized_signer = pk(4),
    program_id = pc.default_program_id(),
  }
  base_params.salt = 1
  local a = pc.find_channel_pda(base_params)
  base_params.salt = 2
  local b = pc.find_channel_pda(base_params)
  helpers.assert_true(a ~= b, 'different salt should derive a different PDA')
end)

-- ── Ed25519 precompile instruction data offsets ──

helpers.test('build_ed25519_verify_instruction_data: offsets match the program', function()
  local message = pc.voucher_message_bytes(pk(9), 42, 1234)
  local data = pc.build_ed25519_verify_instruction_data(pk(7), string.rep('\1', 64), message)
  -- header(16) || pubkey(32) || sig(64) || message(48) = 160.
  helpers.assert_equal(#data, 16 + 32 + 64 + #message)
  helpers.assert_equal(data:byte(1), 1) -- one signature
  helpers.assert_equal(data:byte(2), 0) -- padding
  -- signature_offset = 48 (u16 LE) at bytes 3..4.
  helpers.assert_equal(data:byte(3) + data:byte(4) * 256, 48)
  -- public_key_offset = 16 at bytes 7..8.
  helpers.assert_equal(data:byte(7) + data:byte(8) * 256, 16)
  -- message_data_offset = 112 at bytes 11..12.
  helpers.assert_equal(data:byte(11) + data:byte(12) * 256, 112)
  -- message_data_size = #message at bytes 13..14.
  helpers.assert_equal(data:byte(13) + data:byte(14) * 256, #message)
end)
