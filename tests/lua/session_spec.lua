-- session.lua over a fake agent: the config of its buffer, requests for the user, and the agent's commands

local t = ...

if not pcall(require, 'blink.lib.config') then return t.skip('the config needs blink.lib, in BLINK_LIB') end

local config = require('otto.config')
local providers = require('otto.providers')
local sessions = require('otto.session')
local track = require('otto.track')

providers.providers.fake = {
  name = 'fake',
  icon = 'f ',
  open = function(_, opts)
    local agent = {}
    function agent.replay() end
    function agent.commands() return { { name = 'review' } } end
    function agent.close() end
    agent.opts = opts
    return agent
  end,
}
local provider_config = { cmd = { 'fake' }, args = {}, env = {} }

--- @param session_uri string
--- @param bufnr? integer
--- @return otto.Session
local function open(session_uri, bufnr)
  local opts = { bufnr = bufnr, config = provider_config }
  return sessions.open(session_uri, opts)
end

t.describe('config of its buffer', function()
  local wrapped = {}
  local start = track.start
  track.start = function()
    return {
      wrap = function(_, cmd, on_host)
        table.insert(wrapped, on_host)
        return cmd
      end,
      stop = function() end,
      catch_up = function() end,
    }
  end
  local tracked = vim.api.nvim_create_buf(true, true)
  local other = vim.api.nvim_create_buf(true, true)
  config.set({ track = true, on_host = { 'ssh' } }, { bufnr = tracked })

  vim.api.nvim_set_current_buf(other)
  local session = open('fake://tracked', tracked)
  t.check('rather than the current one', { session.tracked ~= nil, wrapped }, { true, { { 'ssh' } } })
  session:close()

  vim.api.nvim_set_current_buf(tracked)
  session = open('fake://untracked', other)
  t.check('of another buffer', session.tracked, nil)
  session:close()
  session = open('fake://global')
  t.check('or the global one', session.tracked, nil)
  session:close()
  track.start = start
end)

t.describe("an agent that can't start", function()
  local config_of = { cmd = { 'otto-no-such-agent' }, args = {}, env = {} }
  local count = vim.tbl_count(sessions.sessions)
  local ok, err = pcall(sessions.open, 'pi://missing', { config = config_of })
  t.check('raises', ok, false)
  t.match('why', err, '^pi: ENOENT')
  t.check('without a session', vim.tbl_count(sessions.sessions), count)
end)

t.describe('requests', function()
  local session = open('fake://requests')
  local answers = {}
  --- @param request table
  local function ask(request)
    local count = #answers
    request.respond = function(value) table.insert(answers, value == nil and vim.NIL or value) end
    session:on_request(request)
    vim.wait(100, function() return #answers > count end)
    return answers[#answers]
  end

  local select
  local asked = t.selecting(
    2,
    function() select = ask({ kind = 'select', prompt = 'Pick: ', items = { 'a', 'b' } }) end
  )
  t.check('select', { select, asked.prompt }, { 'b', 'Pick: ' })
  t.selecting(1, function() t.check('confirm', ask({ kind = 'confirm', prompt = 'Sure?' }), true) end)
  t.selecting(
    nil,
    function() t.check('cancelled', ask({ kind = 'select', prompt = 'P', items = { 'a' } }), vim.NIL) end
  )

  local input = vim.ui.input
  vim.ui.input = function(opts, on_confirm) on_confirm(opts.default .. '!') end
  t.check('input', ask({ kind = 'input', prompt = 'Name: ', default = 'x' }), 'x!')
  vim.ui.input = input

  local ui_select = vim.ui.select
  vim.ui.select = function() error('no picker', 0) end
  local failed
  local notified = t.notified(function() failed = ask({ kind = 'select', prompt = 'P', items = { 'a' } }) end)
  vim.ui.select = ui_select
  t.check('a picker that fails cancels', { failed, notified }, { vim.NIL, { 'otto: no picker' } })
  session:close()
end)

t.describe('commands', function()
  local patches = {}
  local group = vim.api.nvim_create_augroup('otto.session_spec', {})
  vim.api.nvim_create_autocmd('User', {
    group = group,
    pattern = 'OttoState',
    -- not of the sessions before, whose autocmds may still be pending
    callback = function(ev)
      if ev.data.uri == 'fake://commands' then table.insert(patches, ev.data.patch) end
    end,
  })
  local session = open('fake://commands')
  vim.wait(100, function() return #patches > 0 end)
  t.check('in the state', session.state.commands, { { name = 'review' } })
  t.check('as a patch', patches, { { commands = { { name = 'review' } } } })
  vim.api.nvim_del_augroup_by_id(group)
  session:close()
end)

providers.providers.fake = nil
