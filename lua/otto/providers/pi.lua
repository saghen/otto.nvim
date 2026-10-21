-- pi: `pi --mode rpc`, JSONL commands on stdin, and responses and events on stdout. Its session files and its events
-- hold the same messages, which `message` turns into the log
-- https://github.com/earendil-works/pi/blob/main/docs/rpc.md

local event = require('otto.event')
local log = require('otto.providers.log')
local proc = require('otto.proc')
local util = require('otto.util')

local M = { name = 'pi', icon = '󰏿 ' }

--- pi's tools, and those of extensions, which are otto's under another name
local tools = { search = 'grep', kagi_search = 'web_search', web_fetch = 'fetch', kagi_extract = 'fetch' }

local function environment(config, name)
  local value = config.env[name] or vim.env[name]
  return value ~= '' and value or nil
end

--- @param config? otto.ProviderConfig
--- @return string folder of the current folder's sessions
local function folder(config)
  config = config or require('otto.config').providers.pi
  local agent = environment(config, 'PI_CODING_AGENT_DIR') or '~/.pi/agent'
  local root = environment(config, 'PI_CODING_AGENT_SESSION_DIR') or (agent .. '/sessions')
  root = vim.fs.normalize(vim.fn.fnamemodify(vim.fs.normalize(root), ':p'))
  return vim.fs.joinpath(root, '--' .. (vim.fn.getcwd():sub(2):gsub('[/\\:]', '-')) .. '--')
end

local function files(config)
  local paths = {}
  local dir = folder(config)
  local scan = vim.uv.fs_scandir(dir)
  if scan == nil then return paths end
  while true do
    local name = vim.uv.fs_scandir_next(scan)
    if name == nil then break end
    local path = vim.fs.joinpath(dir, name)
    local stat = name:sub(-6) == '.jsonl' and vim.uv.fs_stat(path)
    if stat and stat.type == 'file' then table.insert(paths, path) end
  end
  return paths
end

--- @param id string
--- @return string? path of the session's file
local function session_file(id, config)
  -- Read paths literally: roots and project names can contain glob characters.
  return vim
    .iter(files(config))
    :find(function(file) return vim.fs.basename(file):match('^[^_]*_(.+)%.jsonl$') == id end)
end

--- @param name? string
--- @return string id of a new session, which is its name, or when it started
function M.new_id(name)
  -- which pi requires to start and end with a letter or digit
  local id = (name or ''):gsub('[^%w._-]+', '_'):gsub('^[^%w]+', ''):gsub('[^%w]+$', '')
  if id == '' then id = os.date('%Y_%m_%d_%H%M%S') end
  -- pi resumes the session of an id that exists
  if session_file(id) ~= nil then id = id .. '_' .. os.date('%H%M%S') end
  return id
end

--- pi's diffs number their lines, like "+12 code", and mark the gaps between hunks with "..."
--- @param diff string
--- @return otto.DiffLine[]
local function diff_lines(diff)
  -- lines around the change are numbered in the old file, so they move by the lines changed above them
  local shift = 0
  return vim.tbl_map(function(line)
    local sign, number, text = line:match('^([+%- ])%s*(%d+) ?(.*)$')
    if sign == nil then return { text = vim.trim(line) } end
    local lnum = tonumber(number) + (sign == ' ' and shift or 0)
    shift = shift + (sign == '+' and 1 or sign == '-' and -1 or 0)
    return { sign = sign, lnum = lnum, text = text }
  end, vim.split(diff, '\n'))
end

--- @class otto.PiState What the decoder keeps between messages
--- @field cost number Of the session so far

--- Adds a message of pi to the log, which is the same in its session files and its events
--- @param session_log otto.Log
--- @param state otto.PiState
--- @param msg table AgentMessage
--- @param at? integer When it ended, which is when its entry was saved, or now, since messages only say when they
--- started
local function message(session_log, state, msg, at)
  if msg.role == 'user' then
    session_log:user(vim.trim(event.text_of(msg.content)), at)
  elseif msg.role == 'assistant' then
    for _, part in ipairs(msg.content or {}) do
      if part.type == 'text' and vim.trim(part.text) ~= '' then session_log:text(vim.trim(part.text), at) end
      if part.type == 'toolCall' then
        session_log:tool_call(part.id, tools[part.name] or part.name, part.arguments, at)
      end
    end
    if msg.errorMessage ~= nil then session_log:error(msg.errorMessage, at) end
    -- aborting ends the answer with an error, like "The operation was aborted."
    local aborted = msg.stopReason == 'error' and (msg.errorMessage or ''):find('aborted', 1, true)
    if msg.stopReason == 'aborted' or aborted then session_log:interrupt() end
    if msg.usage ~= nil then
      state.cost = state.cost + (vim.tbl_get(msg.usage, 'cost', 'total') or 0)
      session_log:info({ context = msg.usage.totalTokens, cost = state.cost })
    end
  elseif msg.role == 'toolResult' then
    local output = util.trim_end(event.text_of(msg.content))
    local result = { id = msg.toolCallId, ok = not msg.isError, output = output }
    local diff = vim.tbl_get(msg, 'details', 'diff')
    if diff ~= nil then result.diff = diff_lines(diff) end
    -- the text of search results has HTML in it, but their details don't
    local results = vim.tbl_get(msg, 'details', 'results')
    if type(results) == 'table' and results[1] and results[1].url then
      result.output = vim
        .iter(results)
        :map(function(item) return (item.title and item.title .. '  ' or '') .. (item.url or '') end)
        :join('\n')
    end
    -- which extensions can add a line after, like "[Output truncated...]"
    local text, code, rest = output:match('^(.-)%s*Command exited with code (%d+)(%s*[^\n]*)$')
    if code ~= nil then
      text = text == '(no output)' and '' or text
      result.output = text == '' and vim.trim(rest) or text .. rest
      result.exit_code = tonumber(code)
    end
    session_log:tool_result(result, at)
  end
end

--- @class otto.PiHandle : otto.Handle
--- @field id string
--- @field proc otto.Proc
--- @field log otto.Log
--- @field state otto.PiState
--- @field on_status fun(status: otto.Status)
--- @field working boolean
--- @field on_settled? fun() For `ask`
local Handle = {}
Handle.__index = Handle

--- @param msg table A command, see docs/rpc-commands.md
--- @return fun(id: integer): table
local function command(msg)
  return function(id) return vim.tbl_extend('force', msg, { id = tostring(id) }) end
end

--- @param msg table
--- @param callback? fun(err?: string, data?: table) Notifies errors by default
function Handle:request(msg, callback) self.proc:request(command(msg), callback) end

--- @async
--- @param msg table
--- @return table?
function Handle:call(msg) return self.proc:call(command(msg)) end

--- Answers pi's extension dialogs, see docs/rpc-extension-ui.md
--- @param request table
function Handle:dialog(request)
  if request.method == 'notify' then
    local levels = { warning = vim.log.levels.WARN, error = vim.log.levels.ERROR }
    return util.notify(request.message, levels[request.notifyType] or vim.log.levels.INFO)
  end
  local function respond(value)
    local key = request.method == 'confirm' and 'confirmed' or 'value'
    self.proc:send({ type = 'extension_ui_response', id = request.id, [key] = value, cancelled = value == nil or nil })
  end
  if request.method == 'input' or request.method == 'editor' then
    self.on_status({
      type = 'request',
      kind = 'input',
      prompt = request.title,
      default = request.prefill,
      respond = respond,
    })
  elseif request.method == 'select' then
    self.on_status({
      type = 'request',
      kind = 'select',
      prompt = request.title,
      items = request.options,
      respond = respond,
    })
  elseif request.method == 'confirm' then
    local prompt = request.title .. (request.message and ': ' .. request.message or '')
    self.on_status({ type = 'request', kind = 'confirm', prompt = prompt, respond = respond })
  end
end

--- @param working? 'working' | 'thinking' | 'compacting'
function Handle:set_working(working) self.on_status({ type = 'working', state = working }) end

--- @param msg table
function Handle:on_message(msg)
  if msg.type == 'response' then
    self.proc:respond(msg.id, not msg.success and msg.error or nil, msg.data)
  elseif msg.type == 'extension_ui_request' then
    self:dialog(msg)
  elseif msg.type == 'agent_start' then
    self.working = true
    self:set_working('working')
  elseif msg.type == 'agent_settled' then
    self.working = false
    self.log:settle(msg.aborted)
    self:set_working(nil)
    if self.on_settled ~= nil then self.on_settled() end
  elseif msg.type == 'message_end' then
    message(self.log, self.state, msg.message)
  elseif msg.type == 'message_update' then
    local update = msg.assistantMessageEvent.type
    if update == 'thinking_start' then self:set_working('thinking') end
    if update == 'thinking_end' then self:set_working('working') end
  elseif msg.type == 'compaction_start' then
    self:set_working('compacting')
  elseif msg.type == 'compaction_end' then
    -- compacting can happen while the agent works
    self:set_working(self.working and 'working' or nil)
    if msg.result ~= nil then
      self.log:compaction({ summary = msg.result.summary, before = msg.result.tokensBefore })
    end
  elseif msg.type == 'queue_update' then
    self.on_status({ type = 'queue', steering = msg.steering, follow_up = msg.followUp })
  elseif msg.type == 'session_info_changed' then
    self.log:info({ name = msg.name })
  elseif msg.type == 'thinking_level_changed' then
    self.log:info({ effort = msg.level })
  end
end

--- The history from the session file, along its current branch
--- @async
function Handle:replay()
  local file = session_file(self.id, self.config)
  if file == nil then return end
  local entries = {}
  local by_id = {}
  for line in io.lines(file) do
    -- one bad line, like the last while it's written, doesn't lose the lines after it
    local ok, entry = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
    if not ok then
      util.notify('pi: ' .. tostring(entry))
    elseif entry.id ~= nil and entry.type ~= 'session' then
      table.insert(entries, entry)
      by_id[entry.id] = entry
    end
  end
  local branch = {}
  local entry = entries[#entries]
  while entry ~= nil do
    table.insert(branch, 1, entry)
    entry = entry.parentId and by_id[entry.parentId]
  end

  for _, current in ipairs(branch) do
    local at = event.time(current.timestamp)
    if current.type == 'message' then
      message(self.log, self.state, current.message, at)
    elseif current.type == 'compaction' then
      self.log:compaction({ summary = current.summary, before = current.tokensBefore }, at)
    elseif current.type == 'session_info' then
      self.log:info({ name = current.name })
    elseif current.type == 'model_change' then
      self.log:info({ model = current.modelId })
    elseif current.type == 'thinking_level_change' then
      self.log:info({ effort = current.thinkingLevel })
    end
  end
  self.log:finish()
end

--- @param text string
--- @param mode 'steer' | 'follow_up' While the agent works
function Handle:prompt(text, mode)
  self:request({ type = 'prompt', message = text, streamingBehavior = mode == 'follow_up' and 'followUp' or 'steer' })
end

function Handle:abort() self:request({ type = 'abort' }) end

--- @async
--- @param last? boolean Only the newest
--- @return string[]
function Handle:take_queue(last)
  local queued = self:call({ type = 'clear_queue' })
  if not last then return vim.list_extend(vim.list_extend({}, queued.steering), queued.followUp) end
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
function Handle:compact(instructions) self:call({ type = 'compact', customInstructions = instructions }) end

--- @async
--- @return string[] like "openrouter/deepseek/deepseek-v4.1-flash"
function Handle:models()
  local models = self:call({ type = 'get_available_models' }).models
  return vim.tbl_map(function(model) return model.provider .. '/' .. model.id end, models)
end

--- @async
--- @param model string like "openrouter/deepseek/deepseek-v4.1-flash"
function Handle:set_model(model)
  local provider, id = model:match('^([^/]+)/(.+)$')
  local result = self:call({ type = 'set_model', provider = provider, modelId = id })
  self.on_status({ type = 'info', model = id, window = result and result.contextWindow })
end

--- @async
function Handle:cycle_effort()
  -- pi reports the level as `thinking_level_changed`
  self:call({ type = 'cycle_thinking_level' })
end

--- @async
--- @param name string
function Handle:rename(name) self:call({ type = 'set_session_name', name = name }) end

--- @async
--- @return otto.Command[]
function Handle:commands()
  return vim.tbl_map(
    function(command) return { name = command.name, description = command.description } end,
    self:call({ type = 'get_commands' }).commands
  )
end

--- @async
--- @return { id: string, text: string }[] prompts to fork from
function Handle:fork_points()
  return vim.tbl_map(
    function(point) return { id = point.entryId, text = point.text } end,
    self:call({ type = 'get_fork_messages' }).messages
  )
end

--- @async
--- @param id string Of the prompt
--- @return { id: string, text: string }? the new session, and the prompt to edit
function Handle:fork(id)
  local fork = self:call({ type = 'fork', entryId = id })
  if fork.cancelled then return end
  return { id = self:call({ type = 'get_state' }).sessionId, text = fork.text, switched = true }
end

function Handle:close() self.proc:close() end

--- @param id string
--- @param args string[] for pi
--- @param config otto.ProviderConfig
--- @param on_log fun(event: otto.Event)
--- @param on_status fun(status: otto.Status)
--- @return otto.PiHandle
local function start(id, args, config, on_log, on_status)
  config = vim.deepcopy(config)
  for _, key in ipairs({ 'PI_CODING_AGENT_DIR', 'PI_CODING_AGENT_SESSION_DIR' }) do
    local path = environment(config, key)
    if path then config.env[key] = vim.fs.normalize(vim.fn.fnamemodify(vim.fs.normalize(path), ':p')) end
  end
  --- @type otto.PiHandle
  local handle = setmetatable({
    id = id,
    config = config,
    log = log.new(on_log, on_status),
    state = { cost = 0 },
    on_status = on_status,
    working = false,
  }, Handle)
  local launch_args = { '--mode', 'rpc' }
  if environment(config, 'PI_CODING_AGENT_SESSION_DIR') then
    vim.list_extend(launch_args, { '--session-dir', folder(config) })
  end
  handle.proc = proc.start_provider(config, vim.list_extend(launch_args, args), {
    name = 'pi',
    on_message = function(msg) handle:on_message(msg) end,
    on_exit = function()
      handle.log:settle(true)
      handle:set_working(nil)
      if handle.on_settled ~= nil then handle.on_settled('pi exited') end
    end,
  })
  return handle
end

--- Starts pi for the session, which it creates when it doesn't exist
--- @param id string
--- @param opts otto.OpenOpts
--- @return otto.PiHandle
function M.open(id, opts)
  local args = { '--session-id', id }
  if opts.name ~= nil then vim.list_extend(args, { '--name', opts.name }) end
  local handle = start(id, args, opts.config, opts.on_log, opts.on_status)
  util.run(function()
    local state = handle:call({ type = 'get_state' })
    local model = state.model or {}
    opts.on_status({
      type = 'info',
      name = state.sessionName,
      model = model.id,
      effort = model.reasoning and state.thinkingLevel or nil,
      window = model.contextWindow,
    })
  end)
  return handle
end

--- Sends `message` to a new pi without a saved session, and returns its final answer
--- @async
--- @param message string
--- @param opts otto.AskOpts
--- @return string
function M.ask(message, opts)
  local args = { '--no-session', '--no-mcp' }
  if opts.thinking then vim.list_extend(args, { '--thinking', opts.thinking }) end
  if opts.tools == false then table.insert(args, '--no-tools') end
  if type(opts.tools) == 'table' then vim.list_extend(args, { '--tools', table.concat(opts.tools, ',') }) end
  if opts.skills == false then table.insert(args, '--no-skills') end
  local failure
  local function on_log(log_event)
    if log_event.type == 'error' then failure = log_event.message end
  end
  -- dialogs of extensions, which nobody would answer
  local function on_status(status)
    if status.type == 'request' then status.respond(nil) end
  end
  local handle = start('ask', args, opts.config, on_log, on_status)
  local ok, answer = pcall(function()
    local err = vim.async.await(1, function(done)
      handle.on_settled = done
      handle:request({ type = 'prompt', message = message }, function(err)
        if err ~= nil then done(err) end
      end)
    end)
    -- like when the model's provider failed
    err = err or failure
    if err ~= nil then error(err, 0) end
    return handle:call({ type = 'get_last_assistant_text' }).text or ''
  end)
  handle:close()
  if not ok then error(answer, 0) end
  return answer
end

--- @param file string
--- @param modified integer
--- @return otto.SessionInfo
local function read(file, modified)
  local id = file:match('_([^/]+)%.jsonl$')
  local info = { provider = 'pi', id = id, messages = 0, modified = modified }
  local first_prompt
  -- decodes only the lines it needs, since sessions can be large
  for line in io.lines(file) do
    if line:find('"type":"session_info"', 1, true) then
      info.name = vim.json.decode(line).name
    elseif line:find('"type":"message"', 1, true) then
      info.messages = info.messages + 1
      if first_prompt == nil and line:find('"role":"user"', 1, true) then
        -- not prompts of only images
        local text = event.text_of(vim.json.decode(line).message.content)
        if vim.trim(text) ~= '' then first_prompt = text end
      end
    end
  end
  info.title = info.name or (first_prompt and vim.trim(first_prompt):gsub('%s+', ' ')) or id
  return info
end

--- @return { file: string, read: fun(file: string, modified: integer): otto.SessionInfo? }[]
function M.files()
  return vim.tbl_map(function(file) return { file = file, read = read } end, files())
end

return M
