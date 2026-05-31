-- Wire-shape parity for pay_kit.protocols.mpp.session.
-- Mirrors rust/crates/mpp/src/protocol/intents/session.rs::tests.

local helpers = require('tests.test_helper')
local session = require('pay_kit.protocols.mpp.session')
local json = require('pay_kit.util.json')

-- ── Defaults ──

helpers.test('session: DEFAULT_SESSION_EXPIRES_AT is 2100-01-01 UTC', function()
  helpers.assert_equal(session.DEFAULT_SESSION_EXPIRES_AT, 4102444800)
end)

-- ── salt: string out, string-or-number in ──

helpers.test('session: encode_salt always emits a decimal string', function()
  helpers.assert_equal(session.encode_salt(99), '99')
  helpers.assert_equal(session.encode_salt('18446744073709551608'), '18446744073709551608')
  helpers.assert_equal(session.encode_salt(nil), nil)
end)

helpers.test('session: decode_salt accepts number and string', function()
  helpers.assert_equal(session.decode_salt(42), '42')
  helpers.assert_equal(session.decode_salt('42'), '42')
  helpers.assert_equal(session.decode_salt('18446744073709551608'), '18446744073709551608')
end)

helpers.test('session: open_payment_channel serializes salt as a string', function()
  local p = session.open_payment_channel({
    channel_id = 'chan1', deposit = '1000000', payer = 'payer1', payee = 'payee1',
    mint = 'mint1', salt = 99, grace_period = 900,
    authorized_signer = 'signer1', signature = 'txsig',
  })
  helpers.assert_equal(p.salt, '99')
  local encoded = json.encode(p)
  helpers.assert_true(encoded:find('"salt":"99"', 1, true) ~= nil, 'salt must encode as a string')
end)

-- ── cumulativeAmount wire name + cumulative read alias ──

helpers.test('session: voucher_data emits cumulativeAmount', function()
  local data = session.voucher_data('chan1', 500000, 42, 3)
  helpers.assert_equal(data.cumulativeAmount, '500000')
  helpers.assert_equal(data.cumulative, nil)
  helpers.assert_equal(data.nonce, 3)
end)

helpers.test('session: voucher_cumulative reads cumulativeAmount', function()
  helpers.assert_equal(session.voucher_cumulative({ cumulativeAmount = '500000' }), '500000')
end)

helpers.test('session: voucher_cumulative accepts the cumulative alias', function()
  helpers.assert_equal(session.voucher_cumulative({ cumulative = '700' }), '700')
end)

-- ── action tag: topUp (capital U) ──

helpers.test('session: topup_action uses the topUp wire tag', function()
  local a = session.topup_action('chan1', '9000000', 'txsig')
  helpers.assert_equal(a.action, 'topUp')
  helpers.assert_equal(a.newDeposit, '9000000')
end)

helpers.test('session: voucher/commit/close action tags', function()
  helpers.assert_equal(session.voucher_action({}).action, 'voucher')
  helpers.assert_equal(session.commit_action('d1', {}).action, 'commit')
  helpers.assert_equal(session.commit_action('d1', {}).deliveryId, 'd1')
  helpers.assert_equal(session.close_action('chan1').action, 'close')
end)

helpers.test('session: close_action omits voucher when absent', function()
  local a = session.close_action('chan1')
  helpers.assert_equal(a.voucher, nil)
  local b = session.close_action('chan1', { signature = 's' })
  helpers.assert_true(b.voucher ~= nil, 'voucher present when provided')
end)

-- ── session_id + deposit_amount ──

helpers.test('session: session_id returns channelId for push', function()
  local p = session.open_push('chan123', '5000000', 'signer1', 'sig456')
  helpers.assert_equal(session.session_id(p), 'chan123')
  helpers.assert_equal(session.deposit_amount(p), '5000000')
end)

helpers.test('session: session_id returns tokenAccount for pull-no-channel', function()
  local p = session.open_pull('tokacct', '3000000', 'wallet1', 'signer1', 'approvesig')
  helpers.assert_equal(session.session_id(p), 'tokacct')
  helpers.assert_equal(session.deposit_amount(p), '3000000')
end)

helpers.test('session: deposit_amount rejects non-numeric', function()
  helpers.assert_error(function()
    session.deposit_amount(session.open_push('c', 'bad', 's', 'sig'))
  end, 'invalid deposit amount')
end)

-- ── SessionRequest omission rules ──

helpers.test('session_request: omits empty splits/modes and nil optionals', function()
  local req = session.session_request({
    cap = '1000', currency = 'USDC', operator = 'op', recipient = 'rec',
  })
  helpers.assert_equal(req.cap, '1000')
  helpers.assert_equal(req.splits, nil)
  helpers.assert_equal(req.modes, nil)
  helpers.assert_equal(req.decimals, nil)
  helpers.assert_equal(req.minVoucherDelta, nil)
end)

helpers.test('session_request: keeps modes and pullVoucherStrategy when set', function()
  local req = session.session_request({
    cap = '1000', currency = 'USDC', operator = 'op', recipient = 'rec',
    modes = { session.MODE_PUSH, session.MODE_PULL },
    pull_voucher_strategy = session.PULL_STRATEGY_CLIENT_VOUCHER,
    min_voucher_delta = 500,
  })
  helpers.assert_equal(#req.modes, 2)
  helpers.assert_equal(req.pullVoucherStrategy, 'clientVoucher')
  helpers.assert_equal(req.minVoucherDelta, '500')
end)
