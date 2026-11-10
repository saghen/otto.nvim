-- pi's process: `pi --mode rpc`, JSONL commands on stdin, and responses and events on stdout, see `decode.lua` for
-- its messages
-- https://github.com/earendil-works/pi/blob/main/docs/rpc.md

local decode = require('otto.providers.pi.decode')
local event = require('otto.event')
local files = require('otto.providers.pi.files')
local jsonl = require('otto.jsonl')
local log = require('otto.providers.log')
local rpc = require('otto.providers.rpc')
local util = require('otto.util')

local M = {}

--- @class otto.PiAgent : otto.Agent
--- @field id string
--- @field rpc otto.Rpc
--- @field log otto.Log
--- @field decoder otto.PiDecoder
--- @field on_state fun(patch: otto.StatePatch)
--- @field on_request fun(request: otto.Request)
--- @field working boolean
local Agent = {}
Agent.__index = Agent

Agent.compact_instructions = true

--- @param msg table A command, see docs/rpc-commands.md
--- @return fun(id: integer): table
local function command(msg)
  return function(id) return vim.tbl_extend('force', msg, { id = tostring(id) }) end
end

--- @param msg table
--- @param callback? fun(err?: string, data?: table) Notifies errors by default
function Agent:request(msg, callback) self.rpc:request(command(msg), callback) end

--- @async
--- @param msg table
--- @return table data
function Agent:call(msg) return self.rpc:call(command(msg)) end

--- Answers pi's extension dialogs, see docs/rpc-extension-ui.md
--- @param request table
function Agent:on_dialog(request)
  if request.method == 'notify' then
    local levels = { warning = vim.log.levels.WARN, error = vim.log.levels.ERROR }
    return util.notify(request.message, levels[request.notifyType] or vim.log.levels.INFO)
  end
  local function respond(value)
    local key = request.method == 'confirm' and 'confirmed' or 'value'
    self.rpc:send({ type = 'extension_ui_response', id = request.id, [key] = value, cancelled = value == nil or nil })
  end
  if request.method == 'input' or request.method == 'editor' then
    self.on_request({
      kind = 'input',
      prompt = request.title,
      default = request.prefill,
      respond = respond,
    })
  elseif request.method == 'select' then
    self.on_request({
      kind = 'select',
      prompt = request.title,
      items = request.options,
      respond = respond,
    })
  elseif request.method == 'confirm' then
    local prompt = request.title .. (request.message and ': ' .. request.message or '')
    self.on_request({ kind = 'confirm', prompt = prompt, respond = respond })
  end
end

--- @param status? 'working' | 'thinking' | 'compacting'
function Agent:set_status(status) self.on_state({ status = status or false }) end

--- Forgets the turn and the queue, once the process exited
function Agent:reset()
  self.working = false
  self.log:reset()
end

--- @param msg table
function Agent:on_message(msg)
  if msg.type == 'response' then
    -- an error without a message fails all the same
    self.rpc:resolve(msg.id, not msg.success and (msg.error or 'request failed') or nil, msg.data)
  elseif msg.type == 'extension_ui_request' then
    self:on_dialog(msg)
  elseif msg.type == 'agent_start' then
    self.working = true
    self:set_status('working')
  elseif msg.type == 'agent_settled' then
    self.working = false
    self.log:end_turn(msg.aborted)
    self:set_status(nil)
  elseif msg.type == 'message_end' then
    decode.add(self.log, self.decoder, msg.message)
  elseif msg.type == 'message_update' then
    local update = msg.assistantMessageEvent.type
    if update == 'thinking_start' then self:set_status('thinking') end
    if update == 'thinking_end' then self:set_status('working') end
  elseif msg.type == 'compaction_start' then
    self:set_status('compacting')
  elseif msg.type == 'compaction_end' then
    if msg.result ~= nil then
      self.log:compaction({ summary = msg.result.summary, before = msg.result.tokensBefore })
    end
    -- compacting can happen while the agent works
    self:set_status(self.working and 'working' or nil)
  elseif msg.type == 'queue_update' then
    self.on_state({ queue = event.queue(msg.steering, msg.followUp) })
  elseif msg.type == 'session_info_changed' then
    self.on_state({ name = msg.name })
  elseif msg.type == 'thinking_level_changed' then
    self.on_state({ effort = msg.level })
  end
end

--- The history from the session file, along its current branch
--- @async
function Agent:replay()
  local file = files.session_file(self.id)
  if file == nil then return end
  local handle = io.open(file)
  if handle == nil then return end
  local entries = {}
  local by_id = {}
  jsonl.each_line(handle, function(line)
    local entry = jsonl.decode(line)
    if entry.id ~= nil and entry.type ~= 'session' then
      table.insert(entries, entry)
      by_id[entry.id] = entry
    end
  end, function(err) util.notify('pi: ' .. err) end)
  local branch = {}
  local entry = entries[#entries]
  while entry ~= nil do
    table.insert(branch, 1, entry)
    entry = entry.parentId and by_id[entry.parentId]
  end

  for _, current in ipairs(branch) do
    -- one bad entry doesn't lose the entries after it
    local ok, err = pcall(decode.add_entry, self.log, self.decoder, current)
    if not ok then util.notify('pi: ' .. tostring(err)) end
  end
  self.log:end_turn()
end

--- @param text string
--- @param mode otto.PromptMode While the agent works
function Agent:prompt(text, mode)
  self:request({ type = 'prompt', message = text, streamingBehavior = mode == 'follow_up' and 'followUp' or 'steer' })
end

function Agent:abort() self:request({ type = 'abort' }) end

--- @async
--- @param newest_only? boolean
--- @return string[]
function Agent:take_queue(newest_only)
  local queued = self:call({ type = 'clear_queue' })
  if not newest_only then return vim.list_extend(vim.list_extend({}, queued.steering), queued.followUp) end
  -- pi only clears them all, so the others go back
  local newest = table.remove(#queued.followUp > 0 and queued.followUp or queued.steering)
  for _, text in ipairs(queued.steering) do
    self:prompt(text, 'steer')
  end
  for _, text in ipairs(queued.followUp) do
    self:prompt(text, 'follow_up')
  end
  return { newest }
end

--- @async
--- @param instructions? string
function Agent:compact(instructions) self:call({ type = 'compact', customInstructions = instructions }) end

--- @async
--- @return string[] like "openrouter/deepseek/deepseek-v4.1-flash"
function Agent:models()
  local models = self:call({ type = 'get_available_models' }).models
  return vim.tbl_map(function(model) return decode.model_id(model.provider, model.id) end, models)
end

--- @async
--- @param model string like "openrouter/deepseek/deepseek-v4.1-flash"
function Agent:set_model(model)
  local provider, id = model:match('^([^/]+)/(.+)$')
  local result = self:call({ type = 'set_model', provider = provider, modelId = id })
  self.on_state({ model = model, context_window = result.contextWindow })
end

--- @async
function Agent:cycle_effort()
  -- pi reports the level as `thinking_level_changed`
  self:call({ type = 'cycle_thinking_level' })
end

--- @async
--- @param name string
function Agent:rename(name) self:call({ type = 'set_session_name', name = name }) end

--- @async
--- @return otto.AgentCommand[]
function Agent:commands()
  return vim.tbl_map(
    function(cmd) return { name = cmd.name, description = cmd.description } end,
    self:call({ type = 'get_commands' }).commands
  )
end

--- @async
--- @return { id: string, text: string }[] prompts to fork from
function Agent:fork_points()
  return vim.tbl_map(
    function(point) return { id = point.entryId, text = point.text } end,
    self:call({ type = 'get_fork_messages' }).messages
  )
end

--- @async
--- @param id string Of the prompt
--- @return { id: string, text: string }? the new session, and the prompt to edit
function Agent:fork(id)
  local fork = self:call({ type = 'fork', entryId = id })
  if fork.cancelled then return end
  return { id = self:call({ type = 'get_state' }).sessionId, text = fork.text }
end

function Agent:close() self.rpc:close() end

--- Starts pi for the session, which it creates when it doesn't exist
--- @param id string
--- @param opts otto.AgentOpts
--- @return otto.PiAgent
function M.open(id, opts)
  local args = { '--session-id', id }
  if opts.name ~= nil then vim.list_extend(args, { '--name', opts.name }) end

  --- @type otto.PiAgent
  local agent = setmetatable({
    id = id,
    log = log.new(opts.on_log, opts.on_state),
    decoder = decode.new(),
    on_state = opts.on_state,
    on_request = opts.on_request,
    working = false,
  }, Agent)
  agent.rpc = rpc.start_agent(opts.config, vim.list_extend({ '--mode', 'rpc' }, args), {
    name = 'pi',
    on_message = function(msg) agent:on_message(msg) end,
    on_exit = function() agent:reset() end,
  })
  util.run_task(function()
    local state = agent:call({ type = 'get_state' })
    local model = state.model or {}
    opts.on_state({
      name = state.sessionName,
      model = model.id and decode.model_id(model.provider, model.id),
      effort = model.reasoning and state.thinkingLevel or nil,
      context_window = model.contextWindow,
    })
  end)
  return agent
end

return M
