-- Treesitter highlights for the transcript and the input, since the buffer has no parser of its own. The transcript
-- only changes by appending, so each block highlights once, parsed on its own as its language, when it's first drawn,
-- and changing the input only parses the input. See PLAN.md

local input = require('otto.input')

local M = {}

local ns = vim.api.nvim_create_namespace('otto.highlights')
local input_ns = vim.api.nvim_create_namespace('otto.input.highlights')
local pending_ns = vim.api.nvim_create_namespace('otto.highlights.pending')

--- Highlighting of the blocks that haven't been drawn yet, by buffer and by the extmark that spans the block
local pending = {} --- @type table<integer, table<integer, fun(row: integer)>>

--- Captures that aren't highlights
local skipped = { spell = true, nospell = true, conceal = true }

--- @class otto.Place Where a line of the parsed text is in the buffer
--- @field row integer 0-indexed
--- @field col integer
--- @field hidden? boolean Parsed for its context, but not highlighted

--- @param places otto.Place[]
--- @param row integer of the first line
--- @param col integer
--- @param count integer of lines
--- @return otto.Place[] of lines below each other
local function below(places, row, col, count)
  for i = 0, count - 1 do
    table.insert(places, { row = row + i, col = col })
  end
  return places
end

--- Calls `fn` with each highlight of the text as `lang`, with the injections of the language, like code blocks in
--- markdown
--- @param text string
--- @param lang string Treesitter language, which may not have a parser
--- @param fn fun(range: Range6, hl_group: string, priority: integer)
local function captures(text, lang, fn)
  local ok, parser = pcall(vim.treesitter.get_string_parser, text, lang)
  if not ok then return end
  parser:parse(true)
  parser:for_each_tree(function(tree, language_tree)
    local language = language_tree:lang()
    local query = vim.treesitter.query.get(language, 'highlights')
    if query == nil then return end
    for id, node, metadata in query:iter_captures(tree:root(), text) do
      local name = query.captures[id]
      if not skipped[name] and not vim.startswith(name, '_') then
        local range = vim.treesitter.get_range(node, text, metadata[id])
        local priority = tonumber(metadata.priority or metadata[id] and metadata[id].priority)
        fn(range, '@' .. name .. '.' .. language, vim.hl.priorities.treesitter + (priority or 0))
      end
    end
  end)
end

--- Highlights the lines, which may be apart in the buffer, as `lang`
--- @param bufnr integer
--- @param namespace integer
--- @param places otto.Place[] of each line
--- @param lines string[]
--- @param lang string Treesitter language, which may not have a parser
--- @param transient? boolean Whether the highlights are deleted with their text, like the input's once it's sent
local function highlight(bufnr, namespace, places, lines, lang, transient)
  captures(table.concat(lines, '\n'), lang, function(range, hl_group, priority)
    local opts = { hl_group = hl_group, priority = priority, invalidate = transient, undo_restore = not transient }
    -- line by line, since the lines may be apart
    for line = range[1], range[4] do
      local place = places[line + 1]
      local first = line == range[1] and range[2] or 0
      local last = line == range[4] and range[5] or #(lines[line + 1] or '')
      if place ~= nil and not place.hidden and last > first then
        opts.end_col = place.col + last
        vim.api.nvim_buf_set_extmark(bufnr, namespace, place.row, place.col + first, opts)
      end
    end
  end)
end

--- Highlights a line as its filetype for virtual text, which doesn't take extmarks
--- @param text string
--- @param filetype string
--- @return otto.Chunks
function M.chunks(text, filetype)
  local lang = vim.treesitter.language.get_lang(filetype)
  local found = {}
  if lang ~= nil then
    captures(text, lang, function(range, hl_group, priority)
      local last = range[4] == 0 and range[5] or #text
      table.insert(found, { first = range[2], last = last, hl_group = hl_group, priority = priority, i = #found })
    end)
  end
  -- later ones take priority, like extmarks
  table.sort(found, function(a, b) return a.priority < b.priority or a.priority == b.priority and a.i < b.i end)
  local groups = {} -- of each byte
  for byte = 1, #text do
    groups[byte] = {}
  end
  for _, capture in ipairs(found) do
    for byte = capture.first + 1, capture.last do
      table.insert(groups[byte], capture.hl_group)
    end
  end
  local chunks = {}
  for byte = 1, #text do
    local last = chunks[#chunks]
    if last ~= nil and vim.deep_equal(last[2], groups[byte]) then
      last[1] = last[1] .. text:sub(byte, byte)
    else
      table.insert(chunks, { text:sub(byte, byte), groups[byte] })
    end
  end
  -- like virtual text reads back
  for _, chunk in ipairs(chunks) do
    if #chunk[2] <= 1 then chunk[2] = chunk[2][1] end
  end
  return chunks
end

local registered = false

--- Draws what waits to be, once something does, rather than whenever this loads
local function register()
  if registered then return end
  registered = true
  vim.api.nvim_set_decoration_provider(pending_ns, {
    on_win = function(_, _, bufnr, top, bottom)
      if next(pending[bufnr] or {}) == nil then return false end
      local opts = { overlap = true, limit = 1 }
      return #vim.api.nvim_buf_get_extmarks(bufnr, pending_ns, { top, 0 }, { bottom, -1 }, opts) > 0
    end,
    -- closed folds only draw their first line, and the extmarks set here draw with the line
    on_line = function(_, _, bufnr, row)
      local opts = { overlap = true, details = true }
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, pending_ns, { row, 0 }, { row, -1 }, opts)) do
        -- not of the block above, which ends where the row starts, like inside the closed fold above it
        if mark[2] == row or mark[4].end_row > row then
          local fn = pending[bufnr][mark[1]]
          pending[bufnr][mark[1]] = nil
          vim.api.nvim_buf_del_extmark(bufnr, pending_ns, mark[1])
          fn(mark[2])
        end
      end
    end,
  })
end

--- Highlights the block once it's drawn, since most of the transcript is folded or scrolled past
--- @param bufnr integer
--- @param row integer 0-indexed, of the first line
--- @param count integer of lines
--- @param fn fun(row: integer) Highlights the block, which starts at the row
local function lazily(bufnr, row, count, fn)
  if count == 0 then return end
  -- up to the next line, without the lines that go after it
  local opts = { end_row = row + count, end_right_gravity = false }
  local id = vim.api.nvim_buf_set_extmark(bufnr, pending_ns, row, 0, opts)
  pending[bufnr] = pending[bufnr] or {}
  pending[bufnr][id] = fn
  register()
end

--- Removes the highlights of the transcript, and those that wait to be drawn
--- @param bufnr integer
function M.clear(bufnr)
  pending[bufnr] = nil
  vim.api.nvim_buf_clear_namespace(bufnr, pending_ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
end

--- Highlights lines of the transcript, which don't change once they're appended
--- @param bufnr integer
--- @param row integer 0-indexed, of the first line
--- @param col integer Where the lines start in the buffer, past their indent
--- @param lines string[]
--- @param filetype string
function M.lines(bufnr, row, col, lines, filetype)
  local lang = vim.treesitter.language.get_lang(filetype)
  if lang == nil then return end
  lazily(bufnr, row, #lines, function(first) highlight(bufnr, ns, below({}, first, col, #lines), lines, lang) end)
end

--- @param bufnr integer
--- @param row integer
--- @param col integer
--- @param lines string[]
--- @param lang? string
local function diff(bufnr, row, col, lines, lang)
  local before, after
  -- hunks parse apart, since a string that one leaves open would continue into the next
  local function hunk()
    if before ~= nil then
      highlight(bufnr, ns, before.places, before.lines, lang)
      highlight(bufnr, ns, after.places, after.lines, lang)
    end
    before, after = { lines = {}, places = {} }, { lines = {}, places = {} }
  end
  hunk()
  local next_lnum -- in the new file, which jumps between hunks
  for i, line in ipairs(lines) do
    local sign = line:sub(1, 1)
    local number, code = line:match('^.(%s*%d+ )(.*)$')
    local lnum = tonumber(number)
    -- or at the gaps between them, like pi's
    if lnum == nil or (sign ~= '-' and next_lnum ~= nil and lnum ~= next_lnum) then hunk() end
    if sign ~= '-' then next_lnum = lnum and lnum + 1 end
    if number ~= nil then
      local code_col = col + 1 + #number
      local opts = { end_col = code_col - 1, hl_group = 'OttoLineNumber' }
      vim.api.nvim_buf_set_extmark(bufnr, ns, row + i - 1, col + 1, opts)
      if sign ~= '+' then
        table.insert(before.lines, code)
        -- the lines around the change highlight after it
        table.insert(before.places, { row = row + i - 1, col = code_col, hidden = sign == ' ' })
      end
      if sign ~= '-' then
        table.insert(after.lines, code)
        table.insert(after.places, { row = row + i - 1, col = code_col })
      end
    end
  end
  hunk()
end

--- Highlights a diff like pi's, with a line number after the sign of each line, as the language of its file, like
--- delta. The lines before the change and after it parse apart, each with the lines around the change
--- @param bufnr integer
--- @param row integer 0-indexed, of the first line
--- @param col integer Where the lines start in the buffer, past their indent
--- @param lines string[]
--- @param filetype? string
function M.diff(bufnr, row, col, lines, filetype)
  -- whose line numbers highlight without a parser too
  local lang = filetype and vim.treesitter.language.get_lang(filetype)
  lazily(bufnr, row, #lines, function(first) diff(bufnr, first, col, lines, lang) end)
end

--- Highlights the input as markdown again, after it changed
--- @param bufnr integer
function M.input(bufnr)
  local row = input.row(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, input_ns, row, -1)
  local lines = vim.api.nvim_buf_get_lines(bufnr, row, -1, false)
  highlight(bufnr, input_ns, below({}, row, 0, #lines), lines, 'markdown', true)
end

return M
