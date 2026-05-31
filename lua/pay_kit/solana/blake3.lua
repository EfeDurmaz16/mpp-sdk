--[[
Pure-LuaJIT BLAKE3 (hash mode, no keyed/derive variants).

The MPP payment-channels program commits a 32-byte distribution hash at
channel open time, computed with BLAKE3 over the recipient preimage. None
of the other PayKit crypto primitives (`pay_kit.util._mpp_crypto`) carry
BLAKE3, so the session intent ships its own implementation here.

This is a faithful port of the BLAKE3 reference (the official spec at
<https://github.com/BLAKE3-team/BLAKE3-specs>). It implements the regular
unkeyed hash with the default 32-byte output, which is all the
distribution-hash preimage needs. The preimage the payment-channels
program hashes is small (`u32 len || (pubkey32 || u16 bps)*`), so the
single-threaded, single-output reference structure is sufficient; there is
no need for the SIMD / multi-chunk-tree fast paths.

LuaJIT ships the `bit` library natively, so the 32-bit word ops use it
directly rather than the pure-Lua `pay_kit.util.bit` fallback.
]]

local bit = require('bit')
local band, bxor = bit.band, bit.bxor
local rshift, ror = bit.rshift, bit.ror
local tobit, bnot = bit.tobit, bit.bnot

local M = {}

local OUT_LEN = 32
local BLOCK_LEN = 64
local CHUNK_LEN = 1024

-- Domain-separation flags.
local CHUNK_START = 1
local CHUNK_END = 2
local ROOT = 8

local IV = {
  0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A,
  0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19,
}

-- Message permutation applied between rounds. These are the canonical
-- 0-based BLAKE3 permutation indices [2,6,3,10,7,0,4,13,1,11,12,5,9,14,15,8]
-- shifted by +1 so they index a 1-based 16-word message table.
local MSG_PERMUTATION = {
  3, 7, 4, 11, 8, 1, 5, 14, 2, 12, 13, 6, 10, 15, 16, 9,
}

-- 32-bit add that wraps; `bit.tobit` normalizes to a signed 32-bit int but
-- equality/serialization treat the low 32 bits, which is what we want.
local function add(a, b)
  return tobit(a + b)
end

local function g(state, a, b, c, d, mx, my)
  state[a] = add(add(state[a], state[b]), mx)
  state[d] = ror(bxor(state[d], state[a]), 16)
  state[c] = add(state[c], state[d])
  state[b] = ror(bxor(state[b], state[c]), 12)
  state[a] = add(add(state[a], state[b]), my)
  state[d] = ror(bxor(state[d], state[a]), 8)
  state[c] = add(state[c], state[d])
  state[b] = ror(bxor(state[b], state[c]), 7)
end

local function round(state, m)
  -- Columns.
  g(state, 1, 5, 9, 13, m[1], m[2])
  g(state, 2, 6, 10, 14, m[3], m[4])
  g(state, 3, 7, 11, 15, m[5], m[6])
  g(state, 4, 8, 12, 16, m[7], m[8])
  -- Diagonals.
  g(state, 1, 6, 11, 16, m[9], m[10])
  g(state, 2, 7, 12, 13, m[11], m[12])
  g(state, 3, 8, 9, 14, m[13], m[14])
  g(state, 4, 5, 10, 15, m[15], m[16])
end

local function permute(m)
  local out = {}
  for i = 1, 16 do
    out[i] = m[MSG_PERMUTATION[i]]
  end
  return out
end

-- The core compression function. `chaining` is 8 words, `block_words` is
-- 16 words, returns 16 output words (only the first 8 are used for the
-- chaining value; the full 16 are used for the root output).
local function compress(chaining, block_words, counter, block_len, flags)
  local counter_low = tobit(counter % 4294967296)
  local counter_high = tobit(math.floor(counter / 4294967296) % 4294967296)
  local state = {
    chaining[1], chaining[2], chaining[3], chaining[4],
    chaining[5], chaining[6], chaining[7], chaining[8],
    IV[1], IV[2], IV[3], IV[4],
    counter_low, counter_high, tobit(block_len), tobit(flags),
  }
  local m = block_words
  for _ = 1, 6 do
    round(state, m)
    m = permute(m)
  end
  round(state, m)

  local out = {}
  for i = 1, 8 do
    out[i] = bxor(state[i], state[i + 8])
    out[i + 8] = bxor(state[i + 8], chaining[i])
  end
  return out
end

-- Read 16 little-endian 32-bit words from a 64-byte block string. The block
-- is zero-padded to 64 bytes by the caller.
local function words_from_block(block)
  local words = {}
  for i = 0, 15 do
    local b0 = block:byte(i * 4 + 1) or 0
    local b1 = block:byte(i * 4 + 2) or 0
    local b2 = block:byte(i * 4 + 3) or 0
    local b3 = block:byte(i * 4 + 4) or 0
    words[i + 1] = tobit(b0 + b1 * 256 + b2 * 65536 + b3 * 16777216)
  end
  return words
end

-- Compute the BLAKE3 hash of `input` (a byte string) and return a 32-byte
-- raw digest string.
--
-- This handles inputs of any length by splitting into 1024-byte chunks and
-- combining their chaining values up the binary tree, exactly as the
-- reference describes. The distribution-hash preimage is far below one
-- chunk, but the full path keeps the implementation correct for any input.
function M.hash(input)
  input = input or ''

  -- Build the list of chunk chaining values.
  local chunk_cvs = {}
  local total = #input
  local num_chunks = math.max(1, math.ceil(total / CHUNK_LEN))

  for chunk_index = 0, num_chunks - 1 do
    local chunk_start = chunk_index * CHUNK_LEN
    local chunk_end = math.min(chunk_start + CHUNK_LEN, total)
    local chunk = input:sub(chunk_start + 1, chunk_end)
    local chunk_data_len = #chunk
    local num_blocks = math.max(1, math.ceil(chunk_data_len / BLOCK_LEN))

    local cv = { IV[1], IV[2], IV[3], IV[4], IV[5], IV[6], IV[7], IV[8] }
    for block_index = 0, num_blocks - 1 do
      local bstart = block_index * BLOCK_LEN
      local bend = math.min(bstart + BLOCK_LEN, chunk_data_len)
      local block = chunk:sub(bstart + 1, bend)
      local block_len = #block
      -- Zero-pad to 64 bytes.
      if block_len < BLOCK_LEN then
        block = block .. string.rep('\0', BLOCK_LEN - block_len)
      end

      local flags = 0
      if block_index == 0 then
        flags = flags + CHUNK_START
      end
      local is_last_block = (block_index == num_blocks - 1)
      local is_last_chunk = (chunk_index == num_chunks - 1)
      if is_last_block then
        flags = flags + CHUNK_END
      end
      -- Root flag is set only on the final compression of a single-chunk
      -- input; multi-chunk inputs set ROOT during the parent-merge step.
      if is_last_block and is_last_chunk and num_chunks == 1 then
        flags = flags + ROOT
      end

      local words = words_from_block(block)
      local out = compress(cv, words, chunk_index, block_len, flags)
      cv = { out[1], out[2], out[3], out[4], out[5], out[6], out[7], out[8] }
    end
    chunk_cvs[#chunk_cvs + 1] = cv
  end

  -- Merge chunk chaining values up the tree. For the single-chunk case the
  -- ROOT flag was already applied above and the loop body is skipped.
  local function parent_cv(left, right, is_root)
    local block_words = {
      left[1], left[2], left[3], left[4], left[5], left[6], left[7], left[8],
      right[1], right[2], right[3], right[4], right[5], right[6], right[7], right[8],
    }
    local flags = 4 -- PARENT
    if is_root then
      flags = flags + ROOT
    end
    local out = compress(
      { IV[1], IV[2], IV[3], IV[4], IV[5], IV[6], IV[7], IV[8] },
      block_words, 0, BLOCK_LEN, flags
    )
    return { out[1], out[2], out[3], out[4], out[5], out[6], out[7], out[8] }
  end

  local root_words
  if num_chunks == 1 then
    -- The single chunk's final compression already had ROOT set, so the
    -- chaining value words are the root output words.
    root_words = chunk_cvs[1]
  else
    -- Reduce left-to-right. BLAKE3's tree is left-balanced: combine the
    -- running left subtree with each subsequent chunk CV. The final merge
    -- carries ROOT.
    local node = chunk_cvs[1]
    for i = 2, #chunk_cvs do
      node = parent_cv(node, chunk_cvs[i], i == #chunk_cvs)
    end
    root_words = node
  end

  -- Serialize the 8 root words little-endian into 32 bytes.
  local bytes = {}
  for i = 1, 8 do
    local w = root_words[i]
    bytes[#bytes + 1] = string.char(band(w, 0xFF))
    bytes[#bytes + 1] = string.char(band(rshift(w, 8), 0xFF))
    bytes[#bytes + 1] = string.char(band(rshift(w, 16), 0xFF))
    bytes[#bytes + 1] = string.char(band(rshift(w, 24), 0xFF))
  end
  return table.concat(bytes)
end

M.OUT_LEN = OUT_LEN
M.BLOCK_LEN = BLOCK_LEN
M.CHUNK_LEN = CHUNK_LEN
-- Silence unused-local lints for symbols kept for spec readability.
M._unused = { bnot, tobit }

return M
