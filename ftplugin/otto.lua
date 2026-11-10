-- A session's buffer: its window options, and keeping the input and the transcript in place as they change, and the
-- <Plug> maps of otto's commands. Its keymaps come from the config once the session loads, without mapping over the
-- keys of after/ftplugin/otto.lua

if vim.b.did_ftplugin then return end
vim.b.did_ftplugin = true

local buffers = require('otto.buffers')
local highlight = require('otto.render.highlight')
local history = require('otto.ui.history')
local input = require('otto.input')
local keymaps = require('otto.ui.keymaps')
local scroll = require('otto.ui.scroll')
local views = require('otto.view')

-- once otto loads, before after/ftplugin/otto.lua maps them
keymaps.define_plugs()

local bufnr = vim.api.nvim_get_current_buf()
local group = vim.api.nvim_create_augroup('otto.buffer', { clear = false })
-- which runs again when the session restarts and sets the filetype again
vim.b.undo_ftplugin = ("lua vim.api.nvim_clear_autocmds({ group = 'otto.buffer', buffer = %d })"):format(bufnr)

--- @return otto.View?
local function view() return buffers.get(bufnr) end

vim.api.nvim_create_autocmd('BufWinEnter', {
  group = group,
  buffer = bufnr,
  callback = function()
    local wo = vim.wo[0][0]
    wo.foldmethod = 'manual'
    if view() ~= nil then view().transcript:fold() end
    wo.foldtext = ''
    wo.conceallevel = 0 -- concealed lines, like code fences, break scrolling
    wo.wrap = true
    wo.linebreak = true
    wo.number = false
    wo.relativenumber = false
    wo.signcolumn = 'no'
    wo.statuscolumn = "%!v:lua.require'otto'.statuscolumn()"
    wo.foldcolumn = '0'
    wo.winbar = "%!v:lua.require'otto'.winbar()"
    wo.winhighlight = 'Folded:Normal' -- folded tools look like the rest of the transcript
    -- once the window settles, so that the first output follows the prompt too
    local win = vim.api.nvim_get_current_win()
    vim.schedule(function()
      if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == bufnr then scroll.remember(win) end
    end)
  end,
})
vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
  group = group,
  buffer = bufnr,
  callback = function()
    if view() == nil then return end
    view().transcript:anchor()
    highlight.input(bufnr)
  end,
})
vim.api.nvim_create_autocmd('InsertEnter', {
  group = group,
  buffer = bufnr,
  callback = function()
    if view() == nil then return end
    -- insert mode opens the fold under the cursor before the prompt buffer moves the cursor to the input
    local input_lnum = input.row(bufnr) + 1
    if vim.fn.line('.') >= input_lnum then return end
    vim.api.nvim_win_set_cursor(0, { input_lnum, 0 })
    vim.v.char = 'moved' -- keeps the cursor there, see :help InsertEnter
  end,
})
vim.api.nvim_create_autocmd('BufUnload', {
  group = group,
  buffer = bufnr,
  callback = function()
    if view() == nil then return end
    history.save_drafts({ bufnr })
    views.unload(bufnr)
  end,
})
