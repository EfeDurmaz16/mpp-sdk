-- Session server lifecycle coverage for
-- pay_kit.protocols.mpp.server.session_handler, mirroring
-- rust/crates/mpp/src/server/session.rs::tests.
--
-- Signature-bearing tests use a deterministic luasodium seed keypair and a
-- channel-id-as-pubkey trick so the 48-byte voucher message decodes a real
-- 32-byte channelId. When no Ed25519 backend can sign, those tests skip
-- silently (mirroring tests/pay_kit/ed25519_spec.lua).

local helpers = require('tests.test_helper')
local handler = require('pay_kit.protocols.mpp.server.session_handler')
local session = require('pay_kit.protocols.mpp.session')
local channel_store = require('pay_kit.protocols.mpp.channel_store')
local base58 = require('pay_kit.solana.base58')
local pc = require('pay_kit.solana.payment_channels')

local RECIPIENT = 'CXhrFZJLKqjzmP3sjYLcF4dTeXWKCy9e2SXXZ2Yo6MPY'

local function make_server(overrides)
  local config = {
    operator = RECIPIENT,
    recipient = RECIPIENT,
    max_cap = '10000000',
    currency = 'USDC',
    decimals = 6,
    network = 'localnet',
    modes = { session.MODE_PUSH },
    clock = function() return 1000 end,
  }
  for k, v in pairs(overrides or {}) do config[k] = v end
  return handler.new(config)
end

local function open_push(channel_id, deposit, signer)
  return session.open_push(channel_id, deposit, signer, 'dummy_tx_sig')
end

-- Deterministic signer keyed on a 32-byte seed. Returns nil if the backend
-- cannot produce a Solana 64-byte secret.
local function make_signer(seed_byte)
  local ok, sodium = pcall(require, 'luasodium')
  if not ok or type(sodium.crypto_sign_ed25519_seed_keypair) ~= 'function' then
    return nil
  end
  local seed = string.rep(string.char(seed_byte), 32)
  local pk, sk = sodium.crypto_sign_ed25519_seed_keypair(seed)
  if not pk or not sk then return nil end
  return {
    pubkey_b58 = base58.encode(pk),
    sign = function(message)
      return sodium.crypto_sign_ed25519_detached(message, sk)
    end,
  }
end

-- Build a signed voucher for `channel_id` at the given cumulative.
local function signed_voucher(signer, channel_id, cumulative, expires_at)
  local data = session.voucher_data(channel_id, cumulative, expires_at)
  local message = pc.voucher_message_bytes(channel_id, cumulative, expires_at)
  return { data = data, signature = base58.encode(signer.sign(message)) }
end

-- ── build_challenge_request ──

helpers.test('session_handler: build_challenge_request clamps cap', function()
  local req = make_server():build_challenge_request('50000000')
  helpers.assert_equal(req.cap, '10000000')
end)

helpers.test('session_handler: build_challenge_request below cap', function()
  local req = make_server():build_challenge_request('5000000')
  helpers.assert_equal(req.cap, '5000000')
end)

helpers.test('session_handler: build_challenge_request includes fields', function()
  local req = make_server():build_challenge_request('1000000')
  helpers.assert_equal(req.operator, RECIPIENT)
  helpers.assert_equal(req.recipient, RECIPIENT)
  helpers.assert_equal(req.currency, 'USDC')
  helpers.assert_equal(req.decimals, 6)
  helpers.assert_equal(req.network, 'localnet')
  -- Push-only server omits modes.
  helpers.assert_equal(req.modes, nil)
end)

-- ── process_open ──

helpers.test('session_handler: process_open stores state', function()
  local server = make_server()
  local state = server:process_open(open_push('chan1', '1000000', 'signer1'))
  helpers.assert_equal(state.deposit, '1000000')
  helpers.assert_equal(state.cumulative, '0')
  helpers.assert_equal(state.finalized, false)
  helpers.assert_equal(state.authorized_signer, 'signer1')
end)

helpers.test('session_handler: process_open rejects zero deposit', function()
  helpers.assert_error(function()
    make_server():process_open(open_push('chan1', '0', 'signer1'))
  end, 'greater than zero')
end)

helpers.test('session_handler: process_open rejects deposit over cap', function()
  helpers.assert_error(function()
    make_server():process_open(open_push('chan1', '20000000', 'signer1'))
  end, 'exceeds max cap')
end)

helpers.test('session_handler: process_open at exactly cap is accepted', function()
  local state = make_server():process_open(open_push('chan1', '10000000', 's'))
  helpers.assert_equal(state.deposit, '10000000')
end)

helpers.test('session_handler: process_open rejects unadvertised pull mode', function()
  local server = make_server()
  local payload = session.open_pull('tok', '1000000', 'wallet', 'signer1', 'pending')
  helpers.assert_error(function() server:process_open(payload) end, 'not supported')
end)

-- ── verify_voucher (signature-bearing) ──

helpers.test('session_handler: verify_voucher advances watermark, enforces rules', function()
  local signer = make_signer(7)
  if not signer then return end -- backend cannot sign; skip silently
  local channel_id = base58.encode(string.rep(string.char(11), 32))
  local server = make_server()
  server:process_open(open_push(channel_id, '1000', signer.pubkey_b58))

  local v1 = signed_voucher(signer, channel_id, '100', 5000)
  helpers.assert_equal(server:verify_voucher(session.voucher_action(v1)), '100')

  -- Monotonic: a non-increasing cumulative is rejected.
  helpers.assert_error(function()
    server:verify_voucher(session.voucher_action(signed_voucher(signer, channel_id, '50', 5000)))
  end, 'must exceed watermark')

  -- Cap enforcement: cumulative over deposit is rejected.
  helpers.assert_error(function()
    server:verify_voucher(session.voucher_action(signed_voucher(signer, channel_id, '2000', 5000)))
  end, 'exceeds deposit')

  -- Advance again.
  local v2 = signed_voucher(signer, channel_id, '300', 5000)
  helpers.assert_equal(server:verify_voucher(session.voucher_action(v2)), '300')
end)

helpers.test('session_handler: verify_voucher idempotent replay of same voucher', function()
  local signer = make_signer(8)
  if not signer then return end
  local channel_id = base58.encode(string.rep(string.char(12), 32))
  local server = make_server()
  server:process_open(open_push(channel_id, '1000', signer.pubkey_b58))
  local v = signed_voucher(signer, channel_id, '200', 5000)
  helpers.assert_equal(server:verify_voucher(session.voucher_action(v)), '200')
  helpers.assert_equal(server:verify_voucher(session.voucher_action(v)), '200')
end)

helpers.test('session_handler: verify_voucher rejects forged signature', function()
  local signer = make_signer(9)
  if not signer then return end
  local channel_id = base58.encode(string.rep(string.char(13), 32))
  local server = make_server()
  server:process_open(open_push(channel_id, '1000', signer.pubkey_b58))
  local v = signed_voucher(signer, channel_id, '100', 5000)
  v.signature = base58.encode(string.rep('\0', 64))
  helpers.assert_error(function()
    server:verify_voucher(session.voucher_action(v))
  end, 'signature verification failed')
end)

helpers.test('session_handler: verify_voucher enforces min delta', function()
  local signer = make_signer(10)
  if not signer then return end
  local channel_id = base58.encode(string.rep(string.char(14), 32))
  local server = make_server({ min_voucher_delta = '50' })
  server:process_open(open_push(channel_id, '1000', signer.pubkey_b58))
  helpers.assert_error(function()
    server:verify_voucher(session.voucher_action(signed_voucher(signer, channel_id, '10', 5000)))
  end, 'below minimum')
  helpers.assert_equal(
    server:verify_voucher(session.voucher_action(signed_voucher(signer, channel_id, '60', 5000))),
    '60')
end)

-- ── topup ──

helpers.test('session_handler: process_topup raises the deposit cap', function()
  local server = make_server()
  server:process_open(open_push('chan1', '1000000', 'signer1'))
  local state = server:process_topup(session.topup_action('chan1', '9000000', 'txsig'))
  helpers.assert_equal(state.deposit, '9000000')
end)

helpers.test('session_handler: process_topup rejects a lower deposit', function()
  local server = make_server()
  server:process_open(open_push('chan1', '5000000', 'signer1'))
  helpers.assert_error(function()
    server:process_topup(session.topup_action('chan1', '1000000', 'txsig'))
  end, 'must exceed current deposit')
end)

-- ── metering deliveries + commit idempotency ──

helpers.test('session_handler: begin_delivery reserves capacity', function()
  local server = make_server()
  server:process_open(open_push('chan1', '1000', 'signer1'))
  local directive = server:begin_delivery({ session_id = 'chan1', amount = '100' })
  helpers.assert_equal(directive.sessionId, 'chan1')
  helpers.assert_equal(directive.amount, '100')
  helpers.assert_equal(directive.sequence, 1)
  helpers.assert_error(function()
    server:begin_delivery({ session_id = 'chan1', amount = '901' })
  end, 'exceeds available deposit')
end)

helpers.test('session_handler: process_commit accepts and replays idempotently', function()
  local signer = make_signer(15)
  if not signer then return end
  local channel_id = base58.encode(string.rep(string.char(16), 32))
  local server = make_server()
  server:process_open(open_push(channel_id, '1000', signer.pubkey_b58))
  local directive = server:begin_delivery({ session_id = channel_id, amount = '125' })
  local v = signed_voucher(signer, channel_id, '125', 5000)
  local payload = session.commit_action(directive.deliveryId, v)

  local receipt = server:process_commit(payload)
  helpers.assert_equal(receipt.deliveryId, directive.deliveryId)
  helpers.assert_equal(receipt.amount, '125')
  helpers.assert_equal(receipt.cumulative, '125')
  helpers.assert_equal(receipt.status, session.COMMIT_STATUS_COMMITTED)

  local replay = server:process_commit(payload)
  helpers.assert_equal(replay.status, session.COMMIT_STATUS_REPLAYED)
  helpers.assert_equal(replay.cumulative, '125')
end)

helpers.test('session_handler: process_commit accepts partial stream usage', function()
  local signer = make_signer(17)
  if not signer then return end
  local channel_id = base58.encode(string.rep(string.char(18), 32))
  local server = make_server()
  server:process_open(open_push(channel_id, '1000', signer.pubkey_b58))
  local directive = server:begin_delivery({ session_id = channel_id, amount = '125' })
  local v = signed_voucher(signer, channel_id, '75', 5000)
  local receipt = server:process_commit(session.commit_action(directive.deliveryId, v))
  helpers.assert_equal(receipt.amount, '75')
  helpers.assert_equal(receipt.cumulative, '75')
end)

helpers.test('session_handler: process_commit rejects over-reserved cumulative', function()
  local signer = make_signer(19)
  if not signer then return end
  local channel_id = base58.encode(string.rep(string.char(20), 32))
  local server = make_server()
  server:process_open(open_push(channel_id, '1000', signer.pubkey_b58))
  local directive = server:begin_delivery({ session_id = channel_id, amount = '125' })
  local v = signed_voucher(signer, channel_id, '200', 5000)
  helpers.assert_error(function()
    server:process_commit(session.commit_action(directive.deliveryId, v))
  end, 'exceeds reserved amount')
end)

-- ── close + finalize ──

helpers.test('session_handler: process_close sets close-pending and returns finalize params', function()
  local server = make_server()
  server:process_open(open_push('chan1', '1000000', 'signer1'))
  local params = server:process_close(session.close_action('chan1'))
  helpers.assert_equal(params.channel_id, 'chan1')
  helpers.assert_equal(params.settled, '0')
  helpers.assert_equal(params.recipient, RECIPIENT)
  helpers.assert_equal(#params.distribution_hash, 32)
  -- A second close is rejected (already close-pending).
  helpers.assert_error(function()
    server:process_close(session.close_action('chan1'))
  end, 'already requested')
end)

helpers.test('session_handler: finalize_params carries the blake3 distribution hash', function()
  local split_pk = base58.encode(string.rep(string.char(3), 32))
  local server = make_server({ splits = { { recipient = split_pk, bps = 1000 } } })
  server:process_open(open_push('chan1', '1000000', 'signer1'))
  local params = server:finalize_params('chan1')
  helpers.assert_equal(params.distribution_hash, pc.distribution_hash({ { recipient = split_pk, bps = 1000 } }))
end)

helpers.test('session_handler: mark_finalized flips finalized flag', function()
  local server = make_server()
  server:process_open(open_push('chan1', '1000000', 'signer1'))
  server:mark_finalized('chan1')
  local store = channel_store.memory()
  store:put_channel('x', channel_store.new_state({ channel_id = 'x', authorized_signer = 's', deposit = '1' }))
  helpers.assert_equal(store:mark_finalized('x').finalized, true)
end)
