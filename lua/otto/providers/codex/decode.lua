-- Codex's items as the log, which are the same in its history and once they complete. Items have no times, so they
-- take those of their turns

local diff = require('otto.providers.diff')
local event = require('otto.event')
local util = require('otto.util')

local M = {}

--- @param item table commandExecution
--- @return string like "cat a.txt", without the `bash -lc` that Codex runs it with
local function unwrap_shell(item)
  local quoted = item.command:match('^%S+ %-lc (.+)$')
  if quoted == nil then return item.command end
  -- with the single quotes inside it unescaped, which are '"'"'
  local single = quoted:match("^'(.*)'$")
  return single and (single:gsub([['"'"']], "'")) or quoted:match('^"(.*)"$') or quoted
end

--- Commands that only read, list or search become otto's tools for those, like Codex's own UI shows them
--- @param item table commandExecution
--- @return string tool
--- @return table args
local function shell_tool(item)
  local actions = item.commandActions or {}
  local action = #actions == 1 and actions[1] or {}
  -- like `sed -n '10,20p' file`
  local offset = tonumber(action.command and action.command:match('^sed %-n [\'"]?(%d+)[,p]') or nil)
  -- unlike reads of the end of the file, which don't say where they start
  if action.type == 'read' and not (action.command or ''):match('^tail') then
    return 'read', { path = action.path, offset = offset }
  end
  if action.type == 'listFiles' then return 'ls', { path = action.path or '.' } end
  if action.type == 'search' then return 'grep', { pattern = action.query or action.command, path = action.path } end
  return 'bash', { command = unwrap_shell(item) }
end

--- @param change { diff: string, kind: { type: string } }
--- @return otto.DiffLine[]
local function parse_change(change)
  -- a deleted file's diff is its contents, without signs
  local deleted = change.kind.type == 'delete'
  local lines = {}
  local hunk = { old = 1, new = 1, lines = {} }
  local function flush() vim.list_extend(lines, diff.hunk(hunk.lines, hunk.old, hunk.new)) end
  for _, line in ipairs(vim.split(change.diff:gsub('\n$', ''), '\n')) do
    local old_start, new_start = line:match('^@@ %-(%d+),?%d* %+(%d+),?%d* @@')
    if old_start ~= nil then
      flush()
      hunk = { old = tonumber(old_start), new = tonumber(new_start), lines = {} }
    else
      table.insert(hunk.lines, deleted and '-' .. line or line)
    end
  end
  flush()
  return lines
end

--- @class otto.CodexDecoder What the decoder keeps of the thread between items
--- @field agents table<string, table> Args of the tools that started subagents, by thread

--- @return otto.CodexDecoder
function M.new() return { agents = {} } end

--- Tool calls of an item, of which file changes have one per file
--- @param item table
--- @return { id: string, tool: string, args: table }[]
function M.calls(item)
  local function call(id, tool, args) return { id = id, tool = tool, args = args } end
  if item.type == 'commandExecution' then return { call(item.id, shell_tool(item)) } end
  if item.type == 'webSearch' then return { call(item.id, 'web_search', { query = item.query }) } end
  if item.type == 'mcpToolCall' then return { call(item.id, item.tool, item.arguments) } end
  if item.type ~= 'fileChange' then return {} end
  return vim
    .iter(ipairs(item.changes))
    :map(function(i, change)
      local id = item.id .. ':' .. i
      -- the diff of a new file is its content
      if change.kind.type == 'add' then return call(id, 'write', { path = change.path, content = change.diff }) end
      return call(id, 'edit', { path = change.path })
    end)
    :totable()
end

--- @param item table
--- @return otto.ToolResult[]
local function results(item)
  if item.type == 'commandExecution' then
    local ok = item.status == 'completed' and (item.exitCode or 0) == 0
    return { { id = item.id, ok = ok, output = util.trim_end(item.aggregatedOutput or ''), exit_code = item.exitCode } }
  end
  if item.type == 'webSearch' then return { { id = item.id, ok = true, output = '' } } end
  if item.type == 'mcpToolCall' then
    local output = item.error and item.error.message or event.text_of(item.result and item.result.content)
    return { { id = item.id, ok = item.error == nil, output = util.trim_end(output) } }
  end
  if item.type ~= 'fileChange' then return {} end
  local ok = item.status == 'completed'
  return vim
    .iter(ipairs(item.changes))
    :map(function(i, change)
      local lines = ok and change.kind.type ~= 'add' and parse_change(change) or nil
      return { id = item.id .. ':' .. i, ok = ok, output = '', diff = lines }
    end)
    :totable()
end

--- Subagents, which Codex's history only has the starts and ends of, the end as a second result of the tool
--- @param log otto.Log
--- @param decoder otto.CodexDecoder
--- @param item table subAgentActivity
--- @param at? integer
local function add_activity(log, decoder, item, at)
  local thread = item.agentThreadId
  if item.kind == 'started' then
    -- named after their paths, since their nicknames are on their threads
    local name = vim.fs.basename(item.agentPath or '')
    name = name ~= '' and name or thread:sub(-8)
    decoder.agents[thread] = { description = name, type = item.model, background = true }
  end
  local args = decoder.agents[thread]
  if args == nil or item.kind == 'interacted' then return end
  local ok = item.kind == 'started' or item.kind == 'completed'
  log:tool_call(item.id, 'agent', args, at)
  log:tool_result({ id = item.id, ok = ok, output = '' }, at)
end

--- Adds a completed item to the log, of which the tool calls may have been added when it started
--- @param log otto.Log
--- @param decoder otto.CodexDecoder
--- @param item table
--- @param announced table<string, true> Tool calls in the log already
--- @param at? integer
function M.add(log, decoder, item, announced, at)
  if item.type == 'userMessage' then return log:user(vim.trim(event.text_of(item.content)), at) end
  if item.type == 'agentMessage' then
    -- prompts after commentary steer the turn, which only ends when Codex says so
    if vim.trim(item.text) ~= '' then log:text(vim.trim(item.text), at, item.phase == 'commentary') end
    return
  end
  -- Codex keeps the summary to itself
  if item.type == 'contextCompaction' then return log:compaction({}, at) end
  if item.type == 'subAgentActivity' then return add_activity(log, decoder, item, at) end
  for _, call in ipairs(M.calls(item)) do
    if not announced[call.id] then log:tool_call(call.id, call.tool, call.args, at) end
    announced[call.id] = nil
  end
  for _, result in ipairs(results(item)) do
    -- commands say how long they ran, which shows once they take a while
    log:tool_result(result, at and item.durationMs and at + item.durationMs or at)
  end
end

--- @param turn table
--- @return integer? started
--- @return integer? completed In milliseconds since the epoch, like started
function M.times(turn)
  local started = turn.startedAt and turn.startedAt * 1000
  local completed = turn.completedAt and turn.completedAt * 1000
    or started and turn.durationMs and started + turn.durationMs
  return started, completed
end

return M
