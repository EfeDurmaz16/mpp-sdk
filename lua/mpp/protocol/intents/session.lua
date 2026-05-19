local M = {
  MODE_PUSH = 'push',
  MODE_PULL = 'pull',
  PULL_CLIENT_VOUCHER = 'clientVoucher',
  PULL_OPERATED_VOUCHER = 'operatedVoucher',
  DEFAULT_EXPIRES_AT = 4102444800,
  STATUS_COMMITTED = 'committed',
  STATUS_REPLAYED = 'replayed',
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

function M.normalize_mode(mode)
  if mode == M.MODE_PUSH or mode == M.MODE_PULL then
    return mode
  end
  error('unsupported session mode: ' .. tostring(mode))
end

function M.normalize_pull_voucher_strategy(strategy)
  if strategy == M.PULL_CLIENT_VOUCHER or strategy == M.PULL_OPERATED_VOUCHER then
    return strategy
  end
  error('unsupported pullVoucherStrategy: ' .. tostring(strategy))
end

function M.new_split(value)
  value = value or {}
  assert_required(value.recipient, 'split recipient')
  if type(value.bps) ~= 'number' or value.bps <= 0 or value.bps > 10000 or value.bps % 1 ~= 0 then
    error('split bps must be between 1 and 10000')
  end
  return {
    recipient = value.recipient,
    bps = value.bps,
  }
end

function M.new_request(value)
  value = value or {}
  assert_positive_decimal(value.cap, 'cap')
  assert_required(value.currency, 'currency')
  assert_required(value.operator, 'operator')
  assert_required(value.recipient, 'recipient')
  if value.decimals ~= nil and (type(value.decimals) ~= 'number' or value.decimals < 0 or value.decimals > 255 or value.decimals % 1 ~= 0) then
    error('decimals must be between 0 and 255')
  end
  if value.minVoucherDelta ~= nil and value.minVoucherDelta ~= '' then
    assert_positive_decimal(value.minVoucherDelta, 'minVoucherDelta')
  end

  local request = {
    cap = value.cap,
    currency = value.currency,
    operator = value.operator,
    recipient = value.recipient,
  }
  if value.decimals ~= nil then
    request.decimals = value.decimals
  end
  copy_optional(value, request, {
    'network',
    'programId',
    'description',
    'externalId',
    'minVoucherDelta',
    'recentBlockhash',
  })

  if value.splits ~= nil then
    if type(value.splits) ~= 'table' then
      error('splits must be an array')
    end
    request.splits = {}
    for i, split in ipairs(value.splits) do
      request.splits[i] = M.new_split(split)
    end
  end

  if value.modes ~= nil then
    if type(value.modes) ~= 'table' then
      error('modes must be an array')
    end
    request.modes = {}
    local has_pull = false
    for i, mode in ipairs(value.modes) do
      request.modes[i] = M.normalize_mode(mode)
      has_pull = has_pull or mode == M.MODE_PULL
    end
    if has_pull and value.pullVoucherStrategy == nil then
      error('pullVoucherStrategy is required when pull mode is advertised')
    end
  end

  if value.pullVoucherStrategy ~= nil then
    request.pullVoucherStrategy = M.normalize_pull_voucher_strategy(value.pullVoucherStrategy)
  end

  return request
end

function M.new_voucher_data(value)
  value = value or {}
  assert_required(value.channelId, 'channelId')
  assert_positive_decimal(value.cumulativeAmount, 'cumulativeAmount')
  local expires_at = value.expiresAt or M.DEFAULT_EXPIRES_AT
  if type(expires_at) ~= 'number' or expires_at <= 0 or expires_at % 1 ~= 0 then
    error('expiresAt must be positive')
  end
  if value.nonce ~= nil and (type(value.nonce) ~= 'number' or value.nonce < 0 or value.nonce % 1 ~= 0) then
    error('nonce cannot be negative')
  end
  local data = {
    channelId = value.channelId,
    cumulativeAmount = value.cumulativeAmount,
    expiresAt = expires_at,
  }
  if value.nonce ~= nil then
    data.nonce = value.nonce
  end
  return data
end

function M.new_signed_voucher(value)
  value = value or {}
  local data = M.new_voucher_data(value.data)
  assert_required(value.signature, 'signature')
  return {
    data = data,
    signature = value.signature,
  }
end

function M.new_metering_directive(value)
  value = value or {}
  assert_required(value.deliveryId, 'deliveryId')
  assert_required(value.sessionId, 'sessionId')
  assert_positive_decimal(value.amount, 'amount')
  assert_required(value.currency, 'currency')
  if type(value.sequence) ~= 'number' or value.sequence < 0 or value.sequence % 1 ~= 0 then
    error('sequence cannot be negative')
  end
  if type(value.expiresAt) ~= 'number' or value.expiresAt <= 0 or value.expiresAt % 1 ~= 0 then
    error('expiresAt must be positive')
  end
  local directive = {
    deliveryId = value.deliveryId,
    sessionId = value.sessionId,
    amount = value.amount,
    currency = value.currency,
    sequence = value.sequence,
    expiresAt = value.expiresAt,
  }
  copy_optional(value, directive, { 'commitUrl', 'proof' })
  return directive
end

function M.new_commit_receipt(value)
  value = value or {}
  assert_required(value.deliveryId, 'deliveryId')
  assert_required(value.sessionId, 'sessionId')
  assert_positive_decimal(value.amount, 'amount')
  assert_positive_decimal(value.cumulative, 'cumulative')
  if value.status ~= M.STATUS_COMMITTED and value.status ~= M.STATUS_REPLAYED then
    error('status must be committed or replayed')
  end
  return {
    deliveryId = value.deliveryId,
    sessionId = value.sessionId,
    amount = value.amount,
    cumulative = value.cumulative,
    status = value.status,
  }
end

return M
