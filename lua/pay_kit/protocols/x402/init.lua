--[[
x402 (exact scheme) self-hosted adapter for Lua.

Ports the Ruby gem's `X402::Server::Exact` flow to LuaJIT / OpenResty:
- Builds the v2 `PAYMENT-REQUIRED` envelope (challenge emission stays v2-only;
  there is no need to emit a legacy v1 challenge).
- Decodes the inbound credential from `PAYMENT-SIGNATURE` (v2) or, for legacy
  clients, `X-PAYMENT` (v1). The legacy `x402Version == 1` envelope carries a
  top-level `scheme` + `network` and no `accepted`; the route's expected
  requirements always come from the server offer, never the credential.
- Matches client-asserted accepted requirement against server offer
  via identity tuple (scheme/network/asset/payTo + canonical extras).
- Verifies the transaction's structural shape against the offer.
- Signs as facilitator (operator.signer fills the facilitator slot).
- Broadcasts via the cosocket-aware pay_kit.solana.rpc client.
- Marks the signature consumed in the replay store.

Delegated mode (`config.x402.facilitator_url` set) is NOT implemented
yet; the dispatcher refuses to bind the adapter and raises
`errors.NOT_IMPLEMENTED` so the design's flag still works.

This adapter handles the common case: a single SPL transferChecked
to the gate's `pay_to`, with the operator paying network fees. Edge
cases the Ruby gem covers (Token-2022, ATA pre-creation toggle,
sol-native scheme) are left as follow-up; they slot into the same
dispatch shape.
]]

local cjson_safe = require('cjson.safe')
local base64_std = require('pay_kit.util.base64_std')
local errors     = require('pay_kit.errors')
local rpc_mod    = require('pay_kit.solana.rpc')
local rpc_transport = require('pay_kit.solana.rpc_transport')
local tx_cosign  = require('pay_kit.solana.tx_cosign')
local x402_verify = require('pay_kit.protocols.x402.exact.verify')
local tx_mod     = require('pay_kit.solana.transaction')
local network_check = require('pay_kit.protocols.mpp.server.network_check')

local M = {}
local Adapter = {}
Adapter.__index = Adapter

-- --- constants ------------------------------------------------------

-- x402Version is an integer on the wire (constants.rs:10/:13). v2 is the
-- default everywhere; v1 is the legacy backward-compat shape this adapter
-- also accepts inbound (constants.rs:7-13).
local X402_VERSION_V1 = 1
local X402_VERSION_V2 = 2
local EXACT_SCHEME    = 'exact'

-- v2 (default) header names (constants.rs:25-31). Lowercase because the
-- OpenResty request reader lowercases header keys.
local PAYMENT_REQUIRED_HEADER  = 'payment-required'
local PAYMENT_SIGNATURE_HEADER = 'payment-signature'
local PAYMENT_RESPONSE_HEADER  = 'payment-response'
-- Legacy v1 header names (constants.rs:16-22). The client writes the v1
-- credential to X-PAYMENT and reads the v1 challenge from X-PAYMENT-REQUIRED.
local X402_V1_PAYMENT_HEADER          = 'x-payment'
local X402_V1_PAYMENT_REQUIRED_HEADER = 'x-payment-required'
local DEFAULT_FIXTURE_SETTLEMENT_HEADER = 'x-payment-settlement-signature'
local DEFAULT_MAX_TIMEOUT_SECONDS = 60
local DEFAULT_DECIMALS = 6
local TOKEN_PROGRAM_BASE58 = 'TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA'

local CAIP2_MAINNET = 'solana:5eykt4UsFv8P8NJdTREpY1vzqKqZKvdp'
local CAIP2_DEVNET  = 'solana:EtWTRABZaYq6iMfeYKouRu166VU2xqa1'

-- Legacy v1 network strings (constants.rs:4 SOLANA_NETWORK; payment.rs:383).
local LEGACY_NETWORK_SOLANA  = 'solana'
local LEGACY_NETWORK_DEVNET  = 'solana-devnet'

local function caip2_for(pay_kit_network)
  if pay_kit_network == 'solana_mainnet' then return CAIP2_MAINNET end
  return CAIP2_DEVNET                          -- devnet and localnet share devnet CAIP-2
end

-- Normalize any network identifier (CAIP-2 or legacy slug) to its CAIP-2
-- form, mirroring rust `caip2_network_for_cluster` (types.rs:33-40). The v1
-- arm round-trips the credential's legacy network string through this so a
-- `solana` / `solana-devnet` value normalizes back to the server's CAIP-2
-- network before the mismatch check (exact.rs:322).
local function caip2_network_for_cluster(network)
  if type(network) ~= 'string' then return '' end
  if network == LEGACY_NETWORK_SOLANA or network == 'mainnet'
    or network == 'mainnet-beta' or network == CAIP2_MAINNET then
    return CAIP2_MAINNET
  end
  if network == LEGACY_NETWORK_DEVNET or network == 'devnet'
    or network == 'localnet' or network == CAIP2_DEVNET then
    return CAIP2_DEVNET
  end
  return network                              -- already CAIP-2 or unknown; pass through
end

-- Legacy v1 network string for a server offer / requirement, mirroring
-- rust `v1_network_for_requirements` (payment.rs:383-394): select on the
-- requirement's cluster, falling back to its network, then collapse the
-- CAIP-2 space into the two legacy strings: devnet -> "solana-devnet",
-- everything else (mainnet/testnet/localnet/unknown) -> "solana".
local function legacy_network_for_requirements(requirements)
  requirements = requirements or {}
  local selector = requirements.cluster
  if selector == nil or selector == '' then selector = requirements.network end
  if selector == 'devnet' or selector == LEGACY_NETWORK_DEVNET
    or selector == CAIP2_DEVNET then
    return LEGACY_NETWORK_DEVNET
  end
  return LEGACY_NETWORK_SOLANA
end

local function network_label(pay_kit_network)
  if pay_kit_network == 'solana_mainnet' then return 'mainnet' end
  if pay_kit_network == 'solana_devnet' then return 'devnet' end
  return 'localnet'
end

-- Match the cross-SDK identity tuple. Mirrors Ruby's
-- `Types.accepted_requirement_matches?` (PR #138). Excludes `amount`
-- and `maxTimeoutSeconds` so v2 credentials whose client omitted
-- amount still match a server offer that includes it.
local REQUIREMENT_IDENTITY_KEYS       = {'scheme', 'network', 'asset', 'payTo'}
local REQUIREMENT_EXTRA_IDENTITY_KEYS = {'feePayer', 'tokenProgram', 'memo'}

local function accepted_requirement_matches(client_accepted, server_offer)
  if type(client_accepted) ~= 'table' or type(server_offer) ~= 'table' then
    return false
  end
  for _, key in ipairs(REQUIREMENT_IDENTITY_KEYS) do
    if client_accepted[key] ~= server_offer[key] then return false end
  end
  local left_extra  = client_accepted.extra or {}
  local right_extra = server_offer.extra or {}
  for _, key in ipairs(REQUIREMENT_EXTRA_IDENTITY_KEYS) do
    if right_extra[key] ~= nil and left_extra[key] ~= right_extra[key] then
      return false
    end
  end
  return true
end

-- --- offer construction --------------------------------------------

-- Fetch a recent blockhash from the server's RPC and stamp it into
-- the challenge's `extra.recentBlockhash` so clients sign against
-- the same chain state the server will broadcast to. Mirrors Ruby
-- PR #142 follow-up: useful on localnet / forked-mainnet (Surfpool)
-- where the client and server can disagree on `latest_blockhash`,
-- and harmless on real networks because the RPC always agrees with
-- itself.
--
-- Scope: this is currently only consumed by the pay-kit Rust client;
-- canonical x402 SDKs ignore `accepted.extra.recentBlockhash` and
-- call `getLatestBlockhash` against their own RPC. Spec discussion
-- to promote `recentBlockhash` (or equivalent) into the canonical
-- `accepted.extra` shape is tracked upstream.
local function fetch_server_blockhash(config)
  if type(config.recent_blockhash_provider) == 'function' then
    local ok, bh = pcall(config.recent_blockhash_provider)
    if ok and type(bh) == 'string' and bh ~= '' then return bh end
    return nil
  end
  if not config.rpc_url or config.rpc_url == '' then return nil end
  local ok_rpc, rpc = pcall(rpc_mod.new,
    {url = config.rpc_url, transport = rpc_transport.new()})
  if not ok_rpc or not rpc then return nil end
  local ok_call, blockhash = pcall(function() return rpc:latest_blockhash() end)
  if not ok_call or type(blockhash) ~= 'string' or blockhash == '' then return nil end
  return blockhash
end

local function exact_requirement(config, gate, resource_path, mint)
  local op_signer = config:effective_x402_signer()
  local extra = {
    feePayer     = op_signer:pubkey(),
    decimals     = DEFAULT_DECIMALS,
    tokenProgram = TOKEN_PROGRAM_BASE58,
    memo         = resource_path,
  }
  local blockhash = fetch_server_blockhash(config)
  if blockhash then extra.recentBlockhash = blockhash end
  local amount = tostring(gate:total_units())
  return {
    scheme              = 'exact',
    network             = caip2_for(config.network),
    asset               = mint,
    amount              = amount,
    maxAmountRequired   = amount,           -- emit both spellings for cross-SDK interop
    payTo               = gate:pay_to(),
    maxTimeoutSeconds   = DEFAULT_MAX_TIMEOUT_SECONDS,
    extra               = extra,
  }
end

local function exact_challenge(config, gate, resource_path)
  local mint = gate:amount():primary_coin()
  return {
    x402Version = X402_VERSION_V2,
    resource    = {type = 'http', url = resource_path, uri = resource_path},
    accepts     = { exact_requirement(config, gate, resource_path, mint) },
  }
end

local function encode_payment_required(challenge)
  return base64_std.encode(cjson_safe.encode(challenge))
end

-- --- PaymentRequirements dual-shape parse --------------------------
--
-- Mirrors rust `PaymentRequirements::deserialize` (types.rs:308-385): a
-- single type that reads BOTH the v1 flat shape (recipient / currency /
-- maxAmountRequired with a legacy network string) and the v2 accepted shape
-- (payTo / asset / amount with a CAIP-2 network), pulling fields by their
-- v1-or-v2 aliases and folding extra-nested fields up to the top level. The
-- legacy network string is normalized to CAIP-2 so a v1 flat object
-- deserializes into the same normalized form the server compares against.
local function parse_payment_requirements(obj)
  if type(obj) ~= 'table' then return nil end
  local extra = type(obj.extra) == 'table' and obj.extra or {}
  local fee_payer_key = obj.feePayerKey or extra.feePayer
  local req = {
    scheme    = obj.scheme or EXACT_SCHEME,
    network   = caip2_network_for_cluster(obj.network or LEGACY_NETWORK_SOLANA),
    recipient = obj.recipient or obj.payTo,           -- v1 flat OR v2 name
    amount    = obj.amount or obj.maxAmountRequired,  -- v1 OR canonical
    currency  = obj.currency or obj.asset or 'SOL',   -- v1 OR v2 name
    decimals  = obj.decimals or extra.decimals,
    tokenProgram    = obj.tokenProgram or extra.tokenProgram,
    recentBlockhash = obj.recentBlockhash or extra.recentBlockhash,
    feePayerKey     = fee_payer_key,
    feePayer        = obj.feePayer,
    maxAge          = obj.maxAge or obj.maxTimeoutSeconds,
  }
  if req.feePayer == nil and fee_payer_key ~= nil then req.feePayer = true end
  req.cluster = obj.cluster
  -- Retain `accepted` only when the object looks like the v2 accepted shape
  -- (carries amount + asset + payTo). A v1 flat object yields no accepted.
  if obj.amount ~= nil and obj.asset ~= nil and obj.payTo ~= nil then
    req.accepted = obj
  end
  return req
end

-- --- legacy v1 challenge parse -------------------------------------
--
-- Client-side helper mirroring the v1 arm of rust
-- `parse_x402_challenge_with_selection` (payment.rs:236-243): the v1
-- X-PAYMENT-REQUIRED header value is RAW JSON (no base64, no `accepts[]`
-- wrapper) deserialized directly into a single PaymentRequirements via the
-- dual-shape parser above. Returned as-is (single requirement, no selection).
local function parse_challenge_header_v1(header_value)
  if type(header_value) ~= 'string' or header_value == '' then return nil end
  local obj = cjson_safe.decode(header_value)
  if type(obj) ~= 'table' then return nil end
  return parse_payment_requirements(obj)
end

-- --- legacy v1 credential producer ---------------------------------
--
-- Client-side helper mirroring rust `build_payment_header_v1`
-- (payment.rs:144-160). The proof is byte-for-byte identical to v2 (same
-- build_payment); only the envelope differs: x402Version=1, top-level
-- scheme="exact" + legacy network string, NO accepted, NO resource, then the
-- flattened proof. The encoded value is written to the X-PAYMENT header.
local function build_payment_header_v1(requirements, proof)
  local envelope = {
    scheme      = EXACT_SCHEME,
    network     = legacy_network_for_requirements(requirements),
    x402Version = X402_VERSION_V1,
  }
  -- Flatten the proof (transaction xor signature) into the envelope, matching
  -- the rust untagged PaymentProof flatten (types.rs:429-444, payment.rs:159).
  if type(proof) == 'table' then
    if proof.transaction ~= nil then
      envelope.transaction = proof.transaction
    elseif proof.signature ~= nil then
      envelope.signature = proof.signature
    end
  end
  return base64_std.encode(cjson_safe.encode(envelope))
end

-- --- credential decoding -------------------------------------------

-- Parse a payment-signature credential. Mirrors rust
-- `parse_payment_signature` (exact.rs:307-349): decode STANDARD base64,
-- deserialize the envelope, then branch on `x402Version`.
--
-- `expected_caip2` is the server's CAIP-2 network used for the per-version
-- network-mismatch checks. It is optional so the structural tests can decode
-- an envelope without a configured server; when omitted the network check is
-- skipped (the route-level offer comparison still applies for v2).
local function decode_payment_signature(header_value, expected_caip2)
  if type(header_value) ~= 'string' or header_value == '' then
    return nil, errors.PAYMENT_REQUIRED
  end
  local decoded = base64_std.decode(header_value)
  if not decoded then
    return nil, errors.INVALID_PROOF .. ': payment-signature base64 decode failed'
  end
  local envelope = cjson_safe.decode(decoded)
  if type(envelope) ~= 'table' then
    return nil, errors.INVALID_PROOF .. ': payment-signature not a JSON object'
  end

  local version = envelope.x402Version
  if version == X402_VERSION_V1 then
    -- v1 commits only to scheme + network at parse time; there is no
    -- `accepted` object (exact.rs:316-327).
    local scheme = envelope.scheme or ''
    if scheme ~= EXACT_SCHEME then
      return nil, errors.INVALID_PROOF .. ': unsupported payment scheme'
    end
    if expected_caip2 then
      local network = caip2_network_for_cluster(envelope.network or '')
      if network ~= expected_caip2 then
        return nil, errors.WRONG_NETWORK ..
          ': credential network does not match server'
      end
    end
    return envelope
  elseif version == X402_VERSION_V2 then
    if expected_caip2 then
      local accepted = envelope.accepted
      if type(accepted) ~= 'table' then
        return nil, errors.INVALID_PROOF .. ': missing accepted'
      end
      local network = caip2_network_for_cluster(accepted.network or '')
      if network ~= expected_caip2 then
        return nil, errors.WRONG_NETWORK ..
          ': credential network does not match server'
      end
    end
    return envelope
  end

  -- Genuinely-unknown versions are always rejected (exact.rs:342-346).
  return nil, errors.INVALID_PROOF .. ': unsupported x402Version'
end

-- --- verifier (structural) -----------------------------------------
--
-- The Ruby gem's 11-rule verifier lives at
-- ruby/lib/x402/protocol/schemes/exact/verify.rb. Lua port focuses on
-- the happy-path subset: single SPL transferChecked to `payTo`, with
-- the credential's claimed amount + memo + token program matching the
-- offer. Edge rules (Token-2022 program id distinction, ATA presence
-- check, sol-native branching) are tracked as follow-up.

-- Run the 11-rule structural verifier + client-signature check. The
-- facilitator key (operator's signer) is the only managed signer; the
-- verifier refuses to accept a credential whose transfer authority or
-- source matches the facilitator (so a malicious credential cannot
-- "spend the facilitator's funds").
local function verify_transaction_shape(transaction_b64, offer, facilitator_b58)
  local managed = {facilitator_b58}
  local ok, transfer = pcall(x402_verify.verify, transaction_b64, offer, managed)
  if not ok then return nil, transfer end
  -- Client signatures must validate against the message bytes BEFORE
  -- the facilitator cosigns, otherwise a malformed envelope leaks
  -- back to a malformed-envelope attacker.
  local sig_ok, sig_err = pcall(x402_verify.verify_client_signatures,
                                transaction_b64, managed)
  if not sig_ok then return nil, sig_err end
  return transfer
end

-- --- broadcast helpers ---------------------------------------------

local function build_rpc(config)
  return rpc_mod.new({url = config.rpc_url, transport = rpc_transport.new()})
end

local function consume_signature(store, signature)
  if not store then return true end
  local key = 'x402-svm-exact:consumed:' .. signature
  if store.put_if_absent then
    return store:put_if_absent(key)
  end
  return true
end

-- --- public API -----------------------------------------------------

function M.new(opts)
  opts = opts or {}
  if not opts.config_resolver then
    return nil, 'pay_kit: protocols.x402.new requires config_resolver'
  end
  return setmetatable({
    _config_resolver = opts.config_resolver,
    _store           = opts.store,
  }, Adapter)
end

-- Case-insensitive header lookup across a set of candidate names. Rust uses
-- `eq_ignore_ascii_case` when reading both the v2 and v1 headers
-- (payment.rs:229/:238). OpenResty lowercases keys, but a raw table may carry
-- mixed casing, so match defensively.
local function header_lookup(headers, names)
  if type(headers) ~= 'table' then return nil end
  for _, want in ipairs(names) do
    local lower = want:lower()
    for key, value in pairs(headers) do
      if type(key) == 'string' and key:lower() == lower
        and value ~= nil and value ~= '' then
        return value
      end
    end
  end
  return nil
end

-- The inbound credential lives in PAYMENT-SIGNATURE (v2) or, for legacy
-- clients, X-PAYMENT (v1). Read whichever is present (exact.rs key server
-- requirement note; constants.rs:16/:25).
local PAYMENT_CREDENTIAL_HEADERS = {PAYMENT_SIGNATURE_HEADER, X402_V1_PAYMENT_HEADER}

local function read_credential_header(headers)
  return header_lookup(headers, PAYMENT_CREDENTIAL_HEADERS)
end

function M.detect(headers)
  return read_credential_header(headers) ~= nil
end

Adapter.detect = function(_, headers) return M.detect(headers) end

function Adapter:accepts_entry(gate, req)
  local config = self._config_resolver()
  local resource = (req and req.path) or '/'
  local req_obj = exact_requirement(config, gate, resource, gate:amount():primary_coin())
  req_obj.protocol = 'x402'
  return req_obj
end

function Adapter:challenge_headers(gate, req)
  local config = self._config_resolver()
  local resource = (req and req.path) or '/'
  local challenge = exact_challenge(config, gate, resource)
  return {
    [PAYMENT_REQUIRED_HEADER] = encode_payment_required(challenge),
  }
end

function Adapter:verify_and_settle(gate, req)
  local config = self._config_resolver()
  local headers = (req and req.headers) or {}
  local raw_credential = read_credential_header(headers)
  local credential, err = decode_payment_signature(raw_credential, caip2_for(config.network))
  if err then return nil, err end

  local resource = (req and req.path) or '/'
  local offer = exact_requirement(config, gate, resource, gate:amount():primary_coin())
  -- The route's expected requirements always come from the server offer,
  -- never the credential (exact.rs:453-462). For a v2 credential we still
  -- structurally match its self-described `accepted` against the offer; a v1
  -- credential carries no `accepted`, so this binding step is skipped and the
  -- offer alone is the source of truth (exact.rs:490, v1 has no accepted).
  if credential.x402Version == X402_VERSION_V2
    and not accepted_requirement_matches(credential.accepted, offer) then
    return nil, errors.CHARGE_REQUEST_MISMATCH ..
      ': accepted payment requirement does not match server challenge'
  end

  local payload = credential.payload
  if type(payload) ~= 'table' or type(payload.transaction) ~= 'string' then
    return nil, errors.INVALID_PROOF .. ': payment payload missing transaction'
  end

  if not base64_std.decode(payload.transaction) then
    return nil, errors.INVALID_PROOF .. ': transaction base64 decode failed'
  end

  -- Surfpool localnet sanity check. If the credential was signed on
  -- a Surfpool fixture but the server is configured for a non-localnet
  -- slug, reject up-front with the canonical wrong_network code rather
  -- than letting the broadcast hit the wrong cluster.
  -- Only flag wrong_network for mainnet challenges; the interop matrix
  -- shares devnet's CAIP-2 with surfpool-backed localnet fixtures, so a
  -- devnet label can legitimately carry a Surfpool-prefixed blockhash.
  if config.network == 'solana_mainnet' then
    local parsed_ok, parsed_tx = pcall(tx_mod.from_base64, payload.transaction)
    if parsed_ok and parsed_tx and parsed_tx.message and parsed_tx.message.recent_blockhash then
      local nerr = network_check.check_network_blockhash('mainnet',
        parsed_tx.message.recent_blockhash)
      if nerr then return nil, errors.WRONG_NETWORK end
    end
  end

  local signer = config:effective_x402_signer()
  local transfer, verify_err = verify_transaction_shape(payload.transaction,
    offer, signer:pubkey())
  if not transfer then
    return nil, errors.INVALID_PROOF .. ': ' .. tostring(verify_err)
  end

  -- Sign as facilitator. The operator's signer fills the facilitator
  -- slot. The transaction is already partially signed by the client;
  -- the facilitator inserts its signature at the matching account
  -- index, then broadcasts.
  local secret_bytes = signer._secret_key_bytes and signer:_secret_key_bytes()
  if not secret_bytes then
    return nil, errors.OPERATOR_SIGNER_MISSING ..
      ' (the facilitator slot needs a Local signer with raw bytes)'
  end

  local cosign_ok, cosigned_or_err = pcall(tx_cosign.cosign_base64,
    payload.transaction, secret_bytes)
  if not cosign_ok then
    return nil, errors.INVALID_PROOF .. ': facilitator cosign failed: ' ..
      tostring(cosigned_or_err)
  end
  local cosigned = cosigned_or_err

  -- Broadcast + consume + confirm.
  local rpc = build_rpc(config)
  local broadcast_ok, signature_or_err = pcall(function()
    return rpc:send_raw_transaction(cosigned)
  end)
  if not broadcast_ok then
    return nil, errors.INVALID_PROOF .. ': broadcast failed: ' ..
      tostring(signature_or_err)
  end
  local signature = signature_or_err
  if not signature or signature == '' then
    return nil, errors.INVALID_PROOF .. ': empty broadcast result'
  end

  if not consume_signature(self._store, signature) then
    return nil, errors.SIGNATURE_CONSUMED
  end

  local response_body = cjson_safe.encode({
    success     = true,
    network     = offer.network,
    transaction = signature,
  })
  return {
    protocol           = 'x402',
    scheme             = 'exact',
    transaction        = signature,
    settlement_headers = {
      [PAYMENT_RESPONSE_HEADER] = response_body,
      [DEFAULT_FIXTURE_SETTLEMENT_HEADER] = signature,
    },
    raw                = raw_credential,
  }
end

-- Test helpers / introspection. Not part of the public API.
M._private = {
  accepted_requirement_matches   = accepted_requirement_matches,
  exact_challenge                = exact_challenge,
  exact_requirement              = exact_requirement,
  encode_payment_required        = encode_payment_required,
  decode_payment_signature       = decode_payment_signature,
  network_label                  = network_label,
  caip2_for                      = caip2_for,
  caip2_network_for_cluster      = caip2_network_for_cluster,
  legacy_network_for_requirements = legacy_network_for_requirements,
  parse_payment_requirements     = parse_payment_requirements,
  parse_challenge_header_v1      = parse_challenge_header_v1,
  build_payment_header_v1        = build_payment_header_v1,
  -- Header name constants (mirroring constants.rs) for clients reading the
  -- legacy v1 challenge / writing the legacy v1 credential.
  X402_V1_PAYMENT_HEADER          = X402_V1_PAYMENT_HEADER,
  X402_V1_PAYMENT_REQUIRED_HEADER = X402_V1_PAYMENT_REQUIRED_HEADER,
}

return M
