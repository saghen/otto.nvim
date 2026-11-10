-- Keymaps of a session's buffer, which run the commands of `commands.lua` through <Plug>(otto-<command>) maps, like
-- <Plug>(otto-submit), which after/ftplugin/otto.lua can map too

local buffers = require('otto.buffers')
local commands = require('otto.ui.commands')
local config = require('otto.config')
local util = require('otto.util')

local M = {}

local defined = false

--- Maps <Plug>(otto-<command>) of every command, which runs it in the current buffer's session, once
function M.define_plugs()
  if defined then return end
  defined = true
  for _, command in ipairs(commands.builtin) do
    vim.keymap.set(command.modes or 'n', commands.plug(command.name), function()
      local view = buffers.current()
      if view == nil then return '' end
      return commands.run(view, command.name)
    end, { desc = 'Otto: ' .. command.description, expr = command.keys ~= nil })
  end
end

--- @param lhs string
--- @param mode string
--- @param name string
--- @return otto.Command?
--- @return string? error of a command that doesn't exist, or has no keymap in the mode
local function command_of(lhs, mode, name)
  local command = commands.get(name)
  if command == nil then return nil, ('keymaps[%s]: unknown command %s'):format(lhs, vim.inspect(name)) end
  if not vim.list_contains(command.modes or { 'n' }, mode) then
    return nil, ('keymaps[%s]: %s has no keymap in mode %s'):format(lhs, name, mode)
  end
  return command
end

--- Maps the configured keys, but not over the buffer's own, like those of after/ftplugin/otto.lua
--- @param view otto.View
function M.attach(view)
  local bufnr = view.bufnr
  local keymaps = config.get({ bufnr = bufnr }).keymaps
  vim.api.nvim_buf_call(bufnr, function()
    -- otto's from before a restart, which the config may have changed since
    for _, map in ipairs(vim.b.otto_keymaps or {}) do
      if vim.fn.maparg(map.lhs, map.mode, false, true).rhs == map.rhs then
        vim.keymap.del(map.mode, map.lhs, { buf = bufnr })
      end
    end
    local set = {}
    for lhs, value in pairs(keymaps or {}) do
      for mode, name in pairs(commands.by_mode(value)) do
        local command, err = command_of(lhs, mode, name)
        if err then util.notify(err) end
        if command and vim.fn.maparg(lhs, mode, false, true).buffer ~= 1 then
          vim.keymap.set(mode, lhs, commands.plug(name), { buf = bufnr, desc = 'Otto: ' .. command.description })
          table.insert(set, { mode = mode, lhs = lhs, rhs = commands.plug(name) })
        end
      end
    end
    vim.b.otto_keymaps = set
  end)
end

return M
