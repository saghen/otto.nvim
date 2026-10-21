-- Experimental neovim-native agent interface

--- @class otto.Session
--- @field bufnr integer
--- @field backend 'pi' | 'claude' | 'codex' The agent, which names the buffer, like claude://<session id>
--- @field id string
--- @field client otto.Client | otto.ClaudeClient | otto.CodexClient
--- @field tools table<string, { name: string, args: table }> Tool calls by id, until their result arrives
--- @field edits vim.quickfix.entry[] Files that pi edited, at the first changed line
--- @field commands otto.Command[] Extension commands, prompt templates and skills
--- @field tail? 'user' | 'text' | 'tool' | 'error' | 'note' Kind of the last block, which spaces the next one
--- @field started? integer When the agent started working, in seconds since the epoch
--- @field text_row? integer First row of the last text block
--- @field group? otto.Group Tools since the last text
--- @field state? otto.State Shown in the winbar
--- @field naming? boolean Whether a name is on its way, from the user or `name_after`
--- @field follow_up? boolean Whether the prompt being submitted waits for pi to finish, instead of steering

local claude = require('otto.claude')
local codex = require('otto.codex')
local commands = require('otto.commands')
require('otto.highlights')
local lsp = require('otto.lsp')
local pick = require('otto.pick')
local prompt = require('otto.prompt')
local resume = require('otto.resume')
local rpc = require('otto.rpc')
local transcript = require('otto.transcript')
local winbar = require('otto.winbar')

local M = {}

--- Configures pickers and Pi. Call before the first picker or agent launch.
--- @param opts? table
function M.setup(opts) require('otto.config').setup(opts) end

local sessions = {} --- @type table<integer, otto.Session> by buffer
local names = {} --- @type table<string, string> of new sessions by buffer name, until they start

vim.treesitter.language.register('markdown', 'otto')

local winbar_events = { 'agent_settled', 'compaction_end', 'thinking_level_changed', 'session_info_changed' }

--- @param session otto.Session
--- @param event table
local function on_event(session, event)
  if vim.list_contains(winbar_events, event.type) then rpc.run(function() winbar.refresh(session) end) end
  if event.type == 'agent_start' then
    session.started = os.time()
    prompt.set_status(session.bufnr, 'Working')
  elseif event.type == 'agent_settled' then
    vim.cmd.checktime() -- reloads the files the agent edited
    prompt.set_status(session.bufnr, nil)
    if session.started ~= nil then transcript.worked(session, os.time() - session.started, event.aborted) end
    session.started = nil
  elseif event.type == 'tool_execution_start' then
    transcript.tool_started(session, event)
  elseif event.type == 'compaction_start' then
    prompt.set_status(session.bufnr, 'Compacting')
  elseif event.type == 'queue_update' then
    prompt.set_queue(session.bufnr, event.steering, event.followUp)
  elseif event.type == 'compaction_end' then
    -- compacting can happen while the agent works
    prompt.set_status(session.bufnr, session.started ~= nil and 'Working' or nil)
    if event.result ~= nil then transcript.compacted(session, event.result.summary, event.result.tokensBefore) end
  elseif event.type == 'message_end' then
    transcript.render(session, event.message)
  elseif event.type == 'session_created' then
    -- Codex creates the ids of its sessions, which then name the buffer
    session.id = event.id
    vim.api.nvim_buf_set_name(session.bufnr, session.backend .. '://' .. event.id)
  end
end

--- @param session otto.Session
local function keymaps(session)
  local client = session.client
  local function map(mode, lhs, rhs, desc, expr)
    vim.keymap.set(mode, lhs, rhs, { buf = session.bufnr, desc = 'Otto: ' .. desc, expr = expr })
  end

  -- submitting steers while pi is working. <CR> in insert mode adds a line, like <S-CR> in prompt buffers
  map('i', '<CR>', '<S-CR>', 'New line')
  map('n', '<CR>', 'A<CR><Esc>', 'Submit')
  map('n', '<C-s>', 'A<CR><Esc>', 'Submit')
  map('i', '<C-s>', '<CR>', 'Submit')
  map('i', '<M-CR>', function()
    session.follow_up = true
    return '<CR>'
  end, 'Submit as follow-up', true)
  map('n', '<C-c>', function()
    rpc.run(function()
      -- the queued prompts go back to the prompt first, since aborting would continue with them
      local queued = client:call({ type = 'clear_queue' })
      local lines = vim.list_extend(vim.list_extend({}, queued.steering), queued.followUp)
      if #lines == 0 then return client:request({ type = 'abort' }) end
      local input = vim.fn.prompt_getinput(session.bufnr)
      if input ~= '' then table.insert(lines, input) end
      local row = vim.api.nvim_buf_get_mark(session.bufnr, ':')[1] - 1
      vim.api.nvim_buf_set_lines(session.bufnr, row, -1, false, vim.split(table.concat(lines, '\n'), '\n'))
    end)
  end, 'Take back queued prompts, or abort')
  map({ 'n', 'i' }, '<C-CR>', function()
    if prompt.has_queue(session.bufnr) then client:request({ type = 'abort' }) end
  end, 'Send queued prompts now')
  map('n', 'gq', function()
    vim.fn.setqflist({}, ' ', { title = session.id .. ' edits', items = session.edits })
    vim.cmd.copen()
  end, 'Edits to quickfix')
  local function jump_to_prompt(backward)
    local row = transcript.find_prompt(session.bufnr, vim.fn.line('.') - 1, backward)
    if row ~= nil then vim.api.nvim_win_set_cursor(0, { row + 1, 0 }) end
  end
  map('n', ']]', function() jump_to_prompt(false) end, 'Next prompt')
  map('n', '[[', function() jump_to_prompt(true) end, 'Previous prompt')
  map('n', '<C-p>', function() commands.run(session, '/model') end, 'Select model')
  map('n', '<S-Tab>', function()
    client:request({ type = 'cycle_thinking_level' }) -- the winbar shows the level
  end, 'Cycle thinking level')
end

--- Names the session after its first prompt, like "fix_winbar_highlights", with a quick pi
--- @async
--- @param session otto.Session
--- @param text string
local function name_after(session, text)
  local message = 'Name a coding session that starts with this prompt, in 2 to 4 words of snake_case. '
    .. 'Reply with only the name.\n\n'
    .. text
  local name = rpc.ask('naming', message, { '--no-tools', '--no-skills', '--thinking', 'off' })
  name = vim.trim(name):lower():gsub('[^%w]+', '_'):gsub('^_+', ''):gsub('_+$', '')
  if name ~= '' then session.client:call({ type = 'set_session_name', name = name }) end
end

--- @param session otto.Session
--- @param text string
local function on_submit(session, text)
  local follow_up = session.follow_up
  session.follow_up = nil
  local handled = commands.run(session, text)
  transcript.submitted(session, text)
  local message = vim.trim(text)
  if handled or message == '' then return end
  if session.state ~= nil and session.state.name == nil and not session.naming then
    session.naming = true
    rpc.run(function() name_after(session, message) end)
  end
  local behavior = follow_up and 'followUp' or 'steer'
  session.client:request({ type = 'prompt', message = message, streamingBehavior = behavior })
end

--- Starts pi for the session named by the buffer, and renders its history
--- @param bufnr integer
local function load(bufnr)
  local uri = vim.api.nvim_buf_get_name(bufnr)
  local backend, id = uri:match('^(%a+)://(.+)')
  -- agents take a display name, which keeps them from naming the session after its first prompt
  local name = names[uri]
  names[uri] = nil
  local args = name and { '--name', name } or {}
  --- @type otto.Session
  --- @diagnostic disable-next-line: missing-fields
  local session = { bufnr = bufnr, backend = backend, id = id, tools = {}, edits = {}, commands = {} }
  session.naming = #args > 0 -- the name is on its way already
  local function events(event) on_event(session, event) end
  if backend == 'claude' then
    session.client = claude.start(id, events, args)
  elseif backend == 'codex' then
    session.client = codex.start(id, events, name)
  else
    session.client = rpc.start(id, vim.list_extend({ '--session-id', id }, args), events)
  end
  sessions[bufnr] = session

  vim.bo[bufnr].buftype = 'prompt'
  vim.bo[bufnr].bufhidden = 'hide'
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = 'otto'
  vim.b[bufnr].completion = true -- blink.cmp skips prompt buffers otherwise
  vim.fn.prompt_setprompt(bufnr, '')
  vim.fn.prompt_setcallback(bufnr, function(text) on_submit(session, text) end)
  vim.treesitter.start(bufnr)
  keymaps(session)
  lsp.attach(session)
  transcript.clear(bufnr)

  rpc.run(function()
    session.commands = session.client:call({ type = 'get_commands' }).commands
    for _, msg in ipairs(session.client:call({ type = 'get_messages' }).messages) do
      transcript.render(session, msg)
    end
    winbar.refresh(session)
  end)
end

--- Restarts pi for the session's buffer, and renders the session again
--- @param bufnr integer
--- @param id? string Session to switch the buffer to
function M.restart(bufnr, id)
  sessions[bufnr].client:close()
  if id ~= nil then vim.api.nvim_buf_set_name(bufnr, sessions[bufnr].backend .. '://' .. id) end
  load(bufnr)
end

--- Opens the session, creating it when it doesn't exist. Ids may contain letters, numbers, `.`, `_` and `-`, and
--- other characters become `_`
--- @param id string
function M.open(id) vim.cmd.edit('pi://' .. id:gsub('[^%w._-]+', '_')) end

--- Opens a new session, which is named after its first prompt unless it's given a name. pi's ids are the name, or
--- when the session started, and Claude Code's are always UUIDs. Codex's start like pi's, until it creates them
--- @param name? string
--- @param backend? 'pi' | 'claude' | 'codex' Defaults to pi
function M.new(name, backend)
  local id = backend == 'claude' and claude.uuid() or (name or os.date('%Y_%m_%d_%H%M%S')):gsub('[^%w._-]+', '_')
  local uri = ('%s://%s'):format(backend or 'pi', id)
  names[uri] = name
  vim.cmd.edit(uri)
end

--- Sends a reference to lines of the current file to the most recent session
--- @param first integer
--- @param last integer
function M.send(first, last)
  local path = vim.fn.expand('%:.')
  M.append(first == last and ('`%s:%d`'):format(path, first) or ('`%s:%d-%d`'):format(path, first, last))
end

--- @return vim.fn.getbufinfo.ret.item[] Buffers of the open sessions, most recently used first
local function open_sessions()
  local infos = vim.tbl_filter(
    function(info) return sessions[info.bufnr] ~= nil end,
    vim.fn.getbufinfo({ bufloaded = 1 })
  )
  table.sort(infos, function(a, b) return a.lastused > b.lastused end)
  return infos
end

--- Picks an open session, and switches to it
local function pick_session()
  --- @param info vim.fn.getbufinfo.ret.item
  --- @return string? name that pi gave the session
  local function name(info) return (sessions[info.bufnr].state or {}).name end
  local opts = {
    prompt = 'Session: ',
    text = function(info) return name(info) or sessions[info.bufnr].id end,
    format = function(info)
      local id = sessions[info.bufnr].id
      if name(info) == nil then return { { text = id } } end
      return { { text = name(info) }, { text = '  ' .. id, hl = 'Comment' } }
    end,
  }
  pick.pick(open_sessions(), opts, function(info)
    if info ~= nil then vim.cmd.buffer(info.bufnr) end
  end)
end

--- Appends text to the prompt of the most recently used session, or a new one, and starts insert mode there
--- @param text string
function M.append(text)
  local recent = open_sessions()[1]
  if recent ~= nil then
    vim.cmd.buffer(recent.bufnr)
  else
    M.new()
  end

  local line = vim.api.nvim_buf_get_lines(0, -2, -1, false)[1]
  vim.api.nvim_buf_set_text(0, -1, #line, -1, #line, { (line:match('%s$') and '' or ' ') .. text .. ' ' })
  vim.cmd.startinsert({ bang = true })
end

--- Spaces the transcript from the edge, highlighted like the prompts on their lines. Signs would do, but they only
--- highlight the first row of wrapped lines: https://github.com/neovim/neovim/issues/12866
--- @return string
function M.statuscolumn()
  local bufnr = vim.api.nvim_win_get_buf(vim.g.statusline_winid)
  return transcript.is_prompt(bufnr, vim.v.lnum - 1) and '%#OttoPrompt#  ' or '  '
end

--- @return string
function M.winbar()
  local session = sessions[vim.api.nvim_win_get_buf(vim.g.statusline_winid)]
  return session and winbar.render(session) or ''
end

-- pi only saves sessions with messages, so an empty session only has its buffer to remove, once it's been hidden for a
-- while
local cleanup_delay = 10000
local shown = {} --- @type table<integer, integer> times each session buffer was shown in a window
--- @param bufnr integer
--- @return boolean
local function is_empty(bufnr)
  return vim.api.nvim_buf_get_mark(bufnr, ':')[1] == 1 and vim.fn.prompt_getinput(bufnr) == ''
end

local group = vim.api.nvim_create_augroup('otto', {})
local patterns = { 'pi://*', 'claude://*', 'codex://*' }
vim.api.nvim_create_autocmd('BufReadCmd', {
  group = group,
  pattern = patterns,
  callback = function(ev) load(ev.buf) end,
})
vim.api.nvim_create_autocmd('BufWinEnter', {
  group = group,
  pattern = patterns,
  callback = function(ev)
    local wo = vim.wo[0][0]
    wo.foldmethod = 'manual'
    transcript.fold(ev.buf)
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
    shown[ev.buf] = (shown[ev.buf] or 0) + 1
  end,
})
vim.api.nvim_create_autocmd({ 'BufEnter', 'CursorMoved', 'InsertEnter', 'TextChanged', 'TextChangedI' }, {
  group = group,
  pattern = patterns,
  callback = function(ev)
    vim.schedule(function() prompt.pin(ev.buf) end)
  end,
})
-- like when the command line grows, which would cover the end of the prompt
vim.api.nvim_create_autocmd('WinResized', {
  group = group,
  callback = function()
    local bufnr = vim.api.nvim_get_current_buf()
    if sessions[bufnr] ~= nil then prompt.pin(bufnr) end
  end,
})
vim.api.nvim_create_autocmd('InsertEnter', {
  group = group,
  pattern = patterns,
  callback = function(ev)
    -- insert mode opens the fold under the cursor before the prompt buffer moves the cursor to the prompt
    local prompt_lnum = vim.api.nvim_buf_get_mark(ev.buf, ':')[1]
    if vim.fn.line('.') >= prompt_lnum then return end
    vim.api.nvim_win_set_cursor(0, { prompt_lnum, 0 })
    vim.v.char = 'moved' -- keeps the cursor there, see :help InsertEnter
  end,
})
vim.api.nvim_create_autocmd('BufHidden', {
  group = group,
  pattern = patterns,
  callback = function(ev)
    local times = shown[ev.buf]
    vim.defer_fn(function()
      local hidden = vim.api.nvim_buf_is_loaded(ev.buf) and shown[ev.buf] == times
      if hidden and is_empty(ev.buf) then vim.api.nvim_buf_delete(ev.buf, { force = true }) end
    end, cleanup_delay)
  end,
})
vim.api.nvim_create_autocmd('BufUnload', {
  group = group,
  pattern = patterns,
  callback = function(ev)
    if sessions[ev.buf] ~= nil then sessions[ev.buf].client:close() end
  end,
})

--- @type table<string, fun(arg?: string, cmd: vim.api.keyset.create_user_command.command_args)>
local subcommands = {
  pi = function(name) M.new(name, 'pi') end,
  claude = function(name) M.new(name, 'claude') end,
  codex = function(name) M.new(name, 'codex') end,
  send = function(_, cmd) M.send(cmd.line1, cmd.line2) end,
  resume = function(id)
    if id == nil then return resume.pick() end
    local saved = vim.iter(resume.list()):find(function(session) return session.id == id end)
    if saved == nil then return M.open(id) end
    vim.cmd.edit(saved.uri)
  end,
  pick = pick_session,
}

-- :Otto pi [name], :Otto claude [name], :Otto codex [name], :Otto resume [id], :Otto pick, which :Otto defaults to, and :Otto send for the
-- current line or a range
vim.api.nvim_create_user_command('Otto', function(cmd)
  local subcommand = subcommands[cmd.fargs[1] or 'pick']
  if subcommand == nil then return rpc.notify('unknown subcommand: ' .. cmd.fargs[1]) end
  local arg = table.concat(cmd.fargs, ' ', 2)
  subcommand(arg ~= '' and arg or nil, cmd)
end, {
  nargs = '*',
  range = true,
  complete = function(lead, line)
    local words = vim.split(line, '%s+')
    if #words <= 2 then
      local names = vim.tbl_keys(subcommands)
      table.sort(names)
      return vim.tbl_filter(function(name) return vim.startswith(name, lead) end, names)
    end
    if words[2] ~= 'resume' then return {} end
    local ids = vim.tbl_map(function(session) return session.id end, resume.list())
    return lead == '' and ids or vim.fn.matchfuzzy(ids, lead)
  end,
})

return M
