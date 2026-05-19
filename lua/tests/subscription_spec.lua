local t = require('tests.test_helper')
local subscription = require('mpp.protocol.intents.subscription')

t.test('subscription request serializes recurring fields', function()
  local request = subscription.new_request({
    amount = '1000',
    currency = 'USDC',
    periodUnit = subscription.PERIOD_MONTH,
    periodCount = '1',
    recipient = 'recipient',
    subscriptionExpires = '2027-01-01T00:00:00+00:00',
    description = 'Monthly API access',
    externalId = 'sub-001',
    methodDetails = { network = 'devnet' },
  })

  t.assert_equal(request.amount, '1000')
  t.assert_equal(request.currency, 'USDC')
  t.assert_equal(request.periodUnit, 'month')
  t.assert_equal(request.periodCount, '1')
  t.assert_equal(request.methodDetails.network, 'devnet')
end)

t.test('subscription request rejects unsupported period unit', function()
  t.assert_error(function()
    subscription.new_request({
      amount = '1000',
      currency = 'USDC',
      periodUnit = 'year',
      periodCount = '1',
    })
  end, 'unsupported periodUnit')
end)

t.test('subscription receipt serializes charged period', function()
  local receipt = subscription.new_receipt({
    subscriptionId = 'subscription',
    amount = '1000',
    currency = 'USDC',
    periodStart = 1770000000,
    periodEnd = 1772678400,
    reference = 'tx-signature',
    externalId = 'sub-001',
  })

  t.assert_equal(receipt.subscriptionId, 'subscription')
  t.assert_equal(receipt.reference, 'tx-signature')
  t.assert_equal(receipt.periodEnd, 1772678400)
end)

t.test('subscription account state rejects duplicate period charges', function()
  local state = subscription.new_account_state({
    subscriptionId = 'subscription',
    status = subscription.STATUS_ACTIVE,
    currentPeriod = 2,
    chargedPeriods = { 1 },
  })

  t.assert_true(subscription.can_charge_period(state, 2))
  subscription.record_period_charge(state, 2)
  t.assert_true(not subscription.can_charge_period(state, 2))
  t.assert_error(function()
    subscription.record_period_charge(state, 2)
  end, 'subscription period cannot be charged')
end)

t.test('subscription account state does not accumulate missed periods', function()
  local state = subscription.new_account_state({
    subscriptionId = 'subscription',
    status = subscription.STATUS_ACTIVE,
    currentPeriod = 3,
    chargedPeriods = {},
  })

  t.assert_true(subscription.can_charge_period(state, 3))
  t.assert_true(not subscription.can_charge_period(state, 4))
end)
