--[[
Channel store for the MPP session intent.

This is the richer, stateful store the session lifecycle needs. It is NOT
the charge replay store (`pay_kit.protocols.mpp.store`), which only does
put-if-absent on a signature key. Session tracks a full per-channel state
with an atomic read-modify-write so the settled watermark cannot be advanced
twice under concurrent vouchers.

Mirrors the Rust spine's `ChannelStore` / `ChannelState` in
`rust/crates/mpp/src/store.rs`:

  ChannelState fields:
    channel_id, authorized_signer, deposit, cumulative, finalized,
    highest_voucher_signature, highest_voucher_expires_at,
    close_requested_at, operator, next_delivery_sequence,
    pending_deliveries[], committed_deliveries[]

The Lua runtime here is single-threaded inside an Nginx worker, so
`update_channel` is atomic by virtue of running to completion without
yielding. The updater closure receives the current state (or nil) and must
return the new state or raise.
]]

local M = {}

local ChannelStore = {}
ChannelStore.__index = ChannelStore

function M.memory()
  return setmetatable({ data = {} }, ChannelStore)
end

-- Deep copy of a channel-state table so callers cannot mutate stored state
-- by reference between calls. State carries nested delivery arrays.
local function clone_state(state)
  if state == nil then return nil end
  local out = {}
  for k, v in pairs(state) do
    if k == 'pending_deliveries' or k == 'committed_deliveries' then
      local arr = {}
      for i = 1, #v do
        local entry = {}
        for ek, ev in pairs(v[i]) do entry[ek] = ev end
        arr[i] = entry
      end
      out[k] = arr
    else
      out[k] = v
    end
  end
  return out
end

M.clone_state = clone_state

--- Build a fresh ChannelState with the session defaults.
function M.new_state(opts)
  return {
    channel_id = opts.channel_id,
    authorized_signer = opts.authorized_signer,
    deposit = opts.deposit, -- decimal string (u64)
    cumulative = '0',
    finalized = false,
    highest_voucher_signature = opts.highest_voucher_signature,
    highest_voucher_expires_at = opts.highest_voucher_expires_at,
    close_requested_at = opts.close_requested_at,
    operator = opts.operator,
    next_delivery_sequence = 0,
    pending_deliveries = {},
    committed_deliveries = {},
  }
end

function ChannelStore:get_channel(channel_id)
  return clone_state(self.data[channel_id])
end

function ChannelStore:put_channel(channel_id, state)
  self.data[channel_id] = clone_state(state)
end

--- Atomic read-modify-write. `updater(state_or_nil)` returns the new state
--- or raises. Returns the newly-stored state (a clone).
function ChannelStore:update_channel(channel_id, updater)
  local current = clone_state(self.data[channel_id])
  local new_state = updater(current)
  if type(new_state) ~= 'table' then
    error('update_channel updater must return a state table')
  end
  self.data[channel_id] = clone_state(new_state)
  return clone_state(new_state)
end

function ChannelStore:mark_finalized(channel_id)
  return self:update_channel(channel_id, function(state)
    if state == nil then
      error('Channel ' .. tostring(channel_id) .. ' not found')
    end
    state.finalized = true
    return state
  end)
end

M.ChannelStore = ChannelStore

return M
