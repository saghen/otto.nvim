-- ui/scroll.lua: windows keep the same lines of the input at their bottom as output arrives above it

local t = ...
local scroll = require('otto.ui.scroll')
local input = require('otto.input')

--- A transcript of 60 lines, then the input
--- @param input_lines integer
--- @return integer bufnr
local function buffer(input_lines)
  local lines = {}
  for i = 1, 60 do
    lines[i] = 'out ' .. i
  end
  for i = 1, input_lines do
    table.insert(lines, 'in ' .. i)
  end
  return t.scratch(lines, 60)
end

--- Output above the input
--- @param bufnr integer
--- @param count integer
local function output(bufnr, count)
  local row = input.row(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, row, row, false, vim.split(('more\n'):rep(count - 1) .. 'more', '\n'))
  -- which the prompt buffer's mark doesn't follow
  vim.api.nvim_buf_set_mark(bufnr, ':', row + count + 1, 0, {})
end

--- @param fn fun()
local function in_window(fn)
  vim.cmd('silent only')
  local ok, err = pcall(fn)
  vim.cmd('silent only')
  assert(ok, err)
end

t.describe('at the end', function()
  local bufnr = buffer(3)
  local win = vim.api.nvim_get_current_win()
  vim.cmd('normal! G')
  scroll.remember(win)
  t.check('remembered', vim.w[win].otto_scroll, { height = vim.api.nvim_win_get_height(win), offset = nil })
  output(bufnr, 10)
  scroll.follow(bufnr)
  t.check('keeps the end at the bottom', vim.fn.line('w$'), vim.api.nvim_buf_line_count(bufnr))
end)

t.describe('in the input', function()
  local bufnr = buffer(10)
  local win = vim.api.nvim_get_current_win()
  -- the second line of the input at the bottom
  vim.api.nvim_win_set_cursor(win, { 62, 0 })
  vim.cmd('normal! zb')
  scroll.remember(win)
  t.check('remembered', vim.w[win].otto_scroll.offset, 1)
  output(bufnr, 10)
  scroll.follow(bufnr)
  t.check('the same line at the bottom', vim.fn.getline(vim.fn.line('w$')), 'in 2')
  t.check('the cursor stays on its text', vim.api.nvim_get_current_line(), 'in 2')
end)

t.describe('in the transcript', function()
  local bufnr = buffer(3)
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_cursor(win, { 30, 0 })
  vim.cmd('normal! zb')
  local top = vim.fn.line('w0')
  scroll.remember(win)
  t.check('nothing to keep', vim.w[win].otto_scroll, nil)
  output(bufnr, 10)
  scroll.follow(bufnr)
  t.check('stays where it is', { vim.fn.line('w0'), vim.fn.line('.') }, { top, 30 })
end)

t.describe('the cursor in the transcript', function()
  local bufnr = buffer(3)
  local win = vim.api.nvim_get_current_win()
  vim.cmd('normal! G')
  scroll.remember(win)
  local height = vim.api.nvim_win_get_height(win)
  -- a line in view, and the line at the top
  local last = vim.api.nvim_buf_line_count(bufnr)
  vim.api.nvim_win_set_cursor(win, { last - 3, 0 })
  output(bufnr, 2)
  scroll.follow(bufnr)
  t.check('stays on its line while it shows', vim.fn.line('.'), last - 3)
  vim.api.nvim_win_set_cursor(win, { vim.fn.line('w0'), 0 })
  output(bufnr, height)
  scroll.follow(bufnr)
  t.check('moves to the top once it would scroll off', vim.fn.line('.'), vim.fn.line('w0'))
end)

t.describe('scrolled', function()
  in_window(function()
    local bufnr = buffer(10)
    vim.cmd('split')
    vim.api.nvim_win_set_buf(0, bufnr)
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_cursor(win, { 63, 0 })
    vim.cmd('normal! zb')
    scroll.remember(win)
    vim.cmd('resize -3')
    vim.cmd('normal! zt')
    scroll.scrolled(win)
    t.check('the same line at the bottom of a smaller window', vim.fn.getline(vim.fn.line('w$')), 'in 3')
    t.check('remembers the height', vim.w[win].otto_scroll.height, vim.api.nvim_win_get_height(win))

    vim.api.nvim_win_set_cursor(win, { 62, 0 })
    vim.cmd('normal! zb')
    scroll.scrolled(win)
    t.check('otherwise remembers where it scrolled', vim.w[win].otto_scroll.offset, 1)
  end)
end)
