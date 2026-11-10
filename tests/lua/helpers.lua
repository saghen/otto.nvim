-- What specs share: checks, which the runner reports, and fixtures of agents without their processes

local M = { failures = {}, skipped = {}, checks = 0 }

local scopes = {}

--- @param got any
--- @param want any
--- @param path? string
--- @return string? where they first differ
local function first_diff(got, want, path)
  path = path or ''
  if type(got) ~= 'table' or type(want) ~= 'table' then
    if vim.deep_equal(got, want) then return nil end
    local function show(value) return vim.inspect(value, { newline = ' ', indent = '' }) end
    return ('%s got %s, want %s'):format(path == '' and '' or path .. ':', show(got), show(want))
  end
  local keys = {}
  for key in pairs(got) do
    keys[key] = true
  end
  for key in pairs(want) do
    keys[key] = true
  end
  local sorted = vim.tbl_keys(keys)
  table.sort(sorted, function(a, b) return tostring(a) < tostring(b) end)
  for _, key in ipairs(sorted) do
    local diff = first_diff(got[key], want[key], ('%s[%s]'):format(path, vim.inspect(key)))
    if diff then return diff end
  end
end

--- @param name string
--- @param message string
function M.fail(name, message)
  local where = vim.list_extend({ M.spec }, scopes)
  table.insert(where, name)
  table.insert(M.failures, table.concat(where, ' > ') .. ': ' .. message)
end

--- @param name string
--- @param got any
--- @param want any
function M.check(name, got, want)
  M.checks = M.checks + 1
  local diff = first_diff(got, want)
  if diff then M.fail(name, vim.trim(diff)) end
end

--- Checks that `text` matches the Lua pattern
--- @param name string
--- @param text any
--- @param pattern string
function M.match(name, text, pattern)
  M.checks = M.checks + 1
  if type(text) ~= 'string' or not text:match(pattern) then
    M.fail(name, ('%s does not match %s'):format(vim.inspect(text), vim.inspect(pattern)))
  end
end

--- Names the checks inside `fn`, and reports its error as a failure
--- @param name string
--- @param fn fun()
function M.describe(name, fn)
  table.insert(scopes, name)
  local ok, err = xpcall(fn, debug.traceback)
  if not ok then M.fail('error', err) end
  table.remove(scopes)
end

--- @param events otto.Event[]
--- @param fields string[]
--- @return otto.Event[] copies without the fields
function M.without(events, fields)
  return vim.tbl_map(function(event)
    local copy = vim.deepcopy(event)
    for _, field in ipairs(fields) do
      copy[field] = nil
    end
    return copy
  end, events)
end

--- A log that collects what it emits
--- @return otto.Log log
--- @return otto.Event[] events
--- @return otto.StatePatch[] patches
function M.log()
  local events, patches = {}, {}
  local log = require('otto.providers.log').new(
    function(event) table.insert(events, event) end,
    function(patch) table.insert(patches, patch) end
  )
  return log, events, patches
end

--- @param id string
--- @param tool string
--- @param args table
--- @param at? integer
--- @return otto.Event tool_call
function M.call(id, tool, args, at) return { type = 'tool_call', id = id, tool = tool, args = args, at = at or 0 } end

--- @param id string
--- @param fields? table Over a result that succeeded without output
--- @return otto.Event tool_result
function M.result(id, fields)
  return vim.tbl_extend('force', { type = 'tool_result', id = id, ok = true, output = '', at = 0 }, fields or {})
end

--- Blocks of the layout for the events, and `turn_end` for its ops of that kind
--- @param events otto.Event[]
--- @return (otto.Block | 'turn_end')[]
function M.layout(events)
  local layout = require('otto.render.layout').new()
  local out = {}
  for _, event in ipairs(events) do
    for _, op in ipairs(layout:add(event)) do
      table.insert(out, op.type == 'block' and op.block or op.type)
    end
  end
  return out
end

--- A prompt buffer like a session's, current in the current window
--- @param lines string[]
--- @param input_row integer 0-indexed
--- @return integer bufnr
function M.scratch(lines, input_row)
  local bufnr = vim.api.nvim_create_buf(false, true)
  -- which have the input's mark
  vim.bo[bufnr].buftype = 'prompt'
  vim.fn.prompt_setprompt(bufnr, '')
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_buf_set_mark(bufnr, ':', input_row + 1, 0, {})
  vim.api.nvim_set_current_buf(bufnr)
  return bufnr
end

--- Renders the events into a new transcript of the buffer
--- @param bufnr integer
--- @param events otto.Event[]
--- @param on_change? fun()
--- @return otto.Transcript
function M.render(bufnr, events, on_change)
  local transcript = require('otto.render.transcript').new(bufnr, on_change or function() end)
  local layout = require('otto.render.layout').new()
  for _, event in ipairs(events) do
    for _, op in ipairs(layout:add(event)) do
      transcript:apply(op)
    end
  end
  return transcript
end

--- @param bufnr integer
--- @return string[]
function M.lines(bufnr) return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false) end

--- Runs `fn`, collecting what it notifies
--- @param fn fun()
--- @return string[]
function M.notified(fn)
  local messages = {}
  local notify = vim.notify
  vim.notify = function(message) table.insert(messages, message) end
  local ok, err = pcall(fn)
  vim.notify = notify
  assert(ok, err)
  return messages
end

--- Notes a spec that didn't run, like one that needs blink.lib, which the runner reports
--- @param reason string
function M.skip(reason) table.insert(M.skipped, M.spec .. ': ' .. reason) end

--- Runs `fn` with `vim.ui.select` answering with the item at `choice`, or cancelling without one
--- @param choice? integer
--- @param fn fun()
--- @return { items: any[], labels: string[], prompt: string }? What it was asked to pick from
function M.selecting(choice, fn)
  local asked
  local select = vim.ui.select
  vim.ui.select = function(items, opts, on_choice)
    local format = opts.format_item or tostring
    asked = { items = items, labels = vim.tbl_map(format, items), prompt = opts.prompt }
    on_choice(choice and items[choice], choice)
  end
  local ok, err = pcall(fn)
  vim.ui.select = select
  assert(ok, err)
  return asked
end

--- @param path string
--- @param records table[]
function M.write_jsonl(path, records)
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  local lines = vim.tbl_map(vim.json.encode, records)
  assert(vim.fn.writefile(lines, path) == 0)
end

--- What `respond` returns for a request that the fake process answers later, through its `held` callbacks
M.later = {}

--- Opens a provider's agent over a fake process, which answers requests with `respond`
--- @param provider 'claude' | 'codex' | 'pi'
--- @param id string
--- @param respond fun(msg: table): string?, any Error and result of each request, or `later`
--- @return table agent
--- @return otto.Event[] events
--- @return otto.StatePatch[] patches
--- @return table[] sent To the process
--- @return otto.Request[] requests Of the agent, for the user
function M.open_agent(provider, id, respond)
  local rpc = require('otto.providers.rpc')
  local util = require('otto.util')
  local sent = {}
  --- @type { seq: integer, held: table<string, fun(err?: string, data?: any)> }
  local fake = { seq = 0, held = {} }
  function fake.send(_, msg)
    table.insert(sent, msg)
    return true
  end
  function fake.request(self, frame, callback)
    self.seq = self.seq + 1
    local msg = frame(self.seq)
    table.insert(sent, msg)
    local err, result = respond(msg)
    if err == M.later then
      fake.held[msg.method or msg.type or tostring(self.seq)] = callback or function() end
    elseif callback then
      callback(err, result)
    end
  end
  function fake.call(self, frame)
    return util.await(function(callback) self:request(frame, callback) end)
  end
  function fake.resolve() end
  function fake.running() return true end
  function fake.close() end

  local events, patches, requests = {}, {}, {}
  local start_agent = rpc.start_agent
  rpc.start_agent = function() return fake end
  local agents = {
    claude = function() return require('otto.providers.claude.agent') end,
    codex = function() return require('otto.providers.codex.agent') end,
    pi = function() return require('otto.providers.pi.agent') end,
  }
  local ok, agent = pcall(agents[provider]().open, id, {
    config = { cmd = {}, args = {}, env = {}, model = 'default', effort = 'high', permission_mode = 'default' },
    on_log = function(event) table.insert(events, event) end,
    on_state = function(patch) table.insert(patches, patch) end,
    on_request = function(request) table.insert(requests, request) end,
  })
  rpc.start_agent = start_agent
  assert(ok, agent)
  return agent, events, patches, sent, requests
end

--- Answers every request of a fake process without an error
--- @return nil, table
function M.respond() return nil, {} end

--- Times of the records of replays
--- @param s integer Seconds after the first record
--- @return string
function M.ts(s) return ('2026-10-21T17:%02d:%02d.000Z'):format(15 + math.floor(s / 60), s % 60) end

--- Without times, which the stream doesn't have, so they're when the messages arrive
--- @param events otto.Event[]
--- @return otto.Event[]
function M.untimed(events)
  return vim.tbl_map(function(e)
    local copy = vim.deepcopy(e)
    copy.at = 0
    copy.started = copy.started and 0
    return copy
  end, events)
end

--- @param events otto.Event[]
--- @return string[]
function M.types(events)
  return vim.tbl_map(function(e) return e.type end, events)
end

--- Runs an async function to its end
--- @param fn async fun()
function M.run(fn) vim.async.run(fn):wait(1000) end

return M
