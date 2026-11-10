-- Claude Code's entries as the log, which are the same in its session files and its stream, along with what the
-- decoder keeps between them

local diff = require('otto.providers.diff')
local event = require('otto.event')
local util = require('otto.util')

local M = {}

--- Claude Code's tools as otto's
local tools = {
  Read = function(input) return 'read', { path = input.file_path, offset = input.offset, limit = input.limit } end,
  Edit = function(input) return 'edit', { path = input.file_path } end,
  MultiEdit = function(input) return 'edit', { path = input.file_path } end,
  Write = function(input) return 'write', { path = input.file_path, content = input.content } end,
  Bash = function(input)
    return 'bash', { command = input.command, description = input.description, background = input.run_in_background }
  end,
  Grep = function(input) return 'grep', { pattern = input.pattern, path = input.path } end,
  Glob = function(input) return 'find', { pattern = input.pattern, path = input.path } end,
  WebSearch = function(input) return 'web_search', { query = input.query } end,
  WebFetch = function(input) return 'fetch', { urls = { input.url } } end,
  Agent = function(input)
    local args = { description = input.description, prompt = input.prompt, type = input.subagent_type }
    args.background = input.run_in_background
    return 'agent', args
  end,
}
tools.Task = tools.Agent

--- Edits come with hunks
--- @param patch { oldStart: integer, newStart: integer, lines: string[] }[]
--- @return otto.DiffLine[]
local function parse_patch(patch)
  local lines = {}
  for _, hunk in ipairs(patch) do
    vim.list_extend(lines, diff.hunk(hunk.lines, hunk.oldStart, hunk.newStart))
  end
  return lines
end

--- @param usage table Of an answer
--- @return integer tokens in the context
local function context_tokens(usage)
  return usage.input_tokens + usage.cache_read_input_tokens + usage.cache_creation_input_tokens
end

--- Tags of what Claude Code adds as prompts, like the output of local commands such as /compact, and the caveats around
--- them
local tags = {
  ['task-notification'] = true,
  ['command-name'] = true,
  ['command-message'] = true,
  ['local-command-caveat'] = true,
  ['local-command-stdout'] = true,
  ['local-command-stderr'] = true,
  ['system-reminder'] = true,
  ['bash-input'] = true,
  ['bash-stdout'] = true,
  ['bash-stderr'] = true,
  -- messages from other sessions
  ['cross-session-message'] = true,
  ['agent-message'] = true,
}

--- @param text string
--- @return boolean whether Claude Code added it, rather than the user, who may start a prompt with HTML
function M.is_tagged(text) return tags[text:match('^<([%w-]+)[%s>]')] == true end

--- @class otto.ClaudeDecoder What the decoder keeps between entries
--- @field compaction { before?: integer, after?: integer } The last one
--- @field model? string
--- @field titled? boolean Whether the session has a custom title, which AI titles don't replace
--- @field calls table<string, { tool: string, args: table }> By id, for the subagents and commands that they start
--- @field agents table<string, string> Calls that started subagents, by subagent
--- @field handbacks table<string, string> Reports of subagents by id, which arrive before they end
--- @field notified table<string, true> Ends of subagents and commands, which the stream and the file may both have
--- @field prompts { uuid: string, parent?: string, text: string }[] With the entry before each, which forks resume at
--- @field last? string Uuid of the last entry, which the stream's entries don't say they follow

--- @return otto.ClaudeDecoder
function M.new() return { compaction = {}, calls = {}, agents = {}, handbacks = {}, notified = {}, prompts = {} } end

--- @param log otto.Log
--- @param decoder otto.ClaudeDecoder
--- @param uuid string Of its entry
--- @param parent? string Uuid of the entry before it
--- @param text string
--- @param at? integer
local function add_prompt(log, decoder, uuid, parent, text, at)
  table.insert(decoder.prompts, { uuid = uuid, parent = parent, text = vim.trim(text) })
  log:user(vim.trim(text), at)
end

--- Adds a prompt that Claude Code started a turn with, which it only echoes with the answer, after the last entry
--- @param log otto.Log
--- @param decoder otto.ClaudeDecoder
--- @param uuid string Of its entry, which the echo has
--- @param text string
function M.add_started_prompt(log, decoder, uuid, text)
  local parent = decoder.last
  decoder.last = uuid
  add_prompt(log, decoder, uuid, parent, text)
end

--- @param text string
--- @param name string Of the tag
--- @return string?
local function tag(text, name)
  local escaped = name:gsub('%-', '%%-')
  return text:match('<' .. escaped .. '>(.-)</' .. escaped .. '>')
end

--- The end of a subagent or a command, as Claude Code adds it to the conversation, like the stream's
--- `task_notification`
--- @param text string
--- @return table
local function parse_notification(text)
  return {
    task_id = tag(text, 'task-id'),
    tool_use_id = tag(text, 'tool-use-id'),
    status = tag(text, 'status'),
    summary = tag(text, 'summary'),
    result = tag(text, 'result'),
    output_file = tag(text, 'output-file'),
    usage = {
      total_tokens = tonumber(tag(text, 'subagent_tokens') or tag(text, 'total_tokens')),
      tool_uses = tonumber(tag(text, 'tool_uses')),
      duration_ms = tonumber(tag(text, 'duration_ms')),
    },
  }
end

--- Adds the end of a subagent or a command in the background, as a second result of the tool that started it
--- @param log otto.Log
--- @param decoder otto.ClaudeDecoder
--- @param notification table See `parse_notification`
--- @param at? integer
function M.add_task_end(log, decoder, notification, at)
  -- which the agent reads like a prompt
  log:interject()
  if notification.task_id == nil or notification.skip_transcript then return end
  local usage = notification.usage or {}
  local key = table.concat({ notification.task_id, notification.status or '', usage.duration_ms or '' }, '\0')
  if decoder.notified[key] then return end
  decoder.notified[key] = true
  local call = decoder.calls[notification.tool_use_id or decoder.agents[notification.task_id] or '']
  if call == nil or call.tool ~= 'bash' and call.tool ~= 'agent' then return end
  local ok = notification.status == 'completed'
  local output, code
  if call.tool == 'bash' then
    code = tonumber((notification.summary or ''):match('.*exit code (%d+)'))
    local file = notification.output_file and io.open(notification.output_file, 'r')
    output = file and file:read('*a') or ''
    if file then file:close() end
    code = code or tonumber(output:match('%[exited with code (%d+)%]%s*$'))
    output = output:gsub('%s*%[exited with code %d+%]%s*$', '')
    ok = ok and (code or 0) == 0
  else
    output = notification.handback_report
      or decoder.handbacks[notification.task_id]
      or notification.result
      or notification.summary
      or ''
    decoder.handbacks[notification.task_id] = nil
  end
  local id = notification.task_id .. ':end'
  log:tool_call(id, call.tool, call.args, at)
  log:tool_result({ id = id, ok = ok, output = util.trim_end(output), exit_code = code }, at)
end

--- @param log otto.Log
--- @param decoder otto.ClaudeDecoder
--- @param entry table
--- @param at? integer
local function add_tool_results(log, decoder, entry, at)
  local content = entry.message.content
  -- of the entry's only result, or a string, like the error of one that failed
  local details = entry.toolUseResult or entry.tool_use_result
  if type(details) ~= 'table' then details = {} end
  for _, block in ipairs(content) do
    if block.type == 'tool_result' then
      local patch = details.structuredPatch
      -- reads number their lines, but come with the file's content too
      local file = #content == 1 and vim.tbl_get(details, 'file', 'content') or nil
      local output = file or event.text_of(block.content or '')
      local result = { id = block.tool_use_id, ok = not block.is_error, output = util.trim_end(output) }
      -- new files come with an empty patch, and show their content
      if patch ~= nil and #patch > 0 then result.diff = parse_patch(patch) end
      local code, rest = result.output:match('^Exit code (%d+)\n?(.*)$')
      if code ~= nil then
        result.exit_code = tonumber(code)
        result.output = rest
      end
      local call = decoder.calls[block.tool_use_id] or {}
      local agent = call.tool == 'agent' and result.output:match('agentId: (%w+)')
      if agent then
        decoder.agents[agent] = block.tool_use_id
        -- which the agent may run in the background without being asked
        local async = details.isAsync or vim.startswith(result.output, 'Async agent')
        -- what's left is metadata, or the agent's answer when the turn waited for it
        result.output = async and '' or vim.trim((result.output:gsub('\n*agentId: .*$', '')))
      end
      -- where its output goes, which its end has
      if call.tool == 'bash' and call.args.background and result.ok then result.output = '' end
      log:tool_result(result, at)
    end
  end
end

--- @param body string Of a subagent's report, which Claude Code frames with a line before it, and indents
--- @return string
local function unframe(body)
  if not vim.startswith(body, '[Subagent hand-back]') then return body end
  return (body:gsub('^[^\n]*\n?', ''):gsub('^  ', ''):gsub('\n  ', '\n'))
end

--- Adds an entry of Claude Code to the log, which is the same in its session files and its stream
--- @param log otto.Log
--- @param decoder otto.ClaudeDecoder
--- @param entry table
function M.add(log, decoder, entry)
  local at = event.parse_iso(entry.timestamp)
  if entry.type == 'custom-title' then
    decoder.titled = true
    return log:patch_state({ name = entry.customTitle })
  end
  if entry.type == 'ai-title' then
    if not decoder.titled then log:patch_state({ name = entry.aiTitle }) end
    return
  end
  if entry.subtype == 'compact_boundary' then
    local metadata = entry.compactMetadata or entry.compact_metadata or {}
    local before = metadata.preTokens or metadata.pre_tokens
    local after = metadata.postTokens or metadata.post_tokens
    decoder.compaction = { before = before, after = after }
    if after ~= nil then log:patch_state({ context_tokens = after }) end
    return
  end
  local origin = type(entry.origin) == 'table' and entry.origin or {}
  -- like a subagent's report, which its end has, or a message from another agent
  if entry.type == 'user' and origin.kind == 'peer' then
    if origin.handback then decoder.handbacks[origin.from] = origin.handbackReportText or unframe(origin.body) end
    return log:interject()
  end
  if entry.isSidechain or entry.isMeta or entry.parent_tool_use_id ~= nil then return end
  local parent = entry.parentUuid or decoder.last
  decoder.last = entry.uuid or decoder.last
  -- prompts that the agent read while it worked, which the stream echoes like the others
  local attachment = entry.attachment or {}
  if attachment.type == 'queued_command' and vim.startswith(attachment.prompt or '', '<task-notification>') then
    return M.add_task_end(log, decoder, parse_notification(attachment.prompt), at)
  end
  local queued = type(attachment.prompt) == 'string' and attachment.prompt or nil
  if attachment.type == 'queued_command' and attachment.commandMode == 'prompt' then
    if queued and not M.is_tagged(queued) then return add_prompt(log, decoder, entry.uuid, parent, queued, at) end
    -- like messages from other sessions, which the agent reads like prompts
    return log:interject()
  end
  if entry.message == nil then return end
  local content = entry.message.content

  if entry.type == 'assistant' then
    local model = entry.message.model
    if model ~= nil and model ~= decoder.model and model ~= '<synthetic>' then
      decoder.model = model
      log:patch_state({ model = model })
    end
    -- like a failed request, which Claude Code adds as an answer
    if entry.isApiErrorMessage then return log:error(vim.trim(event.text_of(content)), at) end
    -- like "No response requested.", which ends a turn that was killed once the session resumes, or the output of
    -- commands like /rename, which only the stream has
    if model == '<synthetic>' then return log:end_turn(true) end
    for _, block in ipairs(content) do
      if block.type == 'text' and vim.trim(block.text) ~= '' then log:text(vim.trim(block.text), at) end
      if block.type == 'tool_use' then
        local name, args = (tools[block.name] or function(input) return block.name, input end)(block.input)
        decoder.calls[block.id] = { tool = name, args = args }
        log:tool_call(block.id, name, args, at)
      end
    end
    -- answers that Claude Code made itself have none, and some only have it for each of their iterations
    local tokens = entry.message.usage and context_tokens(entry.message.usage)
    if tokens and tokens > 0 then log:patch_state({ context_tokens = tokens }) end
    return
  end
  if entry.type ~= 'user' then return end

  local text = type(content) == 'string' and content or nil
  if entry.isCompactSummary then
    return log:compaction(
      { summary = event.text_of(content), before = decoder.compaction.before, after = decoder.compaction.after },
      at
    )
  end
  if type(content) == 'table' then
    add_tool_results(log, decoder, entry, at)
    if vim.iter(content):any(function(block) return block.type == 'tool_result' end) then return end
    text = event.text_of(content)
  end
  if text == nil then return end
  if vim.startswith(text, '[Request interrupted') then return log:mark_aborted() end
  if vim.startswith(text, '<task-notification>') then
    return M.add_task_end(log, decoder, parse_notification(text), at)
  end
  -- like /compact from Claude Code's own UI, which renders as the compaction
  if text == '/compact' or vim.startswith(text, '/compact ') then return end
  if M.is_tagged(text) then return log:interject() end
  add_prompt(log, decoder, entry.uuid, parent, text, at)
end

return M
