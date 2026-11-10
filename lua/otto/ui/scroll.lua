-- Keeps the windows of a session's buffer scrolled to the same lines of the input, as output arrives above it and
-- folds change

local input = require('otto.input')

local M = {}

--- Where the window shows the input, which the separator isn't part of
--- @class otto.Scroll
--- @field height integer Of the window
--- @field offset? integer From the input of the line at the bottom, or nil for the end of the buffer

--- Remembers where the window shows the input
--- @param win integer
function M.remember(win)
  local bufnr = vim.api.nvim_win_get_buf(win)
  vim.w[win].otto_scroll = vim.api.nvim_win_call(win, function()
    local bottom = vim.fn.line('w$')
    local input_lnum = input.row(bufnr) + 1
    if bottom < input_lnum then return nil end
    local offset = bottom < vim.api.nvim_buf_line_count(bufnr) and bottom - input_lnum or nil
    return { height = vim.api.nvim_win_get_height(win), offset = offset }
  end)
end

--- Puts the line of the scroll back at the bottom of the window
--- @param win integer
local function restore(win)
  local scroll = vim.w[win].otto_scroll --- @type otto.Scroll?
  if scroll == nil then return end
  local bufnr = vim.api.nvim_win_get_buf(win)
  vim.api.nvim_win_call(win, function()
    local last = vim.api.nvim_buf_line_count(bufnr)
    local input_lnum = input.row(bufnr) + 1
    local cursor = vim.api.nvim_win_get_cursor(win)
    local scrolloff = vim.api.nvim_get_option_value('scrolloff', { win = win, scope = 'local' })
    vim.wo[win].scrolloff = 0 -- so that the line goes to the very bottom
    vim.api.nvim_win_set_cursor(win, { math.min(input_lnum + (scroll.offset or last), last), 0 })
    vim.cmd('normal! zb')
    vim.api.nvim_set_option_value('scrolloff', scrolloff, { win = win, scope = 'local' })
    -- in the transcript, the cursor moves with the text like with <C-e>
    vim.cmd('normal! H')
    if cursor[1] >= vim.fn.line('.') then vim.api.nvim_win_set_cursor(win, cursor) end
  end)
end

--- Keeps the same lines of the input in view in the windows that show it, as output arrives above it and folds
--- change. With the end of the buffer at the bottom, that's the whole input, without scrolling past the end
--- @param bufnr integer
function M.follow(bufnr)
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    restore(win)
    M.remember(win)
  end
end

--- Keeps the same line at the bottom when the window's height changed, like when the command line grows, and otherwise
--- remembers where it scrolled to
--- @param win integer
function M.scrolled(win)
  local scroll = vim.w[win].otto_scroll
  if scroll ~= nil and scroll.height ~= vim.api.nvim_win_get_height(win) then restore(win) end
  M.remember(win)
end

return M
