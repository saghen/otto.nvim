-- pi's messages as the log, which are the same in its session files and its events, and the other entries of its
-- session files

local event = require('otto.event')
local util = require('otto.util')

local M = {}

--- pi's tools, and those of extensions, which are otto's under another name
local tools = { search = 'grep', kagi_search = 'web_search', web_fetch = 'fetch', kagi_extract = 'fetch' }

--- pi's diffs number their lines, like "+12 code", and mark the gaps between hunks with "..."
--- @param diff string
--- @return otto.DiffLine[]
local function parse_diff(diff)
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

--- @param provider? string Of the model, which older entries don't have
--- @param id string
--- @return string model like "openrouter/deepseek/deepseek-v4.1-flash", the same as `Agent:models`
function M.model_id(provider, id) return provider and provider .. '/' .. id or id end

--- @class otto.PiDecoder What the decoder keeps between messages
--- @field cost number Of the session so far
--- @field stop_reason? string Of the last answer in the file, which ends the agent's run unless it calls tools

--- @return otto.PiDecoder
function M.new() return { cost = 0 } end

--- Adds a message of pi to the log, which is the same in its session files and its events
--- @param log otto.Log
--- @param decoder otto.PiDecoder
--- @param msg table AgentMessage
--- @param at? integer When it ended, which is when its entry was saved, or now, since messages only say when they
--- started
function M.add(log, decoder, msg, at)
  if msg.role == 'user' then
    log:user(vim.trim(event.text_of(msg.content)), at)
  elseif msg.role == 'assistant' then
    for _, part in ipairs(msg.content or {}) do
      if part.type == 'text' and vim.trim(part.text) ~= '' then log:text(vim.trim(part.text), at) end
      if part.type == 'toolCall' then log:tool_call(part.id, tools[part.name] or part.name, part.arguments, at) end
    end
    if msg.errorMessage ~= nil then log:error(msg.errorMessage, at) end
    -- aborting ends the answer with an error, like "The operation was aborted."
    local aborted = msg.stopReason == 'error' and (msg.errorMessage or ''):find('aborted', 1, true)
    if msg.stopReason == 'aborted' or aborted then log:mark_aborted() end
    if msg.usage ~= nil then
      decoder.cost = decoder.cost + (vim.tbl_get(msg.usage, 'cost', 'total') or 0)
      log:patch_state({ context_tokens = msg.usage.totalTokens, cost = decoder.cost })
    end
  elseif msg.role == 'toolResult' then
    local output = util.trim_end(event.text_of(msg.content))
    local result = { id = msg.toolCallId, ok = not msg.isError, output = output }
    local diff = vim.tbl_get(msg, 'details', 'diff')
    if diff ~= nil then result.diff = parse_diff(diff) end
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
    log:tool_result(result, at)
  end
end

--- Adds an entry of the session file to the log, or to the state
--- @param log otto.Log
--- @param decoder otto.PiDecoder
--- @param entry table
function M.add_entry(log, decoder, entry)
  local at = event.parse_iso(entry.timestamp)
  if entry.type == 'message' then
    M.add(log, decoder, entry.message, at)
    if entry.message.role == 'assistant' then decoder.stop_reason = entry.message.stopReason end
  elseif entry.type == 'compaction' then
    -- after a run that ended, like /compact between turns, which comes after the end of its turn, like live
    if decoder.stop_reason and decoder.stop_reason ~= 'toolUse' then log:end_turn() end
    log:compaction({ summary = entry.summary, before = entry.tokensBefore }, at)
  elseif entry.type == 'session_info' then
    log:patch_state({ name = entry.name })
  elseif entry.type == 'model_change' then
    log:patch_state({ model = M.model_id(entry.provider, entry.modelId) })
  elseif entry.type == 'thinking_level_change' then
    log:patch_state({ effort = entry.thinkingLevel })
  end
end

return M
