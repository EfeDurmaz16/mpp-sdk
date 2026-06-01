-- Lua cross-SDK conformance-vector runner.
--
-- Honors the same stdin/stdout contract as the TypeScript reference runner
-- (harness/src/conformance/ts-runner.ts) and the Go runner
-- (go/cmd/conformance/main.go): read one conformance vector as JSON on
-- stdin, drive the real Lua pay_kit SDK for the requested mode, and emit
-- one RunnerResult line as JSON on stdout.
--
-- ROLE: the Lua SDK is SERVER-ONLY. It ships a pre-broadcast charge
-- verifier (pay_kit.solana.verifier) and the wire canonical-JSON /
-- base64url encoders, but no client-side transaction builder. The runner
-- therefore supports:
--   * canonical-bytes  -- JCS (RFC 8785) + base64url + fixed-width bytes
--   * verify-transaction WHEN the vector ships a concrete `transaction`
--     base64 (the pure pre-broadcast checks: no live RPC, no HMAC)
-- Build-transaction vectors, and verify-transaction vectors that expect
-- the runner to BUILD the transaction first, have no server-only
-- equivalent. For those the runner emits a clear "unsupported-mode"
-- reject so the driver SKIPs (not fails) the vector for Lua.
--
-- The run is deterministic and RPC-free: the verifier decodes the wire
-- bytes locally and never contacts a validator. A vector that would
-- require a live RPC call is, by construction, a build vector this runner
-- already refuses.
--
-- Run from the `lua/` directory so the `./?.lua` / `./?/init.lua` package
-- path resolves the pay_kit tree (see tests/run.lua and the RUNNER_CWD
-- entry in harness/test/conformance.test.ts).

package.path = table.concat({
  './?.lua',
  './?/init.lua',
  package.path,
}, ';')

local json = require('pay_kit.util.json')
local base64url = require('pay_kit.util.base64url')
local base64_std = require('pay_kit.util.base64_std')
local verifier = require('pay_kit.solana.verifier')
local transaction = require('pay_kit.solana.transaction')
local instructions = require('pay_kit.solana.instructions')
local base58 = require('pay_kit.solana.base58')
local ata = require('pay_kit.solana.ata')
local mints = require('pay_kit.solana.mints')

local UNSUPPORTED_MODE = 'unsupported-mode'

local TOKEN_PROGRAM = instructions.TOKEN_PROGRAM
local TOKEN_2022_PROGRAM = instructions.TOKEN_2022_PROGRAM
local SYSTEM_PROGRAM = instructions.SYSTEM_PROGRAM
local MEMO_PROGRAM = instructions.MEMO_PROGRAM
local COMPUTE_BUDGET_PROGRAM = instructions.COMPUTE_BUDGET_PROGRAM

-- Read all of stdin into one string.
local function read_stdin()
  return io.read('*a') or ''
end

-- Decode a lower/upper hex string into a raw byte string.
local function hex_to_bytes(hex)
  if #hex % 2 ~= 0 then
    error('hex string must have an even length')
  end
  local out = {}
  for i = 1, #hex, 2 do
    local byte = tonumber(hex:sub(i, i + 1), 16)
    if byte == nil then
      error('invalid hex byte at offset ' .. i)
    end
    out[#out + 1] = string.char(byte)
  end
  return table.concat(out)
end

-- Emit one RunnerResult line. The JSON encoder is the SDK's RFC 8785 JCS
-- encoder; key order is canonical, which is fine because the driver parses
-- the line with JSON.parse and reads fields by name.
local function emit(result)
  io.write(json.encode(result) .. '\n')
end

-- Apply the same precedence rules as the TS / Go reference runners:
-- top-level `asset` / `payTo` win over `currency` / `recipient`, and the
-- methodDetails carry network / decimals / tokenProgram / splits /
-- feePayer. The Lua verifier consumes a request table shaped exactly like
-- the live charge route's decoded request, so we mirror that shape here.
local function flatten_request(req)
  local currency = req.currency
  if req.asset ~= nil and req.asset ~= json.null then
    currency = req.asset
  end
  local recipient = req.recipient
  if req.payTo ~= nil and req.payTo ~= json.null then
    recipient = req.payTo
  end

  local md = req.methodDetails or {}
  local network = md.network
  if network == nil or network == json.null then
    network = 'mainnet'
  end

  local details = { network = network }
  -- decimals: the verifier types it as Option<u8>; keep it numeric when
  -- the vector pins it, leave nil otherwise so the verifier's "any
  -- decimals" branch applies (it never injects a default).
  if type(md.decimals) == 'number' then
    details.decimals = md.decimals
  end
  if type(md.tokenProgram) == 'string' then
    details.tokenProgram = md.tokenProgram
  end
  if md.feePayer == true then
    details.feePayer = true
  end
  if type(md.feePayerKey) == 'string' then
    details.feePayerKey = md.feePayerKey
  end
  if type(md.splits) == 'table' then
    details.splits = md.splits
  end

  local request = {
    amount = req.amount,
    currency = currency,
    recipient = recipient,
    methodDetails = details,
  }
  if type(req.externalId) == 'string' and req.externalId ~= '' then
    request.externalId = req.externalId
  end
  return request
end

-- ── wire transaction fixture builder ──
--
-- The Lua SDK is server-only: the verifier is the system under test, and a
-- verify vector that omits `input.transaction` only pins the request +
-- signer, expecting the runner to assemble the wire fixture the verifier
-- then accepts. This mirrors the Ruby runner's TxFixtureBuilder and lays
-- out instructions exactly how the Rust client builder emits them and the
-- Lua verifier reads them: transferChecked accounts (source, mint, dest,
-- authority); idempotent ATA create accounts (payer, ata, owner, mint,
-- system, token program); memo program data is the raw memo bytes. No RPC,
-- no signature: the verifier checks transaction shape, not signatures.

-- Encode an unsigned decimal-string value as `width` little-endian bytes.
local function le_bytes(value, width)
  local digits = {}
  local text = tostring(value)
  if not text:match('^%d+$') then
    error('invalid unsigned integer: ' .. text)
  end
  for i = 1, #text do
    digits[i] = tonumber(text:sub(i, i))
  end
  local out = {}
  for _ = 1, width do
    -- Long division of the decimal digit array by 256 collects one byte.
    local remainder = 0
    local next_digits = {}
    local started = false
    for i = 1, #digits do
      local acc = remainder * 10 + digits[i]
      local q = math.floor(acc / 256)
      remainder = acc % 256
      if started or q ~= 0 then
        next_digits[#next_digits + 1] = q
        started = true
      end
    end
    if #next_digits == 0 then
      next_digits = { 0 }
    end
    out[#out + 1] = string.char(remainder)
    digits = next_digits
  end
  for i = 1, #digits do
    if digits[i] ~= 0 then
      error('value does not fit in ' .. width .. ' bytes')
    end
  end
  return table.concat(out)
end

-- Build a verify-transaction wire fixture from a flattened request and the
-- vector's 64-byte signer secret key. Returns a standard base64 string.
local function build_fixture(flat, signer_secret)
  if #signer_secret ~= 64 then
    error('signerSecretKey must be 64 bytes')
  end
  -- The public key is the trailing 32 bytes of the ed25519 secret key.
  local pub_bytes = {}
  for i = 33, 64 do
    pub_bytes[#pub_bytes + 1] = string.char(signer_secret[i])
  end
  local signer = base58.encode(table.concat(pub_bytes))

  local details = flat.methodDetails or {}
  local currency = flat.currency
  local recipient = flat.recipient
  local network = details.network or 'mainnet'
  local is_sol = type(currency) == 'string' and currency:upper() == 'SOL'

  local splits = details.splits or {}
  local total = tonumber(flat.amount)
  local split_total = 0
  for i = 1, #splits do
    split_total = split_total + tonumber(splits[i].amount)
  end
  local primary = total - split_total

  -- Instruction list: { program = base58, accounts = { base58... }, data = raw }
  local ixs = {}
  local function add_ix(program, accounts, data)
    ixs[#ixs + 1] = { program = program, accounts = accounts, data = data }
  end

  if is_sol then
    add_ix(SYSTEM_PROGRAM, { signer, recipient },
      le_bytes(2, 4) .. le_bytes(primary, 8))
    for i = 1, #splits do
      add_ix(SYSTEM_PROGRAM, { signer, splits[i].recipient },
        le_bytes(2, 4) .. le_bytes(splits[i].amount, 8))
      if splits[i].memo and splits[i].memo ~= '' then
        add_ix(MEMO_PROGRAM, {}, splits[i].memo)
      end
    end
  else
    local mint = mints.resolve_mint(currency, network) or currency
    local token_program = details.tokenProgram
      or mints.default_token_program_for_currency(currency, network)
    local decimals = details.decimals or 6
    local source_ata = ata.derive(signer, mint, token_program)
    local dest_ata = ata.derive(recipient, mint, token_program)
    add_ix(token_program, { source_ata, mint, dest_ata, signer },
      string.char(12) .. le_bytes(primary, 8) .. string.char(decimals))
    for i = 1, #splits do
      local sr = splits[i].recipient
      local sata = ata.derive(sr, mint, token_program)
      if splits[i].ataCreationRequired == true then
        add_ix(instructions.ASSOCIATED_TOKEN_PROGRAM,
          { signer, sata, sr, mint, SYSTEM_PROGRAM, token_program },
          string.char(1))
      end
      add_ix(token_program, { source_ata, mint, sata, signer },
        string.char(12) .. le_bytes(splits[i].amount, 8) .. string.char(decimals))
      if splits[i].memo and splits[i].memo ~= '' then
        add_ix(MEMO_PROGRAM, {}, splits[i].memo)
      end
    end
  end

  -- Account key set: signer (lone signer / fee payer) at index 0, then every
  -- instruction account and program id in first-seen order. The verifier
  -- reads layout by index, so a single read-only-unsigned tail suffices.
  local keys = { signer }
  local seen = { [signer] = true }
  local function push_key(k)
    if not seen[k] then
      seen[k] = true
      keys[#keys + 1] = k
    end
  end
  for _, ix in ipairs(ixs) do
    for _, a in ipairs(ix.accounts) do
      push_key(a)
    end
    push_key(ix.program)
  end
  local index = {}
  for i, k in ipairs(keys) do
    index[k] = i - 1
  end

  local blockhash = details.recentBlockhash or string.rep('1', 32)
  local ok, blockhash_bytes = pcall(base58.decode, blockhash)
  if not ok or #blockhash_bytes ~= 32 then
    blockhash_bytes = base58.decode(string.rep('1', 32))
  end

  local signer_count = 1
  local readonly_unsigned = #keys - 1

  local parts = {}
  parts[#parts + 1] = string.char(signer_count, 0, readonly_unsigned)
  parts[#parts + 1] = transaction.compact_u16(#keys)
  for _, k in ipairs(keys) do
    parts[#parts + 1] = base58.decode(k)
  end
  parts[#parts + 1] = blockhash_bytes
  parts[#parts + 1] = transaction.compact_u16(#ixs)
  for _, ix in ipairs(ixs) do
    parts[#parts + 1] = string.char(index[ix.program])
    parts[#parts + 1] = transaction.compact_u16(#ix.accounts)
    for _, a in ipairs(ix.accounts) do
      parts[#parts + 1] = string.char(index[a])
    end
    parts[#parts + 1] = transaction.compact_u16(#ix.data)
    parts[#parts + 1] = ix.data
  end
  local message = table.concat(parts)

  local signatures = transaction.compact_u16(signer_count)
    .. string.rep(string.char(0), 64 * signer_count)
  return base64_std.encode(signatures .. message)
end

-- Decode a base64 wire transaction into the semantic shape the conformance
-- driver asserts against. Mirrors the TS reference decoder
-- (harness/src/conformance/decode.ts) and the Go shapeFromTransaction:
-- fee payer is account[0], SPL transfers come from transferChecked
-- (discriminator 12), SOL transfers from the System Program transfer
-- (discriminator 2), memos from the Memo Program, and compute caps from
-- the ComputeBudget program.
local function shape_from_transaction(transaction_base64)
  local tx = transaction.from_base64(transaction_base64)
  local keys = tx.message.account_keys
  if #keys == 0 then
    error('transaction has no account keys')
  end

  local shape = {
    feePayer = keys[1],
    forbiddenPrograms = {},
    transfers = {},
    memo = {},
  }

  for _, ix in ipairs(tx.message.instructions) do
    local program = instructions.program_id_for(tx, ix)
    local data = ix.data

    if program == COMPUTE_BUDGET_PROGRAM then
      if #data == 5 and data:byte(1) == 2 then
        shape.maxComputeUnitLimit = tonumber(instructions.decode_le_uint(data, 2, 4))
      elseif #data == 9 and data:byte(1) == 3 then
        shape.maxComputeUnitPrice = instructions.decode_le_uint(data, 2, 8)
      end
    elseif program == MEMO_PROGRAM then
      shape.memo[#shape.memo + 1] = data
    elseif program == SYSTEM_PROGRAM then
      local parsed = instructions.parse_system_transfer(ix)
      if parsed then
        local dest = tx.message.account_keys[ix.accounts[2] + 1]
        shape.transfers[#shape.transfers + 1] = {
          kind = 'sol',
          destination = dest,
          amount = parsed.lamports,
        }
      end
    elseif program == TOKEN_PROGRAM or program == TOKEN_2022_PROGRAM then
      local parsed = instructions.parse_transfer_checked(ix)
      if parsed then
        local mint = tx.message.account_keys[ix.accounts[2] + 1]
        local dest = tx.message.account_keys[ix.accounts[3] + 1]
        shape.transfers[#shape.transfers + 1] = {
          kind = 'spl',
          destination = dest,
          mint = mint,
          amount = parsed.amount,
          decimals = parsed.decimals,
          tokenProgram = program,
        }
      end
    end
  end

  return shape
end

local function run_canonical_bytes(vector)
  local input = vector.input or {}
  local exact = {}
  if input.value ~= nil then
    local canonical = json.encode(input.value)
    exact.canonicalJson = canonical
    exact.base64Url = base64url.encode(canonical)
  end
  if type(input.encodeBase64Url) == 'table' then
    local enc = input.encodeBase64Url
    if type(enc.hexBytes) == 'string' and enc.hexBytes ~= '' then
      local raw = hex_to_bytes(enc.hexBytes)
      local bytes = {}
      for i = 1, #raw do
        bytes[i] = raw:byte(i)
      end
      -- Preserve an empty-table-as-array marker is unnecessary here because
      -- the 48-byte vector is always non-empty; the driver compares the
      -- numeric array element-wise.
      exact.bytes = bytes
      exact.base64Url = base64url.encode(raw)
    elseif type(enc.utf8) == 'string' then
      exact.base64Url = base64url.encode(enc.utf8)
    end
  end
  return { id = vector.id, outcome = 'accept', exactBytes = exact }
end

-- verify-transaction: the Lua SDK is server-only, so the verifier is the
-- system under test. When the vector pins a concrete `transaction` the
-- runner verifies it directly; when it omits one (pinning only request +
-- signerSecretKey) the runner assembles the wire fixture itself via
-- build_fixture, exactly as the Ruby runner does, then runs the verifier
-- over it. Either way the SDK verifier is what is exercised.
local function run_verify_transaction(vector)
  local input = vector.input or {}
  if type(input.request) ~= 'table' then
    error('verify vector is missing input.request')
  end
  local request = flatten_request(input.request)

  local tx = input.transaction
  if type(tx) ~= 'string' or tx == '' then
    if type(input.signerSecretKey) ~= 'table' then
      error('verify vector without input.transaction is missing input.signerSecretKey')
    end
    tx = build_fixture(request, input.signerSecretKey)
  end

  -- Pure pre-broadcast structural verify: decode the wire bytes and assert
  -- the charge shape. No RPC, no HMAC, no broadcast.
  verifier.verify_transaction_base64(tx, request)
  return {
    id = vector.id,
    outcome = 'accept',
    transactionShape = shape_from_transaction(tx),
  }
end

-- build-transaction: no server-only equivalent. The Lua SDK ships no
-- client builder, so report unsupported-mode and let the driver SKIP.
local function run_build_transaction(vector)
  return {
    id = vector.id,
    outcome = UNSUPPORTED_MODE,
    error = 'lua SDK is server-only: no client-side transaction builder',
  }
end

local function run_vector(vector)
  if vector.mode == 'canonical-bytes' then
    return run_canonical_bytes(vector)
  elseif vector.mode == 'build-transaction' then
    return run_build_transaction(vector)
  elseif vector.mode == 'verify-transaction' then
    return run_verify_transaction(vector)
  end
  return {
    id = vector.id,
    outcome = 'reject',
    error = 'unknown mode ' .. tostring(vector.mode),
  }
end

-- Map the Lua SDK's native reject message onto the shared cross-SDK
-- RejectCode vocabulary the interop harness asserts per reject vector
-- (see harness/vectors/charge-rejects.json `expect.rejectCode`). The
-- match is done on the lowercased message with plain substring checks
-- (string.find with `plain = true`) so Lua-pattern magic characters in
-- the message are treated literally.
--
-- The Lua SDK is server-only: it processes verify-transaction reject
-- vectors that ship a concrete `transaction`, so the only reject vector
-- it actually classifies today is the transferChecked decimals mismatch
-- (which surfaces as a no-matching-transfer reject). The remaining
-- branches stay in place so the classifier matches the other reject
-- families once a built-transaction path exists.
local function has(msg, needle)
  return string.find(msg, needle, 1, true) ~= nil
end

local function classify_reject(message)
  if type(message) ~= 'string' then
    return nil
  end
  local m = message:lower()

  if has(m, 'compute unit price') and has(m, 'exceed')
    and (has(m, 'cap') or has(m, 'maximum')) then
    return 'compute-price-over-cap'
  end
  if has(m, 'compute unit limit') and has(m, 'exceed') then
    return 'compute-limit-over-cap'
  end
  if has(m, 'fee payer cannot authorize') then
    return 'fee-payer-not-authority'
  end
  if has(m, 'splits consume the entire amount')
    or has(m, 'split amounts exceed total amount') then
    return 'splits-exceed-amount'
  end
  if has(m, 'too many splits') then
    return 'too-many-splits'
  end
  if (has(m, 'no matching') and has(m, 'transfer'))
    or (has(m, 'unexpected') and has(m, 'transfer')) then
    return 'no-matching-transfer'
  end
  if has(m, 'amount') and (has(m, 'mismatch') or has(m, 'does not match')) then
    return 'amount-mismatch'
  end
  if has(m, 'invalid') or has(m, 'malformed')
    or has(m, 'decode') or has(m, 'payload') then
    return 'invalid-payload'
  end
  return nil
end

local function main()
  local raw = read_stdin()
  raw = raw:gsub('^%s+', ''):gsub('%s+$', '')
  if raw == '' then
    io.stderr:write('lua conformance runner received empty stdin\n')
    os.exit(1)
  end

  local ok, vector = pcall(json.decode, raw)
  if not ok then
    io.stderr:write('failed to parse vector: ' .. tostring(vector) .. '\n')
    os.exit(1)
  end

  local result
  local run_ok, run_err = pcall(function()
    result = run_vector(vector)
  end)
  if not run_ok then
    -- A protocol-level rejection surfaces as outcome reject with the SDK's
    -- error message; the verifier raises either a plain string or a
    -- { code, message } table.
    local message
    if type(run_err) == 'table' then
      message = run_err.message or json.encode(run_err)
    else
      message = tostring(run_err)
    end
    result = { id = vector.id, outcome = 'reject', error = message }
    local code = classify_reject(message)
    if code ~= nil then
      result.rejectCode = code
    end
  end

  emit(result)
end

main()
