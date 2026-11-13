-- Claude Code's process: `claude -p` with stream-json in both directions, see `decode.lua` for its entries

local decode = require('otto.providers.claude.decode')
local event = require('otto.event')
local files = require('otto.providers.claude.files')
local jsonl = require('otto.jsonl')
local log = require('otto.providers.log')
local rpc = require('otto.providers.rpc')
local util = require('otto.util')

local M = {}

--- @type table<string, { session: string, at?: string }> Forks by id, until they're prompted, which saves them
local forks = {}

-- of the default model, until Claude Code reports the context window of the one that answers
local default_context_window = 1000000

--- Of `--permission-mode`
--- @alias otto.ClaudePermissionMode
---| 'default'
---| 'manual' # default
---| 'acceptEdits'
---| 'plan'
---| 'auto'
---| 'dontAsk'
---| 'bypassPermissions'

--- @class otto.ClaudeAgentOpts : otto.AgentOpts
--- @field config otto.ClaudeConfig

--- @class otto.ClaudeAgent : otto.Agent
--- @field id string
--- @field file string Of the session, in the folder that Claude Code started in
--- @field rpc otto.Rpc
--- @field log otto.Log
--- @field decoder otto.ClaudeDecoder
--- @field on_state fun(patch: otto.StatePatch)
--- @field on_request fun(request: otto.Request)
--- @field init otto.Ready Response to `initialize`, with the commands and models
--- @field model string
--- @field effort string like "high", which Claude Code only writes to the session file
--- @field working boolean
--- @field thinking boolean
--- @field unread { text: string, uuid: string, follow_up: boolean }[] Prompts that Claude Code hasn't read yet, which
--- it doesn't report
--- @field started_prompts table<string, true> Prompts that rendered when Claude Code started a turn with them, until it
--- echoes them
--- @field foreground table<string, true> Subagents that the turn waits for, by task, which end with their tool's result
--- @field notifications table[] Ends of subagents and commands in the background that Claude Code hasn't read yet
--- @field permissions table<string, otto.Request> Asked, by request id, until they're answered
local Agent = {}
Agent.__index = Agent

Agent.compact_instructions = true

--- Adds the ends of subagents and commands that Claude Code read
function Agent:flush_notifications()
  for _, notification in ipairs(self.notifications) do
    decode.add_task_end(self.log, self.decoder, notification, notification.at)
  end
  self.notifications = {}
end

--- Claude Code adds the ends of what runs in the background to the conversation, once it reads them
--- @param msg table system message
function Agent:on_task(msg)
  if msg.subtype == 'task_started' and msg.is_backgrounded == false then
    self.foreground[msg.task_id] = true
  elseif msg.subtype == 'background_tasks_changed' then
    for _, task in ipairs(msg.tasks or {}) do
      self.foreground[task.task_id] = nil
    end
  elseif msg.subtype == 'task_notification' then
    local foreground = msg.is_backgrounded == false or self.foreground[msg.task_id]
    self.foreground[msg.task_id] = nil
    if foreground then return end
    -- until Claude Code reads it, which starts a turn, where its file has it
    msg.at = event.now()
    table.insert(self.notifications, msg)
  end
end

--- @param request table
--- @return fun(id: integer): table
local function frame(request)
  return function(id) return { type = 'control_request', request_id = tostring(id), request = request } end
end

--- @param request table
--- @param callback? fun(err?: string, data?: table) Notifies errors by default
function Agent:request(request, callback) self.rpc:request(frame(request), callback) end

--- @async
--- @param request table
--- @return table response
function Agent:call(request) return self.rpc:call(frame(request)) end

--- @async
--- @return table response to `initialize`
function Agent:await_init() return self.init:await() end

--- @param follow_up boolean
--- @return { text: string, uuid: string, follow_up: boolean }[] unread Of those that steer, or the follow-ups
function Agent:unread_of(follow_up)
  return vim.tbl_filter(function(queued) return queued.follow_up == follow_up end, self.unread)
end

--- @return { text: string, uuid: string, follow_up: boolean }[] unread Steering first, like the queue shows them
function Agent:queued() return vim.list_extend(self:unread_of(false), self:unread_of(true)) end

function Agent:report_queue()
  local function texts(follow_up)
    return vim.tbl_map(function(queued) return queued.text end, self:unread_of(follow_up))
  end
  self.on_state({ queue = event.queue(texts(false), texts(true)) })
end

--- @param working boolean
function Agent:set_working(working)
  self.working = working
  self.thinking = false
  self.on_state({ status = working and 'working' })
end

--- Claude Code echoes prompts once it reads them, see `--replay-user-messages`
--- @param text string
function Agent:on_echo(text)
  local index = vim.iter(ipairs(self.unread)):find(function(_, queued) return queued.text == text end)
  if index == nil then return end
  table.remove(self.unread, index)
  self:report_queue()
  -- after an interrupt, Claude Code starts on the queued prompts itself
  if not self.working then self:set_working(true) end
end

--- Claude Code starts a turn with a queued prompt, but only echoes it with the answer's first block, so it renders
--- when the turn starts
--- @param uuid string
function Agent:on_command_started(uuid)
  local index = vim.iter(ipairs(self.unread)):find(function(_, queued) return queued.uuid == uuid end)
  if index == nil then return end
  local text = table.remove(self.unread, index).text
  self:report_queue()
  self.started_prompts[uuid] = true
  decode.add_started_prompt(self.log, self.decoder, uuid, text)
  -- like a follow-up, which starts after the turn that it waited for
  if not self.working then self:set_working(true) end
end

--- Claude Code asks before using tools, unless it's been allowed to
--- @param msg table control_request
function Agent:on_permission(msg)
  local request = msg.request
  local suggestions = request.permission_suggestions or {}
  local items = { 'Allow', 'Deny' }
  if #suggestions > 0 then table.insert(items, 2, 'Always allow') end
  local prompt = ('Claude wants to use %s %s: '):format(
    request.display_name or request.tool_name,
    request.description or ''
  )
  --- @type otto.Request
  local pending
  pending = {
    kind = 'select',
    prompt = prompt,
    items = items,
    respond = function(choice)
      -- unless it was answered elsewhere, like over Remote Control, or the turn was interrupted
      if pending.cancelled then return end
      self.permissions[msg.request_id] = nil
      local response = { behavior = 'deny', message = 'The user denied this' }
      if choice == 'Allow' or choice == 'Always allow' then
        response = {
          behavior = 'allow',
          updatedInput = request.input,
          updatedPermissions = choice == 'Always allow' and suggestions or nil,
        }
      end
      self.rpc:send({
        type = 'control_response',
        response = { subtype = 'success', request_id = msg.request_id, response = response },
      })
    end,
  }
  self.permissions[msg.request_id] = pending
  self.on_request(pending)
end

--- @param msg table
function Agent:on_message(msg)
  if msg.type == 'control_response' then
    local response = msg.response
    -- an error without a message fails all the same
    local err = response.subtype == 'error' and (response.error or 'request failed') or nil
    self.rpc:resolve(response.request_id, err, response.response)
  elseif msg.type == 'control_request' and msg.request.subtype == 'can_use_tool' then
    self:on_permission(msg)
  elseif msg.type == 'control_cancel_request' then
    local pending = self.permissions[msg.request_id]
    if pending then pending.cancelled = true end
    self.permissions[msg.request_id] = nil
  elseif msg.type == 'control_request' then
    -- which Claude Code would wait for
    local message = msg.request.subtype .. ' is not supported by otto'
    local response = { subtype = 'error', request_id = msg.request_id, error = message }
    self.rpc:send({ type = 'control_response', response = response })
  elseif msg.type == 'system' then
    if msg.subtype == 'init' then
      self.model = msg.model
      self.on_state({ model = msg.model })
      self:flush_notifications()
    end
    if msg.subtype == 'status' and msg.status == 'compacting' then self.on_state({ status = 'compacting' }) end
    if msg.subtype == 'compact_boundary' then
      decode.add(self.log, self.decoder, msg)
      self.on_state({ status = self.working and 'working' })
    end
    if msg.subtype == 'session_title_changed' then self.on_state({ name = msg.title }) end
    -- of Remote Control, which reconnects unless it failed for good
    if msg.subtype == 'bridge_state' and (msg.failure_kind == 'terminal' or msg.state == 'policy_disabled') then
      util.notify('claude: Remote Control stopped: ' .. (msg.detail or msg.state))
      self.on_state({ remote = false })
    end
    if msg.subtype == 'background_tasks_changed' or vim.startswith(msg.subtype or '', 'task_') then
      self:on_task(msg)
    end
  elseif msg.type == 'command_lifecycle' then
    -- unlike prompts that steer the turn, which render when it reads them
    if msg.state == 'started' and not self.log.in_turn then self:on_command_started(msg.command_uuid) end
  elseif msg.type == 'user' and self.started_prompts[msg.uuid] then
    self.started_prompts[msg.uuid] = nil
  elseif msg.type == 'assistant' or msg.type == 'user' then
    if msg.type == 'user' and type(msg.message.content) == 'string' then self:on_echo(msg.message.content) end
    decode.add(self.log, self.decoder, msg)
  elseif msg.type == 'stream_event' and msg.parent_tool_use_id == nil then
    local stream = msg.event
    -- of a turn that otto didn't start, like with a prompt over Remote Control
    if stream.type == 'message_start' and not self.working then self:set_working(true) end
    if stream.type == 'content_block_start' and stream.content_block.type == 'thinking' then
      self.thinking = true
      self.on_state({ status = 'thinking' })
    elseif stream.type == 'content_block_stop' and self.thinking then
      self.thinking = false
      self.on_state({ status = 'working' })
    end
  elseif msg.type == 'result' then
    local usage = (msg.modelUsage or {})[self.model] or select(2, next(msg.modelUsage or {}))
    if usage then self.on_state({ context_window = usage.contextWindow }) end
    self:report_context()
    self.log:end_turn(msg.subtype == 'error_during_execution')
    -- until Claude Code starts on the prompts that it didn't read, like follow-ups
    self:set_working(#self.unread > 0)
    -- which only the background ones outlive
    self.foreground = {}
  end
end

--- Asks Claude Code where it compacts, which depends on the model and settings, from its estimate without calling
--- the API
function Agent:report_context()
  self:request({ subtype = 'get_context_usage', detail = 'summary' }, function(err, usage)
    -- like older versions, which don't have it
    if err ~= nil or usage == nil then return end
    self.on_state({
      context_tokens = usage.totalTokens,
      compact_at = usage.isAutoCompactEnabled and usage.autoCompactThreshold or false,
    })
  end)
end

--- The history from the session file
--- @async
function Agent:replay()
  local file = self.file
  -- a fork, which Claude Code only saves once it's prompted, shows the session it forked up to where it did
  local fork = forks[self.id]
  if vim.uv.fs_stat(file) == nil and fork and fork.at then file = files.session_file(fork.session) end
  local handle = io.open(file)
  if handle == nil then return end
  -- up to and including the entry that the fork resumes at, even if it fails
  local at_fork = false
  jsonl.each_line(handle, function(line)
    if at_fork then return false end
    local entry = jsonl.decode(line)
    at_fork = file ~= self.file and entry.uuid == fork.at
    decode.add(self.log, self.decoder, entry)
  end, function(err) util.notify('claude: ' .. err) end)
  self.log:end_turn()
end

--- Claude Code reads prompts that steer between the steps of its turn, and those of priority "later" once it ends
--- @param text string
--- @param mode otto.PromptMode While the agent works
function Agent:prompt(text, mode)
  local uuid = util.uuid() -- which cancels it while it's queued
  local follow_up = self.working and mode == 'follow_up'
  local priority = follow_up and 'later' or nil
  local message = { type = 'user', uuid = uuid, priority = priority, message = { role = 'user', content = text } }
  -- to a process that's gone, which would never read it
  if not self.rpc:send(message) then return end
  if not self.working then self:set_working(true) end
  -- commands render as their output
  if vim.startswith(text, '/') then return end
  table.insert(self.unread, { text = text, uuid = uuid, follow_up = follow_up })
  self:report_queue()
end

function Agent:abort() self:request({ subtype = 'interrupt' }) end

--- Runs a command of Claude Code, like /compact, which it reads like a prompt
--- @async
--- @param text string
function Agent:run_command(text)
  if not self.rpc:running() then error('claude is not running', 0) end
  self:prompt(text, 'steer')
end

--- @async
--- @return string[]
--- @param newest_only? boolean
function Agent:take_queue(newest_only)
  local texts = {}
  local queue = self:queued()
  -- the last one first, while it's waited on
  for i = #queue, 1, -1 do
    local queued = queue[i]
    -- unless Claude Code read it already, which then answers it
    if self:call({ subtype = 'cancel_async_message', message_uuid = queued.uuid }).cancelled then
      table.insert(texts, 1, queued.text)
      self.unread = vim.tbl_filter(function(other) return other ~= queued end, self.unread)
      if newest_only then break end
    end
  end
  self:report_queue()
  return texts
end

--- @async
--- @param instructions? string
function Agent:compact(instructions) self:run_command(vim.trim('/compact ' .. (instructions or ''))) end

--- @async
--- @return string[]
function Agent:models()
  -- aliases like "opus" resolve to the same model as "default"
  local ids = {}
  for _, model in ipairs(self:await_init().models) do
    if not vim.list_contains(ids, model.resolvedModel) then table.insert(ids, model.resolvedModel) end
  end
  return ids
end

--- @async
--- @param model string
function Agent:set_model(model)
  self:call({ subtype = 'set_model', model = model })
  self.model = model
  self.on_state({ model = model })
  self:report_context()
end

--- @async
--- @return string[]
function Agent:efforts()
  local model = vim.iter(self:await_init().models):find(function(option) return option.resolvedModel == self.model end)
  return util.efforts(model and model.supportedEffortLevels or {})
end

--- @async
--- @param level string
function Agent:set_effort(level)
  self:call({ subtype = 'apply_flag_settings', settings = { effortLevel = level } })
  self.effort = level
  self.on_state({ effort = level })
end

--- @async
function Agent:cycle_effort() self:set_effort(util.next_effort(self:efforts(), self.effort)) end

--- With Claude Code's /rename, which it runs after the turn that's running, without the model. Claude Code keeps the
--- name, and reports it as `session_title_changed`
--- @async
--- @param name string
function Agent:rename(name) self:run_command('/rename ' .. name) end

--- @async
--- @return otto.AgentCommand[]
function Agent:commands()
  return vim.tbl_map(
    function(cmd) return { name = cmd.name, description = cmd.description, arg_hint = cmd.argumentHint } end,
    self:await_init().commands
  )
end

--- @async
--- @return { id: string, text: string }[] prompts to fork from
function Agent:fork_points()
  return vim.tbl_map(function(prompt) return { id = prompt.uuid, text = prompt.text } end, self.decoder.prompts)
end

--- A new session from before the prompt, which starts once it's opened, see `M.open`
--- @async
--- @param id string Uuid of the prompt
--- @return { id: string, text: string }? the new session, and the prompt to edit
function Agent:fork(id)
  local prompt = vim.iter(self.decoder.prompts):find(function(prompt) return prompt.uuid == id end)
  if prompt == nil then return end
  -- of a fork that wasn't prompted yet, the session that it forked
  local session = vim.uv.fs_stat(self.file) and self.id or (forks[self.id] or {}).session or self.id
  local fork = util.uuid()
  forks[fork] = { session = session, at = prompt.parent }
  return { id = fork, text = prompt.text }
end

--- With a link to the session on claude.ai, which the Claude app opens too
--- @async
--- @param enabled boolean
--- @return string? link Once it's on
function Agent:remote_control(enabled)
  local response = self:call({ subtype = 'remote_control', enabled = enabled }) or {}
  local link = enabled and response.session_url or nil
  self.on_state({ remote = link or false })
  return link
end

function Agent:close() self.rpc:close() end

--- Forgets the turn and the queue, once the process exited
function Agent:reset()
  -- without the ends that Claude Code didn't read, which its file doesn't have
  self.notifications, self.foreground, self.started_prompts, self.unread = {}, {}, {}, {}
  self.working, self.thinking = false, false
  -- which a process that's gone can't read
  for _, pending in pairs(self.permissions) do
    pending.cancelled = true
  end
  self.permissions = {}
  self.log:reset()
  -- which ends with the process
  self.on_state({ remote = false })
end

--- Starts Claude Code for the session, which it creates when it doesn't exist
--- @param id string UUID
--- @param opts otto.ClaudeAgentOpts
--- @return otto.ClaudeAgent
function M.open(id, opts)
  --- @type otto.ClaudeAgent
  local agent = setmetatable({
    id = id,
    file = files.session_file(id),
    log = log.new(opts.on_log, opts.on_state),
    decoder = decode.new(),
    on_state = opts.on_state,
    on_request = opts.on_request,
    init = util.ready(),
    model = opts.config.model,
    effort = opts.config.effort,
    working = false,
    thinking = false,
    unread = {},
    started_prompts = {},
    foreground = {},
    notifications = {},
    permissions = {},
  }, Agent)

  local exists = vim.uv.fs_stat(agent.file) ~= nil
  local fork = not exists and forks[id] or {}
  local args = {
    '-p',
    '--input-format=stream-json',
    '--output-format=stream-json',
    '--verbose',
    '--include-partial-messages', -- which say when it's thinking
    '--replay-user-messages', -- prompts render when Claude Code reads them
    '--permission-prompt-tool=stdio',
    '--disallowedTools=AskUserQuestion',
    '--permission-mode=' .. opts.config.permission_mode,
    '--model=' .. opts.config.model,
    '--effort=' .. opts.config.effort,
    exists and '--resume' or '--session-id',
    id,
  }
  -- which keeps the history up to and including the entry
  if fork.at then
    vim.list_extend(args, { '--resume', fork.session, '--resume-session-at', fork.at, '--fork-session' })
  end
  if opts.name ~= nil then vim.list_extend(args, { '--name', opts.name }) end
  agent.rpc = rpc.start_agent(opts.config, args, {
    name = 'claude',
    on_message = function(msg) agent:on_message(msg) end,
    on_exit = function() agent:reset() end,
    -- inside Claude Code, CLAUDECODE would make it refuse to start
    env = { CLAUDECODE = '' },
  })
  -- an error raises in what waits for it, like the commands that every session loads
  agent:request({ subtype = 'initialize' }, function(err, response)
    agent.init:set(err, response)
    if err == nil then agent:report_context() end
  end)
  opts.on_state({ model = opts.config.model, effort = opts.config.effort, context_window = default_context_window })
  return agent
end

return M
