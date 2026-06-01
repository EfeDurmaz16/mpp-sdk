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
local verifier = require('pay_kit.solana.verifier')
local transaction = require('pay_kit.solana.transaction')
local instructions = require('pay_kit.solana.instructions')

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

-- verify-transaction: the Lua SDK is server-only, so it can only verify a
-- transaction the vector hands it. A vector that expects the runner to
-- build the transaction first (no input.transaction) has no server-only
-- equivalent; emit unsupported-mode so the driver SKIPs it for Lua.
local function run_verify_transaction(vector)
  local input = vector.input or {}
  if type(input.transaction) ~= 'string' or input.transaction == '' then
    return {
      id = vector.id,
      outcome = UNSUPPORTED_MODE,
      error = 'lua SDK is server-only: cannot build a transaction to verify; '
        .. 'this vector ships no concrete input.transaction',
    }
  end
  if type(input.request) ~= 'table' then
    error('verify vector is missing input.request')
  end
  local request = flatten_request(input.request)
  -- Pure pre-broadcast structural verify: decode the wire bytes and assert
  -- the charge shape. No RPC, no HMAC, no broadcast.
  verifier.verify_transaction_base64(input.transaction, request)
  return {
    id = vector.id,
    outcome = 'accept',
    transactionShape = shape_from_transaction(input.transaction),
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
