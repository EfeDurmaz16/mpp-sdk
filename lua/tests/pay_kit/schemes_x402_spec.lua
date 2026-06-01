--[[
P5 x402 adapter wire-format coverage. The full broadcast / verifier
port is exercised by the cross-language harness in P11; these tests
pin the matching + envelope shape so a regression on the wire is
caught at the gem level.
]]

local helper   = require('tests.test_helper')
local pay_kit  = require('pay_kit')
local x402     = require('pay_kit.protocols.x402')
local cjson    = require('cjson.safe')

local SELLER = 'SeLLeRWaLLeT111111111111111111111111111111'

local function setup()
  pay_kit._reset_for_tests()
  assert(pay_kit.configure({
    network  = 'solana_devnet',
    operator = {recipient = SELLER},
  }))
end

local function make_gate(price_str)
  assert(pay_kit.gate('paid', {
    amount = assert(pay_kit.usd(price_str or '0.001',
      '4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU')),
  }))
  return assert(require('pay_kit.internal.registry').materialize('paid'))
end

-- --- detect ---------------------------------------------------------

helper.test('detect: returns true for non-empty PAYMENT-SIGNATURE header', function()
  helper.assert_equal(x402.detect({['payment-signature'] = 'abc'}), true)
  helper.assert_equal(x402.detect({['PAYMENT-SIGNATURE'] = 'abc'}), true)
end)

helper.test('detect: returns false for empty or missing header', function()
  helper.assert_equal(x402.detect({}), false)
  helper.assert_equal(x402.detect({['payment-signature'] = ''}), false)
  helper.assert_equal(x402.detect(nil), false)
end)

-- --- matcher --------------------------------------------------------

helper.test('matcher: identity tuple match ignores amount/maxTimeoutSeconds', function()
  local client = {
    scheme  = 'exact',
    network = 'solana:dev',
    asset   = 'MintAddr',
    payTo   = SELLER,
    extra   = {feePayer = 'Fp', tokenProgram = 'Tk', memo = '/paid'},
  }
  local server = {
    scheme            = 'exact',
    network           = 'solana:dev',
    asset             = 'MintAddr',
    amount            = '100',
    maxAmountRequired = '100',
    payTo             = SELLER,
    maxTimeoutSeconds = 60,
    extra             = {feePayer = 'Fp', tokenProgram = 'Tk', memo = '/paid', decimals = 6},
  }
  helper.assert_equal(x402._private.accepted_requirement_matches(client, server), true)
end)

helper.test('matcher: scheme/network/asset/payTo mismatch returns false', function()
  local server = {scheme = 'exact', network = 'solana:dev', asset = 'A', payTo = 'P'}
  helper.assert_equal(x402._private.accepted_requirement_matches(
    {scheme = 'other', network = 'solana:dev', asset = 'A', payTo = 'P'}, server), false)
  helper.assert_equal(x402._private.accepted_requirement_matches(
    {scheme = 'exact', network = 'solana:other', asset = 'A', payTo = 'P'}, server), false)
  helper.assert_equal(x402._private.accepted_requirement_matches(
    {scheme = 'exact', network = 'solana:dev', asset = 'B', payTo = 'P'}, server), false)
  helper.assert_equal(x402._private.accepted_requirement_matches(
    {scheme = 'exact', network = 'solana:dev', asset = 'A', payTo = 'Q'}, server), false)
end)

helper.test('matcher: tolerates unknown extra keys on the client side', function()
  local server = {scheme = 'exact', network = 'n', asset = 'a', payTo = 'p', extra = {feePayer = 'f'}}
  local client = {scheme = 'exact', network = 'n', asset = 'a', payTo = 'p',
                  extra = {feePayer = 'f', unexpected = 'drift'}}
  helper.assert_equal(x402._private.accepted_requirement_matches(client, server), true)
end)

helper.test('matcher: server-side canonical extra mismatch returns false', function()
  local server = {scheme = 'exact', network = 'n', asset = 'a', payTo = 'p',
                  extra = {feePayer = 'server_fp'}}
  local client = {scheme = 'exact', network = 'n', asset = 'a', payTo = 'p',
                  extra = {feePayer = 'attacker_fp'}}
  helper.assert_equal(x402._private.accepted_requirement_matches(client, server), false)
end)

-- --- challenge envelope --------------------------------------------

helper.test('exact_challenge envelope shape', function()
  setup()
  local gate = make_gate('0.001')
  local config = pay_kit.config()
  local ch = x402._private.exact_challenge(config, gate, '/paid')
  helper.assert_equal(ch.x402Version, 2)
  helper.assert_equal(ch.resource.type, 'http')
  helper.assert_equal(ch.resource.url, '/paid')
  helper.assert_equal(ch.resource.uri, '/paid')
  helper.assert_equal(#ch.accepts, 1)
  local req = ch.accepts[1]
  helper.assert_equal(req.scheme, 'exact')
  helper.assert_equal(req.network, x402._private.caip2_for('solana_devnet'))
  helper.assert_equal(req.payTo, SELLER)
  helper.assert_equal(req.amount, '1000')                -- 0.001 USDC = 1000 micro
  helper.assert_equal(req.maxAmountRequired, '1000')
  helper.assert_equal(req.maxTimeoutSeconds, 60)
  helper.assert_equal(req.extra.memo, '/paid')
  helper.assert_equal(req.extra.tokenProgram, 'TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA')
end)

helper.test('encode_payment_required is base64 of JSON', function()
  setup()
  local gate = make_gate('0.001')
  local ch = x402._private.exact_challenge(pay_kit.config(), gate, '/paid')
  local encoded = x402._private.encode_payment_required(ch)
  -- Decode and verify roundtrip.
  local base64 = require('pay_kit.util.base64_std')
  local decoded = base64.decode(encoded)
  helper.assert_true(decoded ~= nil)
  local parsed = cjson.decode(decoded)
  helper.assert_equal(parsed.x402Version, 2)
  helper.assert_equal(parsed.accepts[1].payTo, SELLER)
end)

-- --- credential decoding --------------------------------------------

helper.test('decode_payment_signature rejects empty header', function()
  local _, err = x402._private.decode_payment_signature('')
  helper.assert_true(err and err:find('payment required', 1, true), err)
end)

helper.test('decode_payment_signature rejects genuinely-unknown version', function()
  local base64 = require('pay_kit.util.base64_std')
  local encoded = base64.encode(cjson.encode({x402Version = 9}))
  local _, err = x402._private.decode_payment_signature(encoded)
  helper.assert_true(err and err:find('unsupported x402Version', 1, true), err)
end)

helper.test('decode_payment_signature accepts v2 envelope', function()
  local base64 = require('pay_kit.util.base64_std')
  local body = {x402Version = 2, accepted = {}, payload = {}}
  local encoded = base64.encode(cjson.encode(body))
  local env = assert(x402._private.decode_payment_signature(encoded))
  helper.assert_equal(env.x402Version, 2)
end)

-- --- legacy v1 wire shape (inbound credential) ----------------------

helper.test('decode_payment_signature accepts a v1 envelope (scheme + network)', function()
  local base64 = require('pay_kit.util.base64_std')
  local body = {
    x402Version = 1,
    scheme      = 'exact',
    network     = 'solana-devnet',
    transaction = base64.encode('placeholder'),
  }
  local encoded = base64.encode(cjson.encode(body))
  -- With the server's devnet CAIP-2 expectation the legacy string normalizes
  -- back and the credential is accepted (no `accepted` object required).
  local env = assert(x402._private.decode_payment_signature(
    encoded, x402._private.caip2_for('solana_devnet')))
  helper.assert_equal(env.x402Version, 1)
  helper.assert_equal(env.scheme, 'exact')
  helper.assert_equal(env.accepted, nil)
end)

helper.test('decode_payment_signature rejects a v1 envelope with wrong scheme', function()
  local base64 = require('pay_kit.util.base64_std')
  local body = {x402Version = 1, scheme = 'other', network = 'solana'}
  local encoded = base64.encode(cjson.encode(body))
  local _, err = x402._private.decode_payment_signature(encoded)
  helper.assert_true(err and err:find('unsupported payment scheme', 1, true), err)
end)

helper.test('decode_payment_signature rejects a v1 envelope on the wrong network', function()
  local base64 = require('pay_kit.util.base64_std')
  -- "solana" normalizes to mainnet CAIP-2, but the server expects devnet.
  local body = {x402Version = 1, scheme = 'exact', network = 'solana'}
  local encoded = base64.encode(cjson.encode(body))
  local _, err = x402._private.decode_payment_signature(
    encoded, x402._private.caip2_for('solana_devnet'))
  helper.assert_true(err and err:find('wrong network', 1, true), err)
end)

-- --- legacy v1 network string mapping (payment.rs:383) -------------

helper.test('legacy_network_for_requirements maps devnet to solana-devnet', function()
  local fn = x402._private.legacy_network_for_requirements
  helper.assert_equal(fn({cluster = 'devnet'}), 'solana-devnet')
  helper.assert_equal(fn({network = 'solana-devnet'}), 'solana-devnet')
  helper.assert_equal(fn({network = x402._private.caip2_for('solana_devnet')}), 'solana-devnet')
end)

helper.test('legacy_network_for_requirements maps everything else to solana', function()
  local fn = x402._private.legacy_network_for_requirements
  helper.assert_equal(fn({cluster = 'mainnet'}), 'solana')
  helper.assert_equal(fn({cluster = 'localnet'}), 'solana')           -- localnet -> solana
  helper.assert_equal(fn({cluster = 'testnet'}), 'solana')
  helper.assert_equal(fn({network = x402._private.caip2_for('solana_mainnet')}), 'solana')
  -- cluster takes precedence over network when both present.
  helper.assert_equal(fn({cluster = 'devnet', network = 'solana'}), 'solana-devnet')
end)

-- --- legacy v1 producer (build_payment_header_v1) ------------------

helper.test('build_payment_header_v1 emits the X-PAYMENT envelope shape', function()
  local base64 = require('pay_kit.util.base64_std')
  local requirements = {cluster = 'devnet'}
  local proof = {transaction = base64.encode('signed-tx-bytes')}
  local encoded = x402._private.build_payment_header_v1(requirements, proof)
  local env = cjson.decode(base64.decode(encoded))
  helper.assert_equal(env.x402Version, 1)
  helper.assert_equal(env.scheme, 'exact')
  helper.assert_equal(env.network, 'solana-devnet')
  helper.assert_equal(env.accepted, nil)
  helper.assert_equal(env.resource, nil)
  helper.assert_equal(env.transaction, proof.transaction)
end)

helper.test('build_payment_header_v1 flattens a signature proof', function()
  local base64 = require('pay_kit.util.base64_std')
  local encoded = x402._private.build_payment_header_v1(
    {network = 'solana'}, {signature = 'SiGbAsE58'})
  local env = cjson.decode(base64.decode(encoded))
  helper.assert_equal(env.network, 'solana')
  helper.assert_equal(env.signature, 'SiGbAsE58')
  helper.assert_equal(env.transaction, nil)
end)

-- --- legacy v1 challenge parse (flat PaymentRequirements) ----------

helper.test('parse_challenge_header_v1 reads a flat PaymentRequirements (v1 aliases)', function()
  -- Raw JSON, no base64, no accepts[] wrapper. v1 flat aliases:
  -- recipient / currency / maxAmountRequired with a legacy network string.
  local raw = cjson.encode({
    scheme            = 'exact',
    network           = 'solana-devnet',
    recipient         = SELLER,
    maxAmountRequired = '1000',
    currency          = 'MintAddr',
    maxTimeoutSeconds = 60,
  })
  local req = assert(x402._private.parse_challenge_header_v1(raw))
  helper.assert_equal(req.scheme, 'exact')
  helper.assert_equal(req.network, x402._private.caip2_for('solana_devnet'))  -- normalized
  helper.assert_equal(req.recipient, SELLER)
  helper.assert_equal(req.amount, '1000')
  helper.assert_equal(req.currency, 'MintAddr')
  helper.assert_equal(req.maxAge, 60)
  helper.assert_equal(req.accepted, nil)            -- v1 flat yields no accepted
end)

helper.test('parse_payment_requirements retains accepted for the v2 shape', function()
  local req = assert(x402._private.parse_payment_requirements({
    scheme = 'exact',
    network = x402._private.caip2_for('solana_devnet'),
    payTo  = SELLER,
    amount = '1000',
    asset  = 'MintAddr',
  }))
  helper.assert_equal(req.recipient, SELLER)        -- payTo alias
  helper.assert_equal(req.currency, 'MintAddr')     -- asset alias
  helper.assert_true(req.accepted ~= nil)           -- v2 shape retains accepted
end)

-- --- server accepts a v1 credential end-to-end --------------------

helper.test('verify_and_settle accepts a v1 credential past the version gate', function()
  setup()
  local gate = make_gate('0.001')
  local adapter = assert(x402.new({config_resolver = pay_kit.config}))
  local base64 = require('pay_kit.util.base64_std')
  -- A v1 credential carries no `accepted`; the route offer is the sole source
  -- of truth, so the accepted-mismatch path must NOT fire. The flow then
  -- proceeds to proof decoding, where this placeholder fails with a proof
  -- error (not a version / mismatch / scheme error), proving v1 is accepted
  -- through the version + scheme + network gates.
  local cred = {
    x402Version = 1,
    scheme      = 'exact',
    network     = 'solana-devnet',
    transaction = base64.encode('placeholder'),
  }
  local headers = {['x-payment'] = base64.encode(cjson.encode(cred))}
  local _, err = adapter:verify_and_settle(gate, {headers = headers, path = '/paid'})
  helper.assert_true(err ~= nil, 'expected proof error, got success')
  helper.assert_true(not err:find('does not match', 1, true),
    'v1 must skip the accepted-mismatch check: ' .. tostring(err))
  helper.assert_true(not err:find('unsupported x402Version', 1, true),
    'v1 must pass the version gate: ' .. tostring(err))
  helper.assert_true(not err:find('unsupported payment scheme', 1, true),
    'v1 exact scheme must pass: ' .. tostring(err))
end)

helper.test('verify_and_settle rejects a v1 credential on the wrong network', function()
  setup()                                            -- server is devnet
  local gate = make_gate('0.001')
  local adapter = assert(x402.new({config_resolver = pay_kit.config}))
  local base64 = require('pay_kit.util.base64_std')
  local cred = {x402Version = 1, scheme = 'exact', network = 'solana'}  -- mainnet
  local headers = {['x-payment'] = base64.encode(cjson.encode(cred))}
  local _, err = adapter:verify_and_settle(gate, {headers = headers, path = '/paid'})
  helper.assert_true(err and err:find('wrong network', 1, true), tostring(err))
end)

helper.test('detect: returns true for non-empty X-PAYMENT (v1) header', function()
  helper.assert_equal(x402.detect({['x-payment'] = 'abc'}), true)
  helper.assert_equal(x402.detect({['X-PAYMENT'] = 'abc'}), true)
end)

-- --- mismatch flow --------------------------------------------------

helper.test('verify_and_settle rejects unmatched accepted', function()
  setup()
  local gate = make_gate('0.001')
  local adapter = assert(x402.new({config_resolver = pay_kit.config}))
  local base64 = require('pay_kit.util.base64_std')
  -- Network matches the server (so the decode-time network check passes) but
  -- the asset/payTo do not, exercising the accepted-mismatch path.
  local cred = {
    x402Version = 2,
    accepted    = {
      scheme  = 'exact',
      network = x402._private.caip2_for('solana_devnet'),
      asset   = 'wrong',
      payTo   = 'wrong',
    },
    payload     = {transaction = base64.encode('placeholder')},
  }
  local headers = {['payment-signature'] = base64.encode(cjson.encode(cred))}
  local _, err = adapter:verify_and_settle(gate, {headers = headers, path = '/paid'})
  helper.assert_true(err and err:find('does not match server challenge', 1, true), tostring(err))
end)
