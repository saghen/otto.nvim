-- Codex's process: `codex app-server`, JSON-RPC over stdio, which has the history too, see `decode.lua` for its items

local decode = require('otto.providers.codex.decode')
local event = require('otto.event')
local log = require('otto.providers.log')
local rpc = require('otto.providers.rpc')
local util = require('otto.util')

local M = {}

--- @class otto.CodexAgent : otto.Agent
--- @field rpc otto.Rpc
--- @field log otto.Log
--- @field on_state fun(patch: otto.StatePatch)
--- @field on_request fun(request: otto.Request)
--- @field thread? string id, once Codex started or resumed it
--- @field thread_ready otto.Ready Once the thread started, or failed to
--- @field models_ready otto.Ready With the models of `model/list`, once Codex listed them, or failed to
--- @field turn? string id of the turn that's running
--- @field turn_input? string id of the prompt that started it, or that starts the next, which isn't Codex's to drop
--- @field abort_pending? boolean Whether to abort the turn once it starts, which it can't before
--- @field interrupted? string id of the turn that was interrupted, which ends on its own
--- @field turn_started? integer When the turn started
--- @field working boolean From sending a prompt until its turn completes
--- @field model? string
--- @field effort? string like "medium", which turns take, since Codex sets both per turn
--- @field announced table<string, true> Tool calls that started, in the log before their items complete
--- @field unread { text: string, id: string }[] Prompts that Codex hasn't read yet
--- @field follow_ups string[] Prompts that wait for the turn to complete
--- @field new_thread? boolean Whether the thread started with the agent, without history
--- @field decoder otto.CodexDecoder
local Agent = {}
Agent.__index = Agent

-- `thread/compact/start` only takes the thread
Agent.compact_instructions = false

--- @param method string
--- @param params table
--- @return fun(id: integer): table
local function frame(method, params)
  return function(id) return { method = method, id = id, params = params } end
end

--- @param method string
--- @param params table
--- @param callback? fun(err?: string, data?: table) Notifies errors by default
function Agent:request(method, params, callback) self.rpc:request(frame(method, params), callback) end

--- Waits until the thread started
--- @async
function Agent:await_thread() self.thread_ready:await() end

--- Invokes a method of the thread, once it started
--- @async
--- @param method string
--- @param params? table Besides the thread's id
--- @return table result
function Agent:call(method, params)
  self:await_thread()
  return self.rpc:call(frame(method, vim.tbl_extend('force', { threadId = self.thread }, params or {})))
end

function Agent:report_queue()
  local texts = vim.tbl_map(function(unread) return unread.text end, self.unread)
  self.on_state({ queue = event.queue(texts, self.follow_ups) })
end

--- @param working boolean
function Agent:set_working(working)
  self.working = working
  self.on_state({ status = working and 'working' })
end

--- @param text string
--- @return table input of a turn
local function input(text) return { { type = 'text', text = text, text_elements = {} } } end

--- @param text string
function Agent:start_turn(text)
  -- of a thread that failed to start, or a process that's gone, which nothing would read
  local failed = self.thread_ready.err
  if failed ~= nil then return util.notify(failed == util.closed and 'codex is not running' or failed) end
  local id = util.uuid()
  self.turn_input = id
  table.insert(self.unread, { text = text, id = id })
  self:report_queue()
  if not self.working then self:set_working(true) end
  -- prompts can come before the thread starts
  util.run_task(function()
    self:await_thread()
    local params = {
      threadId = self.thread,
      input = input(text),
      clientUserMessageId = id,
      model = self.model,
      effort = self.effort,
    }
    self:request('turn/start', params, function(err)
      if err == nil then return end
      util.notify(err)
      self:on_echo({ clientId = id })
      -- like the follow-ups that waited for it
      if self.turn == nil then self:after_turn() end
    end)
  end)
end

--- Starts the next follow-up, or else stops working
function Agent:after_turn()
  self.abort_pending = nil
  if #self.follow_ups > 0 then return self:start_turn(table.remove(self.follow_ups, 1)) end
  self:report_queue()
  self:set_working(false)
end

--- Forgets the turn and the queue, once the process exited or the thread failed to start
function Agent:reset()
  self.turn, self.turn_started, self.turn_input, self.abort_pending = nil, nil, nil, nil
  self.unread, self.follow_ups, self.announced = {}, {}, {}
  self.working = false
  self.log:reset()
end

--- Codex echoes prompts once it reads them
--- @param item table userMessage
function Agent:on_echo(item)
  local index = vim.iter(ipairs(self.unread)):find(function(_, unread) return unread.id == item.clientId end)
  if index == nil then return end
  table.remove(self.unread, index)
  self:report_queue()
end

--- Codex asks before running commands or changing files that its reviewer doesn't allow
--- @param msg table
function Agent:on_approval(msg)
  local params = msg.params or {}
  local what = msg.method == 'item/fileChange/requestApproval' and 'change files'
    or 'run ' .. (params.command or 'a command')
  local prompt = ('Codex wants to %s%s: '):format(what, params.reason and ' (' .. params.reason .. ')' or '')
  local decisions = { Allow = 'accept', ['Always allow'] = 'acceptForSession', Deny = 'decline' }
  self.on_request({
    kind = 'select',
    prompt = prompt,
    items = { 'Allow', 'Always allow', 'Deny' },
    respond = function(choice)
      local decision = decisions[choice] or 'decline'
      self.rpc:send({ id = msg.id, result = { decision = decision } })
    end,
  })
end

--- @param msg table
function Agent:on_message(msg)
  if msg.method == nil then
    return self.rpc:resolve(msg.id, msg.error and (msg.error.message or vim.inspect(msg.error)), msg.result)
  end
  local params = msg.params or {}
  if msg.id ~= nil then
    if not vim.endswith(msg.method, '/requestApproval') or msg.method == 'item/permissions/requestApproval' then
      return self.rpc:send({
        id = msg.id,
        error = { code = -32601, message = msg.method .. ' is not supported by otto' },
      })
    end
    return self:on_approval(msg)
  end

  local item = params.item
  if msg.method == 'turn/started' then
    self.turn = params.turn.id
    self.turn_started = decode.times(params.turn)
    -- like compactions, which are turns of their own
    if not self.working then self:set_working(true) end
    if self.abort_pending then self:abort() end
  elseif msg.method == 'item/started' and item.type == 'contextCompaction' then
    self.on_state({ status = 'compacting' })
  -- file changes too, whose patches apply before they complete, so that otto-track sees them while they run
  elseif
    msg.method == 'item/started' and vim.list_contains({ 'commandExecution', 'mcpToolCall', 'fileChange' }, item.type)
  then
    for _, call in ipairs(decode.calls(item)) do
      self.announced[call.id] = true
      self.log:tool_call(call.id, call.tool, call.args, self.turn_started)
    end
  -- not of earlier turns, like commands that ran in the background, which the log can't add to
  elseif msg.method == 'item/completed' and params.turnId == self.turn then
    if item.type == 'userMessage' then self:on_echo(item) end
    decode.add(self.log, self.decoder, item, self.announced, self.turn_started)
    if item.type == 'contextCompaction' then self.on_state({ status = 'working' }) end
  elseif msg.method == 'error' and not params.willRetry then
    self.log:error(params.error.message, self.turn_started)
  elseif msg.method == 'thread/tokenUsage/updated' then
    self.on_state({
      context_tokens = params.tokenUsage.last.totalTokens,
      context_window = params.tokenUsage.modelContextWindow,
    })
  elseif msg.method == 'thread/name/updated' then
    self.on_state({ name = params.threadName })
  elseif msg.method == 'turn/completed' then
    self.turn = nil
    -- whatever it didn't read is gone with the turn
    self.unread = {}
    self.log:end_turn(params.turn.status == 'interrupted', select(2, decode.times(params.turn)))
    -- starts the follow-ups, even after an interrupt
    self:after_turn()
  end
end

--- The history, from the app-server
--- @async
function Agent:replay()
  self:await_thread()
  -- Codex only lists the turns of threads with messages
  if self.new_thread then return end
  local turns = {}
  local cursor
  repeat
    local page = self:call('thread/turns/list', { itemsView = 'full', sortDirection = 'asc', cursor = cursor })
    vim.list_extend(turns, page.data)
    cursor = page.nextCursor
  until cursor == nil
  for _, turn in ipairs(turns) do
    -- one bad item doesn't lose the turns after it
    local ok, err = pcall(function()
      local started, completed = decode.times(turn)
      for _, item in ipairs(turn.items) do
        decode.add(self.log, self.decoder, item, {}, started)
      end
      if turn.error ~= nil then self.log:error(turn.error.message, started) end
      self.log:end_turn(turn.status == 'interrupted', completed)
    end)
    if not ok then util.notify('codex: ' .. tostring(err)) end
  end
  self.log:end_turn()
end

--- @param text string
--- @param mode otto.PromptMode While a turn runs
function Agent:prompt(text, mode)
  if not self.working then return self:start_turn(text) end
  -- until the turn starts, which there's nothing to steer before
  if mode == 'follow_up' or self.turn == nil then
    table.insert(self.follow_ups, text)
    return self:report_queue()
  end
  local id = util.uuid()
  local turn = self.turn
  table.insert(self.unread, { text = text, id = id })
  self:report_queue()
  local params = { threadId = self.thread, input = input(text), clientUserMessageId = id, expectedTurnId = turn }
  self:request('turn/steer', params, function(err)
    if err == nil then return end
    self:on_echo({ clientId = id })
    -- like a turn that can't be steered, such as a compaction, or one that completed before Codex got the prompt, which
    -- then goes after it, or after the follow-up that's starting
    if self.working then
      table.insert(self.follow_ups, text)
      return self:report_queue()
    end
    self:start_turn(text)
  end)
end

--- Takes the prompts that Codex hasn't read, but not the turn's own, which it doesn't drop
--- @return string[]
function Agent:take_unread()
  local texts = {}
  self.unread = vim.tbl_filter(function(unread)
    if unread.id == self.turn_input then return true end
    table.insert(texts, unread.text)
    return false
  end, self.unread)
  return texts
end

function Agent:abort()
  -- a prompt that's starting a turn, which can only be interrupted once it started
  if self.turn == nil then
    self.abort_pending = self.working or nil
    return
  end
  self.abort_pending = nil
  -- prompts that Codex hasn't read, which it drops with the turn, go on after it
  self.follow_ups = vim.list_extend(self:take_unread(), self.follow_ups)
  self:report_queue()
  -- once, since the turn then ends on its own
  if self.interrupted == self.turn then return end
  self.interrupted = self.turn
  self:request('turn/interrupt', { threadId = self.thread, turnId = self.turn })
end

--- Prompts that steer are with Codex already, and only drop with the turn, so taking them interrupts it
--- @async
--- @return string[]
--- @param newest_only? boolean Only the newest follow-up, which never interrupts
function Agent:take_queue(newest_only)
  if newest_only then
    local texts = { table.remove(self.follow_ups) }
    self:report_queue()
    return texts
  end
  -- which moves them to the follow-ups
  if #vim.tbl_filter(function(unread) return unread.id ~= self.turn_input end, self.unread) > 0 then self:abort() end
  local texts = vim.list_extend(self:take_unread(), self.follow_ups)
  self.follow_ups = {}
  self:report_queue()
  return texts
end

--- Without instructions, which Codex doesn't take
--- @async
function Agent:compact() self:call('thread/compact/start') end

--- @async
--- @return string[]
function Agent:models()
  return vim.tbl_map(function(model) return model.id end, self.models_ready:await())
end

--- @async
--- @param model string
function Agent:set_model(model)
  self.model = model
  self.on_state({ model = model })
end

--- @async
function Agent:cycle_effort()
  local model = vim.iter(self.models_ready:await()):find(function(option) return option.id == self.model end)
  local options = model and model.supportedReasoningEfforts or {}
  local levels = vim.tbl_map(function(option) return option.reasoningEffort end, options)
  self.effort = util.next_effort(levels, self.effort)
  self.on_state({ effort = self.effort })
end

--- @async
--- @param name string
function Agent:rename(name) self:call('thread/name/set', { name = name }) end

--- @async
--- @return otto.AgentCommand[]
function Agent:commands() return {} end

function Agent:close() self.rpc:close() end

--- Releases what waits for the thread
--- @param err? string When it failed to start
--- @param result? table Of `thread/start` or `thread/resume`
function Agent:on_thread_started(err, result)
  if err ~= nil then
    self:reset()
  elseif result ~= nil then
    self:set_thread(result)
  end
  -- an error raises in what waits for the thread, like the replay that every session starts with
  self.thread_ready:set(err)
end

--- @param result table Of `thread/start` or `thread/resume`
function Agent:set_thread(result)
  self.thread = result.thread.id
  self.model = result.model
  self.effort = result.reasoningEffort
  self.on_state({
    id = self.thread,
    name = result.thread.name,
    model = self.model,
    effort = self.effort,
  })
end

--- Starts Codex for the session. Codex creates the ids of threads, so a new session starts with its name or when it
--- started, until its thread starts
--- @param id string Of the thread, or of the new session
--- @param opts otto.AgentOpts
--- @return otto.CodexAgent
function M.open(id, opts)
  --- @type otto.CodexAgent
  local agent = setmetatable({
    log = log.new(opts.on_log, opts.on_state),
    on_state = opts.on_state,
    on_request = opts.on_request,
    thread_ready = util.ready(),
    models_ready = util.ready(),
    working = false,
    announced = {},
    decoder = decode.new(),
    unread = {},
    follow_ups = {},
  }, Agent)
  agent.rpc = rpc.start_agent(opts.config, { 'app-server' }, {
    name = 'codex',
    on_message = function(msg) agent:on_message(msg) end,
    on_exit = function() agent:reset() end,
  })

  local info = { name = 'otto', title = 'Otto', version = '0' }
  agent:request('initialize', { clientInfo = info }, function(err)
    if err ~= nil then
      agent.models_ready:set(err)
      return agent:on_thread_started(err)
    end
    agent.rpc:send({ method = 'initialized' })
    -- an error raises in what waits for the models, like the model picker
    agent:request('model/list', {}, function(list_err, data) agent.models_ready:set(list_err, data and data.data) end)
    -- the id of a thread, which Codex creates, rather than the name of a new session
    if util.is_uuid(id) then
      return agent:request(
        'thread/resume',
        { threadId = id, excludeTurns = true },
        function(resume_err, result) agent:on_thread_started(resume_err, result) end
      )
    end
    agent:request('thread/start', { cwd = vim.fn.getcwd() }, function(start_err, result)
      agent.new_thread = start_err == nil
      agent:on_thread_started(start_err, result)
      if start_err ~= nil then return end
      if opts.name ~= nil then agent:request('thread/name/set', { threadId = agent.thread, name = opts.name }) end
    end)
  end)
  return agent
end

return M
