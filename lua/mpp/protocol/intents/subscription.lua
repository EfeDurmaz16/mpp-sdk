local M = {
  PERIOD_DAY = 'day',
  PERIOD_WEEK = 'week',
  PERIOD_MONTH = 'month',
  STATUS_ACTIVE = 'active',
  STATUS_EXPIRED = 'expired',
  STATUS_CANCELED = 'canceled',
}

local function assert_required(value, field)
  if type(value) ~= 'string' or value == '' then
    error(field .. ' is required')
  end
end

local function assert_positive_decimal(value, field)
  if type(value) ~= 'string' or not value:match('^[1-9]%d*$') then
    error('invalid ' .. field .. ': ' .. tostring(value))
  end
end

local function copy_optional(source, target, fields)
  for _, field in ipairs(fields) do
    if source[field] ~= nil and source[field] ~= '' then
      target[field] = source[field]
    end
  end
end

function M.normalize_period_unit(period_unit)
  if period_unit == M.PERIOD_DAY or period_unit == M.PERIOD_WEEK or period_unit == M.PERIOD_MONTH then
    return period_unit
  end
  error('unsupported periodUnit: ' .. tostring(period_unit))
end

function M.new_request(value)
  value = value or {}
  assert_positive_decimal(value.amount, 'amount')
  assert_required(value.currency, 'currency')
  local period_unit = M.normalize_period_unit(value.periodUnit)
  assert_positive_decimal(value.periodCount, 'periodCount')
  if value.methodDetails ~= nil and type(value.methodDetails) ~= 'table' then
    error('methodDetails must be an object')
  end

  local request = {
    amount = value.amount,
    currency = value.currency,
    periodUnit = period_unit,
    periodCount = value.periodCount,
  }
  copy_optional(value, request, {
    'recipient',
    'subscriptionExpires',
    'description',
    'externalId',
  })
  if value.methodDetails ~= nil then
    request.methodDetails = value.methodDetails
  end
  return request
end

function M.new_receipt(value)
  value = value or {}
  assert_required(value.subscriptionId, 'subscriptionId')
  assert_positive_decimal(value.amount, 'amount')
  assert_required(value.currency, 'currency')
  if type(value.periodStart) ~= 'number' or value.periodStart <= 0 or value.periodStart % 1 ~= 0 then
    error('periodStart must be a positive epoch second')
  end
  if type(value.periodEnd) ~= 'number' or value.periodEnd <= value.periodStart or value.periodEnd % 1 ~= 0 then
    error('periodEnd must be after periodStart')
  end
  local receipt = {
    subscriptionId = value.subscriptionId,
    amount = value.amount,
    currency = value.currency,
    periodStart = value.periodStart,
    periodEnd = value.periodEnd,
  }
  copy_optional(value, receipt, { 'reference', 'externalId' })
  return receipt
end

function M.new_account_state(value)
  value = value or {}
  assert_required(value.subscriptionId, 'subscriptionId')
  if value.status ~= M.STATUS_ACTIVE and value.status ~= M.STATUS_EXPIRED and value.status ~= M.STATUS_CANCELED then
    error('unsupported subscription status: ' .. tostring(value.status))
  end
  if type(value.currentPeriod) ~= 'number' or value.currentPeriod < 0 or value.currentPeriod % 1 ~= 0 then
    error('currentPeriod cannot be negative')
  end
  local state = {
    subscriptionId = value.subscriptionId,
    status = value.status,
    currentPeriod = value.currentPeriod,
    chargedPeriods = {},
  }
  for _, period in ipairs(value.chargedPeriods or {}) do
    if type(period) ~= 'number' or period < 0 or period % 1 ~= 0 then
      error('chargedPeriods must contain non-negative integers')
    end
    state.chargedPeriods[period] = true
  end
  return state
end

function M.can_charge_period(state, period)
  if state.status ~= M.STATUS_ACTIVE then
    return false
  end
  if type(period) ~= 'number' or period < 0 or period % 1 ~= 0 then
    error('period must be a non-negative integer')
  end
  if period > state.currentPeriod then
    return false
  end
  return state.chargedPeriods[period] ~= true
end

function M.record_period_charge(state, period)
  if not M.can_charge_period(state, period) then
    error('subscription period cannot be charged')
  end
  state.chargedPeriods[period] = true
  return state
end

return M
