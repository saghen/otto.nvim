-- Experimental neovim-native agent buffer

local buffers = require('otto.buffers')
local config = require('otto.config')
local providers = require('otto.providers')
local uri = require('otto.uri')
local util = require('otto.util')
local view = require('otto.view')
local winbar = require('otto.ui.winbar')

local M = {}

--- @param opts? otto.ConfigPartial
function M.setup(opts) config.set(opts or {}) end

--- Opens a new session
--- @param name? string
--- @param provider? otto.ProviderName Defaults to `default_provider`
function M.new(name, provider)
  provider = provider or config.get().default_provider
  local found = providers.get(provider)
  if found == nil then return util.notify('unknown agent: ' .. provider) end
  view.open(uri.unique(provider, found.new_id(name)), name)
end

--- Sends a reference to lines of the current file to the input of the most recent session, like `path:1-2`, without
--- submitting it
--- @param first integer
--- @param last integer
function M.send(first, last)
  local path = vim.fn.expand('%:.')
  M.append(first == last and ('`%s:%d`'):format(path, first) or ('`%s:%d-%d`'):format(path, first, last))
end

--- Appends text to the most recently used session by default, or a new one, and starts insert mode
--- @param text string
--- @param session_bufnr? integer Of the session
function M.append(text, session_bufnr)
  local recent = session_bufnr and buffers.get(session_bufnr) or buffers.recent()[1]
  if recent ~= nil then
    vim.cmd.buffer(recent.bufnr)
  else
    M.new()
  end

  local line = vim.api.nvim_buf_get_lines(0, -2, -1, false)[1]
  local space = (line == '' or line:match('%s$')) and '' or ' '
  vim.api.nvim_buf_set_text(0, -1, #line, -1, #line, { space .. text .. ' ' })
  -- in the input, which entering insert mode from the transcript would move the cursor to the start of
  vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(0), 0 })
  vim.cmd.startinsert({ bang = true })
end

--- Spaces the transcript from the edge, highlighted like the prompts on their lines
--- https://github.com/neovim/neovim/issues/12866
--- @return string
function M.statuscolumn()
  local current = buffers.get(vim.api.nvim_win_get_buf(vim.g.statusline_winid))
  return current and current.transcript:is_prompt(vim.v.lnum - 1) and '%#OttoPrompt#  ' or '  '
end

--- @return string
function M.winbar()
  local current = buffers.get(vim.api.nvim_win_get_buf(vim.g.statusline_winid))
  return current and winbar.render(current) or ''
end

return M
