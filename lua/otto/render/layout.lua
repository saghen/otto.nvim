-- What the transcript shows for the log, without a buffer: blocks of lines, separated by an empty line, except for
-- tools, which follow the text that explains them. Edits and writes stand on their own, and other tools group under a
-- summary on the line above the first. See `transcript.lua` for where they go

local tools = require('otto.render.tools')
local util = require('otto.util')

local M = {}

local group_indent = '  ' -- of the tools in a group
local body_indent = '  ' -- of the lines below the header of a tool
M.body_indent = body_indent

--- @alias otto.BlockKind 'user' | 'text' | 'tool' | 'error' | 'note'

--- @class otto.Block
--- @field kind otto.BlockKind
--- @field spaced boolean Whether an empty line comes before it
--- @field lines string[] The first is the header of tools
--- @field indent? string Before the header and the sections
--- @field header? otto.Chunks Of the first line, after the indent
--- @field sections? otto.Section[] Below the header
--- @field markdown? boolean Whether the lines highlight as markdown
--- @field diff? { filetype?: string } Whether the lines below the header are a diff, and its file's
--- @field highlights otto.BlockHighlight[]
--- @field targets otto.BlockTarget[] Locations that lines are about, which <CR> opens
--- @field fold? boolean Whether the tool folds below its header
--- @field group? { summary: otto.Chunks, first: boolean } Of the tool, which starts with its first tool
--- @field call? otto.BlockCall Of tools, for the actions on them

--- @class otto.BlockCall : otto.ToolCall
--- @field id? string Of the call
--- @field output? string Whole, which the lines may only show the start of

--- @class otto.BlockHighlight
--- @field index integer Of the line in the block, from 0
--- @field hl_group string
--- @field col? integer Of the whole line by default
--- @field end_col? integer To the end of the line by default

--- @class otto.BlockTarget Lines that are about a location, from their first
--- @field index integer Of the first line in the block, from 0
--- @field count? integer Of lines, 1 by default
--- @field path? string
--- @field lnum? integer Of the first line, which the next lines count up from
--- @field parse? 'diff' | 'location' Whether the line number, or the location, comes from the text of each line
--- @field col? integer Where the location starts in the lines

--- @class otto.Op
--- @field type 'block' | 'turn_end' Folds the groups of the turn, which stay open while it runs
--- @field block? otto.Block

--- @class otto.LayoutCall : otto.ToolCall
--- @field at? integer When it was called

--- @class otto.Layout
--- @field last_kind? otto.BlockKind Kind of the last block, which spaces the next one
--- @field group? { tools: string[], failed: integer } Tools since the last block of another kind
--- @field calls table<string, otto.LayoutCall> Tool calls by id, until their result arrives
local Layout = {}
Layout.__index = Layout

--- @return otto.Layout
function M.new() return setmetatable({ calls = {} }, Layout) end

--- Whether a block of `kind` would have an empty line above it, unlike tools right below the text that explains them,
--- and below each other
--- @param kind otto.BlockKind
--- @return boolean
function Layout:spaced(kind) return not (kind == 'tool' and (self.last_kind == 'tool' or self.last_kind == 'text')) end

--- @class otto.NewBlock : otto.Block Of `Layout:block`, which spaces it, without highlights or targets by default
--- @field spaced? boolean
--- @field highlights? otto.BlockHighlight[]
--- @field targets? otto.BlockTarget[]

--- @param block otto.NewBlock
--- @return otto.Op[]
function Layout:block(block)
  block.spaced = self:spaced(block.kind)
  block.highlights = block.highlights or {}
  block.targets = block.targets or {}
  if block.group == nil then self.group = nil end
  self.last_kind = block.kind
  --- @cast block otto.Block
  return { { type = 'block', block = block } }
end

--- Lines below the header, with their highlights and targets
--- @param header otto.Chunks
--- @param sections otto.Section[]
--- @param indent string
--- @param highlights otto.BlockHighlight[]
--- @param targets otto.BlockTarget[]
--- @return string[]
local function tool_lines(header, sections, indent, highlights, targets)
  local lines = { indent .. util.join(header) }
  local col = #indent + #body_indent
  for _, section in ipairs(sections) do
    local before = #lines - 1 -- index of the line before the section
    for _, line in ipairs(section.lines) do
      -- without trailing whitespace on blank lines
      table.insert(lines, line == '' and '' or indent .. body_indent .. line)
    end
    local count = #section.lines
    if section.path and count > 0 then
      table.insert(targets, { index = before + 1, count = count, path = section.path, lnum = section.lnum })
    end
    if section.locations and count > 0 then
      table.insert(targets, { index = before + 1, count = count, parse = 'location', col = col })
    end
    for _, location in ipairs(section.locations and tools.locations(section.lines) or {}) do
      local index = before + location.index
      local path_end = col + #location.path
      table.insert(highlights, { index = index, col = col, end_col = path_end, hl_group = 'OttoPath' })
      local lnum_end = path_end + 1 + location.width
      table.insert(highlights, { index = index, col = path_end + 1, end_col = lnum_end, hl_group = 'OttoLineNumber' })
    end
    if (section.truncated or 0) > 0 then
      table.insert(lines, ('%s%s... %d more lines'):format(indent, body_indent, section.truncated))
      table.insert(highlights, { index = #lines - 1, col = col, hl_group = 'OttoToolDetail' })
    end
  end
  return lines
end

--- @class otto.ToolBlockFields Of a tool's block, besides its lines
--- @field call? otto.BlockCall
--- @field diff? { filetype?: string }
--- @field highlights? otto.BlockHighlight[] Besides those of the sections
--- @field targets? otto.BlockTarget[] Besides those of the sections

--- A tool's block, with the lines of its header and sections
--- @param header otto.Chunks
--- @param sections otto.Section[]
--- @param indent string
--- @param fields? otto.ToolBlockFields
--- @return otto.NewBlock
local function new_tool_block(header, sections, indent, fields)
  fields = fields or {}
  local highlights, targets = {}, {}
  local lines = tool_lines(header, sections, indent, highlights, targets)
  return {
    kind = 'tool',
    lines = lines,
    indent = indent,
    header = header,
    sections = sections,
    highlights = vim.list_extend(highlights, fields.highlights or {}),
    targets = vim.list_extend(targets, fields.targets or {}),
    call = fields.call,
    diff = fields.diff,
  }
end

--- A tool on its own, which folds below its header
--- @param kind 'tool' | 'note'
--- @param header otto.Chunks
--- @param sections otto.Section[]
--- @param fields? otto.ToolBlockFields
--- @return otto.Op[]
function Layout:tool_block(kind, header, sections, fields)
  local block = new_tool_block(header, sections, '', fields)
  block.kind = kind
  -- in insert mode, a single line inserted right below a fold joins it, so blocks are never a single line there
  block.fold = true
  return self:block(block)
end

--- @param tokens integer
--- @return string like "120k"
local function thousands(tokens) return math.floor(tokens / 1000) .. 'k' end

--- @param text string
--- @return string[]
local function split(text) return vim.split(text, '\n') end

--- Edits show their diff since that's what matters, with the changed lines highlighted, and the code as its language
--- @param id string Of the call
--- @param call otto.ToolCall
--- @param diff otto.DiffLine[]
--- @return otto.Op[]
function Layout:diff(id, call, diff)
  local header = tools.diff_header(call, diff)
  local lines, first_changed = tools.format_diff(diff)
  -- a string, which `display_call` checked
  local path = call.args.path --[[@as string?]]

  local targets = path
      and {
        { index = 0, path = path, lnum = first_changed },
        { index = 1, count = #lines, path = path, parse = 'diff' },
      }
    or {}
  local highlights = {}
  for i, line in ipairs(diff) do
    local hl_group = line.sign == '+' and 'DiffAdd' or line.sign == '-' and 'DiffDelete' or nil
    if hl_group ~= nil then table.insert(highlights, { index = i, hl_group = hl_group }) end
  end
  return self:tool_block('tool', header, { { lines = lines } }, {
    targets = targets,
    highlights = highlights,
    diff = { filetype = path and vim.filetype.match({ filename = path }) },
    call = { id = id, tool = call.tool, args = call.args },
  })
end

--- Adds the tool to the group of tools since the last block of another kind, or starts one
--- @param name string Of the tool
--- @param failed boolean
--- @param header otto.Chunks
--- @param sections otto.Section[]
--- @param count integer Of what the summary counts, like the pages that one tool read
--- @param fields? otto.ToolBlockFields
--- @return otto.Op[]
function Layout:add_to_group(name, failed, header, sections, count, fields)
  local group = self.group or { tools = {}, failed = 0 }
  for _ = 1, count do
    table.insert(group.tools, name)
  end
  if failed then group.failed = group.failed + 1 end

  local block = new_tool_block(header, sections, group_indent, fields)
  block.fold = #block.lines > 1
  block.group = { summary = tools.summary(group.tools, group.failed), first = self.group == nil }
  local ops = self:block(block)
  self.group = group
  return ops
end

--- @param result otto.ToolResultEvent
--- @return otto.Op[]
function Layout:tool_result(result)
  local call = self.calls[result.id] or { tool = '?', args = {} }
  self.calls[result.id] = nil
  local tool = call.tool
  local args = call.args
  if result.diff ~= nil then return self:diff(result.id, call, result.diff) end

  if tool == 'write' and result.ok then
    local section, header = tools.written(args)
    return self:tool_block('tool', header, { section }, {
      targets = { { index = 0, path = section.path } },
      call = { id = result.id, tool = tool, args = args },
    })
  end

  local section = tools.output_section(tool, args, result.output or '')
  local seconds = call.at and math.floor((result.at - call.at) / 1000)
  local header = tools.result_header(call, result, seconds, section.lines[1])
  local sections = tools.result_sections(call, section)
  local count = tool == 'fetch' and #args.urls or 1
  return self:add_to_group(tool, not result.ok, header, sections, count, {
    call = { id = result.id, tool = tool, args = args, output = result.output },
    targets = section.path and { { index = 0, path = section.path, lnum = section.lnum } },
  })
end

--- @param compaction otto.CompactionEvent
--- @return otto.Op[]
function Layout:compaction(compaction)
  local before, after = compaction.before, compaction.after
  local tokens = after and before and ('  %s -> %s tokens'):format(thousands(before), thousands(after))
    or before and ('  from %s tokens'):format(thousands(before))
  local header = { { 'compacted', 'OttoToolName' }, tokens and { tokens, 'OttoToolDetail' } or nil }
  if compaction.summary == nil then
    return self:block({ kind = 'note', lines = { util.join(header) }, indent = '', header = header })
  end
  return self:tool_block('note', header, { { lines = split(compaction.summary), filetype = 'markdown' } })
end

--- Notes how long the agent worked, like "Worked for 2m 10s · done 4:19 p.m"
--- @param turn_end otto.TurnEndEvent
--- @return otto.Op[]
function Layout:turn_end(turn_end)
  -- live and replayed times can differ by milliseconds
  local seconds = math.max(math.floor((turn_end.at - turn_end.started) / 1000), 0)
  local at = math.floor(turn_end.at / 1000)
  -- by the hour, since %p is empty or translated in some locales
  local time = os.date('%I:%M', at):gsub('^0', '') .. (os.date('*t', at).hour >= 12 and ' p.m' or ' a.m')
  local text = ('Worked for %s · %s %s'):format(
    util.format_duration(seconds),
    turn_end.aborted and 'aborted' or 'done',
    time
  )
  local header = { { text, 'OttoStatusDone' } }
  return self:block({ kind = 'note', lines = { text }, indent = '', header = header })
end

-- otto.Event spelled out, since emmylua only narrows unions by their `type` then
-- luacheck: push no max line length
--- @param event otto.UserEvent | otto.TextEvent | otto.ErrorEvent | otto.ToolCallEvent | otto.ToolResultEvent | otto.CompactionEvent | otto.TurnEndEvent
--- @return otto.Op[] what changes in the transcript
function Layout:add(event)
  if event.type == 'user' then
    return self:block({ kind = 'user', lines = split(event.text), markdown = true })
  elseif event.type == 'text' then
    return self:block({ kind = 'text', lines = split(event.text), markdown = true })
  elseif event.type == 'error' then
    return self:block({ kind = 'error', lines = split(event.message) })
  elseif event.type == 'tool_call' then
    local call = tools.display_call(event.tool, event.args)
    self.calls[event.id] = { tool = call.tool, args = call.args, at = event.at }
  elseif event.type == 'tool_result' then
    return self:tool_result(event)
  elseif event.type == 'compaction' then
    return self:compaction(event)
  elseif event.type == 'turn_end' then
    local ops = (event.worked or event.aborted) and self:turn_end(event) or {}
    self.group = nil
    self.calls = {}
    table.insert(ops, { type = 'turn_end' })
    return ops
  end
  return {}
end
-- luacheck: pop

return M
