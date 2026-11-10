-- highlight.lua: treesitter highlights of the transcript once it's drawn, of diffs by side and hunk, and of the input

local t = ...
local highlight = require('otto.render.highlight')

local ns = vim.api.nvim_create_namespace('otto.highlights')
local input_ns = vim.api.nvim_create_namespace('otto.input.highlights')

--- @param bufnr integer
--- @param namespace? integer
--- @return string[] like "row:col-end_col group"
local function marks(bufnr, namespace)
  return vim.tbl_map(
    function(mark) return ('%d:%d-%d %s'):format(mark[2], mark[3], mark[4].end_col, mark[4].hl_group) end,
    vim.api.nvim_buf_get_extmarks(bufnr, namespace or ns, 0, -1, { details = true })
  )
end

--- @param bufnr integer
--- @param row integer
--- @return string[] groups at the row
local function groups(bufnr, row)
  local found = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, ns, { row, 0 }, { row, -1 }, { details = true })) do
    table.insert(found, mark[4].hl_group)
  end
  return found
end

--- @param lines string[]
--- @return integer bufnr, in the current window
local function buffer(lines)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_set_current_buf(bufnr)
  return bufnr
end

t.describe('lines', function()
  local lines = {}
  for i = 1, 60 do
    lines[i] = 'local x' .. i
  end
  local bufnr = buffer(lines)
  highlight.lines(bufnr, 0, 0, { 'local x1', 'local x2' }, 'lua')
  highlight.lines(bufnr, 50, 0, { 'local x51' }, 'lua')
  t.check('not before they draw', marks(bufnr), {})
  vim.cmd.redraw()
  t.check('once they draw', marks(bufnr), {
    '0:0-5 @keyword.lua',
    '0:6-8 @variable.lua',
    '1:0-5 @keyword.lua',
    '1:6-8 @variable.lua',
  })
  t.check('blocks past the view wait', groups(bufnr, 50), {})
  vim.cmd('normal! G')
  vim.cmd.redraw()
  t.check('until they show', groups(bufnr, 50), { '@keyword.lua', '@variable.lua' })

  local indented = buffer({ 'text', '    local a = 1' })
  highlight.lines(indented, 1, 4, { 'local a = 1' }, 'lua')
  vim.cmd.redraw()
  t.check('at their indent', marks(indented)[1], '1:4-9 @keyword.lua')

  local other = buffer({ 'plain' })
  highlight.lines(other, 0, 0, { 'plain' }, 'not-a-filetype')
  vim.cmd.redraw()
  t.check('without a language', marks(other), {})

  highlight.clear(bufnr)
  t.check('cleared', marks(bufnr), {})
end)

t.describe('chunks', function()
  t.check('as the language, for virtual text', highlight.chunks('local x', 'lua'), {
    { 'local', '@keyword.lua' },
    { ' ' },
    { 'x', '@variable.lua' },
  })
  t.check('without a language', highlight.chunks('plain', 'not-a-filetype'), { { 'plain' } })
end)

--- @param lines string[] of a diff, which highlight as lua
--- @return integer bufnr
local function diff(lines)
  local bufnr = buffer(vim.tbl_map(function(line) return '  ' .. line end, lines))
  highlight.diff(bufnr, 0, 2, lines, 'lua')
  vim.cmd.redraw()
  return bufnr
end

t.describe('diff', function()
  local bufnr = diff({ ' 1 local s = [[', ' 2 a = 1', '-3 b = 2]]', '+3 ]]', ' 9 x = 3' })
  t.check('line numbers', marks(bufnr)[1], '0:3-4 OttoLineNumber')
  t.check('code after them', groups(bufnr, 0), {
    'OttoLineNumber',
    '@keyword.lua',
    '@variable.lua',
    '@operator.lua',
    '@string.lua',
  })
  t.check('once, though both sides parse them', #groups(bufnr, 1), 2)
  t.check('removed lines parse with the lines around them', groups(bufnr, 2)[2], '@string.lua')
  -- which would be past the end of the string, parsed after the removed line
  t.check('apart from added lines', groups(bufnr, 3)[2], '@string.lua')

  t.check('lines of a hunk parse together', groups(diff({ ' 1 local s = [[', ' 2 x]]' }), 1)[2], '@string.lua')
  t.check('hunks parse apart', groups(diff({ ' 1 local s = [[', ' 9 x]]' }), 1)[2], '@variable.lua')

  local plain = buffer({ '  -1 x', '  +1 y' })
  highlight.diff(plain, 0, 2, { '-1 x', '+1 y' })
  vim.cmd.redraw()
  t.check('line numbers without a language', marks(plain), { '0:3-4 OttoLineNumber', '1:3-4 OttoLineNumber' })
end)

t.describe('input', function()
  local bufnr = t.scratch({ 'transcript', '# title', 'text' }, 1)
  highlight.input(bufnr)
  t.match('as markdown', marks(bufnr, input_ns)[1], '^1:0%-%d+ @markup%.heading')
  t.check('not the transcript', #vim.api.nvim_buf_get_extmarks(bufnr, input_ns, 0, { 0, -1 }, {}), 0)
  vim.api.nvim_buf_set_lines(bufnr, 1, -1, false, { 'plain' })
  highlight.input(bufnr)
  t.check('again once it changed', marks(bufnr, input_ns), {})
end)
