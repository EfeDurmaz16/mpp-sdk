local t = require('tests.test_helper')
local session = require('mpp.protocol.intents.session')

t.test('session request serializes shared wire fields', function()
  local request = session.new_request({
    cap = '1000000',
    currency = 'USDC',
    operator = 'operator',
    recipient = 'recipient',
    decimals = 6,
    network = 'devnet',
    splits = {
      { recipient = 'affiliate', bps = 250 },
    },
    programId = 'program',
    description = 'Metered API session',
    externalId = 'session-001',
    minVoucherDelta = '1000',
    modes = { session.MODE_PUSH, session.MODE_PULL },
    pullVoucherStrategy = session.PULL_CLIENT_VOUCHER,
    recentBlockhash = 'blockhash',
  })

  t.assert_equal(request.cap, '1000000')
  t.assert_equal(request.currency, 'USDC')
  t.assert_equal(request.splits[1].recipient, 'affiliate')
  t.assert_equal(request.splits[1].bps, 250)
  t.assert_equal(request.modes[2], 'pull')
  t.assert_equal(request.pullVoucherStrategy, 'clientVoucher')
end)

t.test('session request requires pull voucher strategy for pull mode', function()
  t.assert_error(function()
    session.new_request({
      cap = '1000',
      currency = 'USDC',
      operator = 'operator',
      recipient = 'recipient',
      modes = { session.MODE_PULL },
    })
  end, 'pullVoucherStrategy is required')
end)

t.test('signed voucher serializes cumulative voucher', function()
  local voucher = session.new_signed_voucher({
    data = {
      channelId = 'channel',
      cumulativeAmount = '25000',
      expiresAt = session.DEFAULT_EXPIRES_AT,
      nonce = 1,
    },
    signature = 'signature',
  })

  t.assert_equal(voucher.data.channelId, 'channel')
  t.assert_equal(voucher.data.cumulativeAmount, '25000')
  t.assert_equal(voucher.data.expiresAt, 4102444800)
  t.assert_equal(voucher.signature, 'signature')
end)

t.test('metering directive serializes commit fields', function()
  local directive = session.new_metering_directive({
    deliveryId = 'delivery-001',
    sessionId = 'channel',
    amount = '5000',
    currency = 'USDC',
    sequence = 1,
    expiresAt = session.DEFAULT_EXPIRES_AT,
    commitUrl = 'https://merchant.example/session/commit',
    proof = 'proof',
  })

  t.assert_equal(directive.deliveryId, 'delivery-001')
  t.assert_equal(directive.sessionId, 'channel')
  t.assert_equal(directive.commitUrl, 'https://merchant.example/session/commit')
end)

t.test('commit receipt rejects unknown status', function()
  t.assert_error(function()
    session.new_commit_receipt({
      deliveryId = 'delivery-001',
      sessionId = 'channel',
      amount = '5000',
      cumulative = '30000',
      status = 'accepted',
    })
  end, 'status must be committed or replayed')
end)
