-- A session's buffer, which shows its transcript and state, and sends what's submitted to its agent. Buffers are named
-- after their session, like claude://<id>, and sessions don't know of them, see `session.lua`

local buffers = require('otto.buffers')
local footer = require('otto.ui.footer')
local history = require('otto.ui.history')
local keymaps = require('otto.ui.keymaps')
local layout = require('otto.render.layout')
local lsp = require('otto.ui.lsp')
local providers = require('otto.providers')
local sessions = require('otto.session')
local transcript = require('otto.render.transcript')
local uri = require('otto.uri')
local util = require('otto.util')

--- @class otto.View
--- @field bufnr integer
--- @field session otto.Session
--- @field layout otto.Layout
--- @field transcript otto.Transcript
--- @field footer otto.Footer
--- @field unsubscribe fun()
--- @field follow_up? boolean Whether the input being submitted waits for the agent to finish, instead of steering
--- @field recall? otto.Recall Where the input is in the history
local View = {}
View.__index = View

local M = {}

--- @type table<string, string> Display names of new sessions by buffer name, until their buffers load
local pending_names = {}

--- Renames the buffer, without the unlisted buffer of its old name that renaming leaves, which <C-^> would open
--- @param bufnr integer
--- @param name string
local function rename_buffer(bufnr, name)
  local old = vim.api.nvim_buf_get_name(bufnr)
  vim.api.nvim_buf_set_name(bufnr, name)
  for _, other in ipairs(vim.api.nvim_list_bufs()) do
    if other ~= bufnr and not vim.api.nvim_buf_is_loaded(other) and vim.api.nvim_buf_get_name(other) == old then
      vim.api.nvim_buf_delete(other, { force = true })
    end
  end
end

--- @param event otto.Event
function View:on_log(event)
  for _, op in ipairs(self.layout:add(event)) do
    self.transcript:apply(op)
  end
  -- which shows below the transcript until its result renders
  if event.type == 'tool_call' then self.footer:draw() end
end

--- Shows what the session runs with
function View:refresh()
  local session = self.session
  -- like Codex, which creates the ids of its sessions
  if vim.api.nvim_buf_get_name(self.bufnr) ~= session.uri then rename_buffer(self.bufnr, session.uri) end
  vim.cmd.redrawstatus({ bang = true })
end

--- @param patch otto.StatePatch
function View:on_state(patch)
  -- reloads the files that changed on disk, like those the agent edited
  if patch.status == false then vim.cmd.checktime() end
  if patch.status ~= nil or patch.queue then self.footer:update() end
  self:refresh()
end

--- @param text string
function View:submit(text)
  local session = self.session
  local follow_up = self.follow_up
  self.follow_up = nil
  history.add(text, session.uri)
  history.reset(self)
  self.transcript:remove_submitted(text)
  local message = vim.trim(text)
  if message == '' then return end
  session.agent:prompt(message, follow_up and 'follow_up' or 'steer')
end

--- Closes the view and its session, which nothing else shows yet
function View:close()
  self.unsubscribe()
  self.footer:close()
  self.transcript:close()
  self.session:close()
end

--- Shows the session that names the buffer, starting its agent unless it runs already, or notifies why it can't
--- @param bufnr integer
function M.load(bufnr)
  local session_uri = vim.api.nvim_buf_get_name(bufnr)
  local name = pending_names[session_uri]
  pending_names[session_uri] = nil
  local provider = providers.get(uri.parse(session_uri) or '')
  if provider == nil then return util.notify('unknown agent: ' .. session_uri) end

  -- before anything changes the buffer, which would start the window's folding, like treesitter's, which then parses
  -- the whole transcript after every change
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    vim.wo[win][0].foldmethod = 'manual'
  end
  vim.bo[bufnr].buftype = 'prompt'
  vim.bo[bufnr].bufhidden = 'hide'
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = 'otto'
  vim.fn.prompt_setprompt(bufnr, '')

  -- after the filetype, whose ftplugin can configure the session's buffer
  local ok, session = pcall(
    function() return sessions.find(session_uri) or sessions.open(session_uri, { name = name, bufnr = bufnr }) end
  )
  -- like an agent that isn't installed, which leaves the buffer without a view, until it's loaded again
  if not ok then return util.notify(tostring(session)) end

  local view = setmetatable({ bufnr = bufnr, session = session }, View)
  view.layout = layout.new()
  view.transcript = transcript.new(bufnr, function() view.footer:draw() end)
  view.footer = footer.new(bufnr, view.session, view.layout)
  -- over the footer of the session before a restart
  view.footer:draw()
  history.restore_draft(bufnr)
  buffers.set(bufnr, view)

  -- what the session logged before the buffer showed it, like its history
  for _, event in ipairs(view.session.events) do
    view:on_log(event)
  end
  view.unsubscribe = view.session:subscribe({
    on_log = function(event) view:on_log(event) end,
    on_state = function(patch) view:on_state(patch) end,
  })
  view:refresh()
  view.footer:update()

  vim.fn.prompt_setcallback(bufnr, function(text) view:submit(text) end)
  keymaps.attach(view)
  lsp.attach(view)
end

--- Restarts the agent for the session's buffer, and renders the session again
--- @param id? string Session to switch the buffer to
--- @return otto.View? The buffer's new view, unless the session failed to load
function View:restart(id)
  local bufnr = self.bufnr
  self:close()
  -- which is closed, even if the agent fails to start again
  buffers.set(bufnr, nil)
  if id ~= nil then rename_buffer(bufnr, uri.format(self.session.provider.name, id)) end
  M.load(bufnr)
  return buffers.get(bufnr)
end

--- Opens a buffer for a new session, which loads with `name`
--- @param session_uri string
--- @param name? string
function M.open(session_uri, name)
  pending_names[session_uri] = name
  vim.cmd.edit(session_uri)
end

--- Closes the view of the buffer, as it unloads
--- @param bufnr integer
function M.unload(bufnr)
  local view = buffers.get(bufnr)
  if view == nil then return end
  view:close()
  buffers.set(bufnr, nil)
end

return M
