-- pi's RPC mode: JSONL commands on stdin, and responses and events on stdout
-- https://github.com/earendil-works/pi/blob/main/docs/rpc.md

--- @class otto.Client
--- @field name string
--- @field proc vim.SystemObj
--- @field closed boolean
--- @field seq integer
--- @field pending table<string, fun(err?: string, data?: table)> Response callbacks by request id
--- @field on_settled? fun() Called when pi stops working, set by `Client:prompt`
--- @field stderr? string
local Client = {}
Client.__index = Client

local M = {}

--- @param message string
--- @param level? integer
function M.notify(message, level) vim.notify('otto: ' .. message, level or vim.log.levels.ERROR) end

--- `vim.ui.select` inside a task
--- @async
--- @param items any[]
--- @param opts table
--- @return any?
function M.select(items, opts) return vim.async.await(3, vim.ui.select, items, opts) end

--- `vim.ui.input` inside a task
--- @async
--- @param opts table
--- @return string?
function M.input(opts) return vim.async.await(2, vim.ui.input, opts) end

--- Answers pi's extension dialogs, see docs/rpc-extension-ui.md
--- @async
--- @param client otto.Client
--- @param event table
local function dialog(client, event)
  local value
  if event.method == 'notify' then
    local levels = { warning = vim.log.levels.WARN, error = vim.log.levels.ERROR }
    return M.notify(event.message, levels[event.notifyType] or vim.log.levels.INFO)
  elseif event.method == 'input' or event.method == 'editor' then
    value = M.input({ prompt = event.title, default = event.prefill })
  elseif event.method == 'select' then
    value = M.select(event.options, { prompt = event.title })
  elseif event.method == 'confirm' then
    local prompt = event.title .. (event.message and ': ' .. event.message or '')
    local choice = M.select({ 'Yes', 'No' }, { prompt = prompt })
    value = choice and choice == 'Yes'
  end
  local key = event.method == 'confirm' and 'confirmed' or 'value'
  client:send({ type = 'extension_ui_response', id = event.id, [key] = value, cancelled = value == nil or nil })
end

--- Starts `pi --mode rpc`, which pi shuts down when its stdin closes
--- @param name string Shown in errors
--- @param args string[]
--- @param on_event fun(event: table) Session events, see docs/json.md
--- @return otto.Client
function M.start(name, args, on_event)
  local client = setmetatable({ name = name, closed = false, seq = 0, pending = {} }, Client)

  -- split only on LF, since JSON strings can contain U+2028
  local partial = ''
  local function on_stdout(_, data)
    local lines = vim.split(partial .. (data or ''), '\n')
    partial = table.remove(lines)
    for _, line in ipairs(lines) do
      if client.closed then return end
      local event = vim.json.decode(line, { luanil = { object = true, array = true } })
      if event.type == 'response' then
        local callback = client.pending[event.id]
        client.pending[event.id] = nil
        if callback ~= nil then callback(not event.success and event.error or nil, event.data) end
      elseif event.type == 'extension_ui_request' then
        M.run(function() dialog(client, event) end)
      else
        if event.type == 'agent_settled' and client.on_settled ~= nil then client.on_settled() end
        on_event(event)
      end
    end
  end

  local config = require('otto.config')
  local cmd = vim.list_extend({ config.options.pi.command }, config.options.pi.args)
  vim.list_extend(cmd, { '--mode', 'rpc' })
  if config.session_override() then vim.list_extend(cmd, { '--session-dir', config.session_dir() }) end
  vim.list_extend(cmd, args)
  local opts = { stdin = true, stdout = vim.schedule_wrap(on_stdout) }
  if config.options.pi.agent_dir ~= nil then opts.env = { PI_CODING_AGENT_DIR = config.agent_dir() } end
  opts.stderr = function(_, data) client.stderr = data or client.stderr end
  local ok, proc = pcall(vim.system, cmd, opts, function(out)
    if client.closed or out.code == 0 then return end
    vim.schedule(function() M.notify(name .. ' exited: ' .. (client.stderr or out.code)) end)
  end)
  if not ok then error(('otto: could not start %s (%s): %s'):format(name, cmd[1], proc), 0) end
  client.proc = proc
  return client
end

--- @param msg table
function Client:send(msg)
  if self.proc:is_closing() then return M.notify(self.name .. ' is not running') end
  self.proc:write(vim.json.encode(msg) .. '\n')
end

--- See docs/rpc-commands.md
--- @param msg table
--- @param callback? fun(err?: string, data?: table) Notifies errors by default
function Client:request(msg, callback)
  self.seq = self.seq + 1
  msg.id = tostring(self.seq)
  self.pending[msg.id] = callback or function(err)
    if err ~= nil then M.notify(err) end
  end
  self:send(msg)
end

--- Awaits a request inside a task, raising its error
--- @async
--- @param msg table
--- @return table?
function Client:call(msg)
  local err, data = vim.async.await(3, self.request, self, msg)
  if err ~= nil then error(err, 0) end
  return data
end

--- Prompts pi and waits until it settles, returning its last answer
--- @async
--- @param message string
--- @return string
function Client:prompt(message)
  local err = vim.async.await(1, function(done)
    self.on_settled = done
    self:request({ type = 'prompt', message = message }, function(err)
      if err ~= nil then done(err) end
    end)
  end)
  if err ~= nil then error(err, 0) end
  return self:call({ type = 'get_last_assistant_text' }).text or ''
end

function Client:close()
  self.closed = true
  if not self.proc:is_closing() then self.proc:kill('sigterm') end
end

--- Sends `message` to a new pi without a saved session, and returns its final answer
--- @async
--- @param name string Shown in errors
--- @param message string
--- @param args? string[] for pi
--- @return string
function M.ask(name, message, args)
  local client = M.start(name, vim.list_extend({ '--no-session', '--no-mcp' }, args or {}), function() end)
  local ok, answer = pcall(client.prompt, client, message)
  client:close()
  if not ok then error(answer, 0) end
  return answer
end

--- Runs `fn` as a task, notifying its error
--- @param fn async fun()
function M.run(fn)
  vim.async.run(fn):on_complete(function(err)
    if err ~= nil then M.notify(tostring(err)) end
  end)
end

return M
