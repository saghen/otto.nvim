-- The transcript is above the input, which only the plugin edits, and only by appending the blocks of `layout.lua`.
-- Tool output is indented below its header, highlighted as its language, see `highlight.lua`. Prompts are highlighted
-- like the quickfix line. An empty line and a separator come before the input

local folds = require('otto.render.folds')
local highlight = require('otto.render.highlight')
local input = require('otto.input')
local layout = require('otto.render.layout')
local tools = require('otto.render.tools')
local util = require('otto.util')

local ns = vim.api.nvim_create_namespace('otto')
local separator_ns = vim.api.nvim_create_namespace('otto.separators')
local user_ns = vim.api.nvim_create_namespace('otto.prompts')
local call_ns = vim.api.nvim_create_namespace('otto.calls')
local summary_ns = vim.api.nvim_create_namespace('otto.summaries')
local target_ns = vim.api.nvim_create_namespace('otto.targets')
local separator = { { ('─'):rep(500), 'OttoSeparator' } } -- clipped to the window

--- @class otto.Target A location that a line of the transcript is about, which <CR> opens
--- @field path string
--- @field lnum? integer

--- @class otto.Transcript
--- @field bufnr integer
--- @field folds otto.Fold[]
--- @field targets table<integer, otto.BlockTarget> by extmark in `target_ns`, at their first line
--- @field calls table<integer, otto.BlockCall> by extmark in `call_ns`, over their tool's lines
--- @field group_fold? otto.Fold Of the last tools, from their summary, until it folds
--- @field pending_folds otto.Fold[] Of the groups of the turn that's running, which fold once it ends
--- @field on_change fun() After the transcript changed
local Transcript = {}
Transcript.__index = Transcript

local M = {}

--- @param bufnr integer
--- @param row integer
--- @return boolean
local function is_separator(bufnr, row)
  return #vim.api.nvim_buf_get_extmarks(bufnr, separator_ns, { row, 0 }, { row, 0 }, {}) > 0
end

--- Calls `fn` outside of the undo history, so that undoing in the input never removes output. It's called with the
--- 0-indexed row where the transcript ends, and the row of the input. Then adds the separator above the input
--- @param fn fun(row: integer, input_row: integer)
function Transcript:modify(fn)
  local bufnr = self.bufnr
  local undolevels = vim.bo[bufnr].undolevels
  local modifiable = vim.bo[bufnr].modifiable -- which the user may have turned off
  vim.bo[bufnr].undolevels = -1
  vim.bo[bufnr].modifiable = true

  local input_row = input.row(bufnr)
  -- the undo levels come back even when it fails
  local ok, err =
    pcall(fn, input_row > 0 and is_separator(bufnr, input_row - 1) and input_row - 2 or input_row, input_row)

  input_row = input.row(bufnr)
  if input_row > 0 and not is_separator(bufnr, input_row - 1) then
    vim.api.nvim_buf_set_lines(bufnr, input_row, input_row, false, { '', '' })
    vim.api.nvim_buf_set_extmark(bufnr, separator_ns, input_row + 1, 0, {
      virt_text = separator,
      virt_text_pos = 'overlay',
      hl_mode = 'combine', -- keeps the cursorline
    })
  end
  vim.bo[bufnr].undolevels = undolevels
  vim.bo[bufnr].modifiable = modifiable
  if not ok then error(err, 0) end
end

--- Puts the input back right below the separator, which moves with the text, unlike the input's mark. Edits in the
--- input can leave the mark below its start, like `P` on its first line or undoing a deletion there, or past the end
--- of the buffer, like deleting all of it
function Transcript:anchor()
  local bufnr = self.bufnr
  if not vim.bo[bufnr].modifiable then return end
  local separator_mark = vim.api.nvim_buf_get_extmarks(bufnr, separator_ns, -1, 0, { limit = 1 })[1]
  local row = separator_mark and separator_mark[2] + 1 or 0
  local missing = row + 1 - vim.api.nvim_buf_line_count(bufnr)
  if missing > 0 then
    -- with the edit that deleted the input, so that undoing brings it back, unless the edit was an undo
    pcall(vim.cmd.undojoin)
    vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, vim.split(('\n'):rep(missing - 1), '\n'))
  end
  if input.row(bufnr) ~= row then vim.api.nvim_buf_set_mark(bufnr, ':', row + 1, 0, {}) end
end

--- @param namespace integer
--- @param row integer
--- @param col integer where the chunks start
--- @param chunks otto.Chunks
function Transcript:highlight_chunks(namespace, row, col, chunks)
  for _, chunk in ipairs(chunks) do
    if chunk[2] ~= nil then
      vim.api.nvim_buf_set_extmark(self.bufnr, namespace, row, col, { hl_group = chunk[2], end_col = col + #chunk[1] })
    end
    if chunk.filetype ~= nil then highlight.lines(self.bufnr, row, col, { chunk[1] }, chunk.filetype) end
    col = col + #chunk[1]
  end
end

--- Inserts lines at the end of the transcript
--- @param block otto.Block
--- @param lines string[]
--- @return integer row of the first line
function Transcript:insert(block, lines)
  local bufnr = self.bufnr
  local start
  self:modify(function(row)
    local spaced = row > 0 and block.spaced
    start = spaced and row + 1 or row
    vim.api.nvim_buf_set_lines(bufnr, row, row, false, spaced and vim.list_extend({ '' }, lines) or lines)
    if block.kind == 'error' then
      vim.api.nvim_buf_set_extmark(bufnr, ns, start, 0, { hl_group = 'DiagnosticError', end_row = start + #lines })
    end
    if block.kind == 'user' then
      local opts = { line_hl_group = 'OttoPrompt', end_row = start + #lines - 1 }
      vim.api.nvim_buf_set_extmark(bufnr, user_ns, start, 0, opts)
    end
  end)
  return start
end

--- Adds the tool to its group, whose summary goes on its own line above the first
--- @param block otto.Block
--- @return integer row of the header
function Transcript:insert_grouped(block)
  local group = block.group --[[@as { summary: otto.Chunks, first: boolean }]]
  local summary = util.join(group.summary)
  local row
  -- or when the first failed to render
  if group.first or self.group_fold == nil then
    row = self:insert(block, vim.list_extend({ summary }, block.lines)) + 1
    self.group_fold = { top = row, bottom = row, nested = false }
    table.insert(self.pending_folds, self.group_fold)
  else
    local top = self.group_fold.top - 1
    self:modify(function() vim.api.nvim_buf_set_lines(self.bufnr, top, top + 1, false, { summary }) end)
    row = self:insert(block, block.lines)
  end
  vim.api.nvim_buf_clear_namespace(self.bufnr, summary_ns, self.group_fold.top - 1, self.group_fold.top)
  self:highlight_chunks(summary_ns, self.group_fold.top - 1, 0, group.summary)
  self.group_fold.bottom = row + #block.lines
  return row
end

--- @param block otto.Block
function Transcript:block(block)
  local bufnr = self.bufnr
  if block.group == nil then self.group_fold = nil end
  local row = block.group and self:insert_grouped(block) or self:insert(block, block.lines)
  if block.markdown then highlight.lines(bufnr, row, 0, block.lines, 'markdown') end
  local indent = block.indent or ''
  if block.header then self:highlight_chunks(ns, row, #indent, block.header) end
  local col = #indent + #layout.body_indent
  local first = row + 1
  for _, section in ipairs(block.sections or {}) do
    if section.filetype ~= nil then highlight.lines(bufnr, first, col, section.lines, section.filetype) end
    first = first + #section.lines + ((section.truncated or 0) > 0 and 1 or 0)
  end
  if block.diff ~= nil then highlight.diff(bufnr, row + 1, col, block.sections[1].lines, block.diff.filetype) end
  for _, hl in ipairs(block.highlights) do
    local opts = hl.col == nil and { line_hl_group = hl.hl_group }
      or hl.end_col and { hl_group = hl.hl_group, end_col = hl.end_col }
      or { hl_group = hl.hl_group, end_row = row + hl.index + 1, strict = false }
    vim.api.nvim_buf_set_extmark(bufnr, ns, row + hl.index, hl.col or 0, opts)
  end
  if block.call ~= nil then
    local id = vim.api.nvim_buf_set_extmark(bufnr, call_ns, row, 0, { end_row = row + #block.lines - 1 })
    self.calls[id] = block.call
  end
  for _, target in ipairs(block.targets) do
    self.targets[vim.api.nvim_buf_set_extmark(bufnr, target_ns, row + target.index, 0, {})] = target
  end
  if block.fold then folds.add(bufnr, self.folds, row + 1, row + #block.lines, block.group ~= nil) end
end

--- Folds the groups of the turn, which stay open while it runs
function Transcript:fold_groups()
  for _, fold in ipairs(self.pending_folds) do
    folds.add(self.bufnr, self.folds, fold.top, fold.bottom, false)
  end
  self.pending_folds = {}
  self.group_fold = nil
end

--- @param op otto.Op
function Transcript:apply(op)
  if op.type == 'block' then self:block(op.block) end
  if op.type == 'turn_end' then self:fold_groups() end
  self.on_change()
end

--- Folds the transcript in the current window, which has 'foldmethod' set to manual
function Transcript:fold() folds.apply(self.folds) end

--- @param row integer 0-indexed
--- @return otto.Target? that the row is about, like the file and line of a line in a diff
function Transcript:target_at(row)
  -- the closest target above, which may span the row
  local marks = vim.api.nvim_buf_get_extmarks(self.bufnr, target_ns, { row, -1 }, { 0, 0 }, { limit = 1 })
  local target = marks[1] and self.targets[marks[1][1]]
  if target == nil or row >= marks[1][2] + (target.count or 1) then return end
  local line = vim.api.nvim_buf_get_lines(self.bufnr, row, row + 1, false)[1]
  if target.parse == 'diff' then
    -- removed lines are numbered in the old file, so they open at the next line of the new one
    local lines = vim.api.nvim_buf_get_lines(self.bufnr, row, marks[1][2] + target.count, false)
    local sign, lnum = line:match('^%s*([+-]?)%s*(%d+) ')
    for _, next_line in ipairs(sign == '-' and lines or {}) do
      local next_sign, next_lnum = next_line:match('^%s*([+-]?)%s*(%d+) ')
      if next_lnum == nil then break end
      if next_sign ~= '-' then
        lnum = next_lnum
        break
      end
    end
    return lnum and { path = target.path, lnum = tonumber(lnum) }
  end
  if target.parse == 'location' then
    local path, lnum = tools.location(line:sub(target.col + 1))
    return path and { path = path, lnum = tonumber(lnum) }
  end
  return { path = target.path, lnum = target.lnum and target.lnum + row - marks[1][2] }
end

--- @param row integer 0-indexed
--- @return boolean
function Transcript:is_prompt(row)
  local opts = { overlap = true, limit = 1 }
  return #vim.api.nvim_buf_get_extmarks(self.bufnr, user_ns, { row, 0 }, { row, 0 }, opts) > 0
end

--- @param mark vim.api.keyset.get_extmark_item
--- @return otto.TranscriptPrompt
function Transcript:prompt(mark)
  local lines = vim.api.nvim_buf_get_lines(self.bufnr, mark[2], mark[4].end_row + 1, false)
  return { row = mark[2], text = table.concat(lines, '\n') }
end

--- @class otto.TranscriptPrompt
--- @field row integer 0-indexed
--- @field text string

--- @return otto.TranscriptPrompt[] oldest first
function Transcript:prompts()
  local marks = vim.api.nvim_buf_get_extmarks(self.bufnr, user_ns, 0, -1, { details = true })
  return vim.tbl_map(function(mark) return self:prompt(mark) end, marks)
end

--- @param row integer 0-indexed
--- @return otto.BlockCall? Of the tool that the row is in
function Transcript:call_at(row)
  local opts = { overlap = true, limit = 1 }
  local mark = vim.api.nvim_buf_get_extmarks(self.bufnr, call_ns, { row, 0 }, { row, 0 }, opts)[1]
  return mark and self.calls[mark[1]]
end

--- @param row integer 0-indexed
--- @param backward boolean
--- @return integer? row of the next prompt
function Transcript:find_prompt(row, backward)
  local start = backward and { math.max(row - 1, 0), 0 } or { row + 1, 0 }
  local marks = vim.api.nvim_buf_get_extmarks(self.bufnr, user_ns, start, backward and 0 or -1, { limit = 1 })
  return marks[1] and marks[1][2]
end

--- Removes the submitted prompt, which the prompt buffer leaves in place. It returns as a user block when the agent
--- reads it
--- @param text string
function Transcript:remove_submitted(text)
  local count = #vim.split(text, '\n')
  self:modify(
    function(_, input_row) vim.api.nvim_buf_set_lines(self.bufnr, input_row - count, input_row, false, {}) end
  )
  self.on_change()
end

--- Drops the highlights that wait to be drawn, which hold the lines of their blocks
function Transcript:close() highlight.clear(self.bufnr) end

--- Starts the transcript of the buffer, removing what was there
--- @param bufnr integer
--- @param on_change fun()
--- @return otto.Transcript
function M.new(bufnr, on_change)
  local transcript = setmetatable(
    { bufnr = bufnr, folds = {}, targets = {}, calls = {}, pending_folds = {}, on_change = on_change },
    Transcript
  )
  highlight.clear(bufnr)
  for _, namespace in ipairs({ ns, separator_ns, user_ns, summary_ns, target_ns, call_ns }) do
    vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
  end
  transcript:modify(function(_, input_row) vim.api.nvim_buf_set_lines(bufnr, 0, input_row, false, {}) end)
  return transcript
end

return M
