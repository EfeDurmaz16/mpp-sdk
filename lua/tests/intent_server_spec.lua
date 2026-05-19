local t = require('tests.test_helper')
local mpp = require('mpp')
local session = require('mpp.protocol.intents.session')
local subscription = require('mpp.protocol.intents.subscription')

local function new_server()
  return mpp.server.new({
    recipient = 'recipient',
    currency = 'USDC',
    decimals = 6,
    network = 'localnet',
    secret_key = 'test-secret',
    store = mpp.store.memory(),
    verify_session = function(context)
      t.assert_equal(context.request.externalId, 'session-001')
      t.assert_equal(context.payload.signature, 'sig')
      return { reference = 'channel-id' }
    end,
    verify_subscription = function(context)
      t.assert_equal(context.request.externalId, 'subscription-001')
      t.assert_equal(context.payload.signature, 'sig')
      return { reference = 'subscription-id' }
    end,
  })
end

t.test('server session challenge verifies through callback', function()
  local server = new_server()
  local challenge = server:session_with_options({
    cap = '1000000',
    operator = 'operator',
    external_id = 'session-001',
    modes = { session.MODE_PUSH },
  })
  local request = challenge.request:decode()
  t.assert_equal(challenge.intent, 'session')
  t.assert_equal(request.cap, '1000000')

  local credential = mpp.NewPaymentCredential(challenge:to_echo(), {
    type = 'session-open',
    signature = 'sig',
  })
  local receipt = server:verify_session_credential(credential, 1770000000)
  t.assert_equal(receipt.reference, 'channel-id')
  t.assert_equal(receipt.challengeId, challenge.id)
end)

t.test('server session verifier rejects wrong intent', function()
  local server = new_server()
  local challenge = server:charge('0.001')
  local credential = mpp.NewPaymentCredential(challenge:to_echo(), {
    type = 'session-open',
    signature = 'sig',
  })

  t.assert_error(function()
    server:verify_session_credential(credential, 1770000000)
  end, 'expected')
end)

t.test('server subscription challenge verifies through callback', function()
  local server = new_server()
  local challenge = server:subscription_with_options({
    amount = '1000',
    period_unit = subscription.PERIOD_MONTH,
    period_count = '1',
    external_id = 'subscription-001',
  })
  local request = challenge.request:decode()
  t.assert_equal(challenge.intent, 'subscription')
  t.assert_equal(request.periodUnit, 'month')

  local credential = mpp.NewPaymentCredential(challenge:to_echo(), {
    type = 'subscription-activation',
    signature = 'sig',
  })
  local receipt = server:verify_subscription_credential(credential, 1770000000)
  t.assert_equal(receipt.reference, 'subscription-id')
  t.assert_equal(receipt.challengeId, challenge.id)
end)

t.test('server subscription verifier requires callback', function()
  local server = mpp.server.new({
    recipient = 'recipient',
    currency = 'USDC',
    secret_key = 'test-secret',
  })
  local challenge = server:subscription_with_options({
    amount = '1000',
    period_unit = subscription.PERIOD_MONTH,
    period_count = '1',
  })
  local credential = mpp.NewPaymentCredential(challenge:to_echo(), {
    type = 'subscription-activation',
    signature = 'sig',
  })

  t.assert_error(function()
    server:verify_subscription_credential(credential, 1770000000)
  end, 'verify_subscription callback is required')
end)
