-- view.lua: a session's buffer over a fake agent, which renders its log and state, and sends what's submitted

local t = ...

if not pcall(require, 'blink.lib.config') then return t.skip('the config needs blink.lib, in BLINK_LIB') end

local views = require('otto.view')
local buffers = require('otto.buffers')
local history = require('otto.ui.history')
local input = require('otto.input')
local providers = require('otto.providers')
local sessions = require('otto.session')

--- @class otto.FakeAgent
--- @field id string
--- @field opts otto.AgentOpts
--- @field prompts { [1]: string, [2]: string }[] Texts and modes
--- @field closed boolean
--- @field queue string[] Prompts that it hasn't read
--- @field aborted? boolean
--- @field renamed? string

local agents = {} --- @type otto.FakeAgent[]
providers.providers.fake = {
  name = 'fake',
  icon = 'f ',
  new_id = function() return 'cleared' end,
  open = function(id, opts)
    -- like an agent that isn't installed
    if vim.startswith(id, 'broken') then error('fake: ENOENT', 0) end
    local agent = { id = id, opts = opts, prompts = {}, closed = false, queue = {} }
    -- its history
    function agent.replay() opts.on_log({ type = 'user', text = 'from ' .. id, at = 0 }) end
    function agent.commands() return {} end
    function agent.prompt(_, text, mode) table.insert(agent.prompts, { text, mode }) end
    function agent.close() agent.closed = true end
    function agent.abort() agent.aborted = true end
    function agent.rename(_, name) agent.renamed = name end
    function agent.take_queue(_, newest_only)
      local texts = newest_only and { table.remove(agent.queue) } or agent.queue
      agent.queue = newest_only and agent.queue or {}
      return texts
    end
    table.insert(agents, agent)
    return agent
  end,
}

local footer_ns = vim.api.nvim_create_namespace('otto.footer')
local state = vim.fs.joinpath(vim.fn.stdpath('state'), 'otto')

--- @param bufnr integer
--- @return string[] the footer's lines, as text
local function footer(bufnr)
  local mark = vim.api.nvim_buf_get_extmarks(bufnr, footer_ns, 0, -1, { details = true })[1]
  return vim.tbl_map(function(line)
    return table.concat(vim.tbl_map(function(chunk) return chunk[1] end, line))
  end, mark and mark[4].virt_lines or {})
end

--- Submits the input like the prompt buffer's <CR>, without otto's keymaps
--- @param bufnr integer
--- @param text string
local function submit(bufnr, text)
  input.set(bufnr, text)
  vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(bufnr), 0 })
  vim.api.nvim_feedkeys(vim.keycode('A<CR><Esc>'), 'nx', false)
end

-- an unsent prompt of a session from before
vim.fn.mkdir(state, 'p')
local draft = { ['fake://one'] = { text = 'draft', at = os.time() } }
assert(vim.fn.writefile({ vim.json.encode(draft) }, vim.fs.joinpath(state, 'drafts.json')) == 0)

local bufnr = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(bufnr, 'fake://one')
vim.api.nvim_set_current_buf(bufnr)
views.load(bufnr)
local view = buffers.get(bufnr)
local agent = agents[#agents]

t.describe('load', function()
  t.check('a view of the buffer', view and view.bufnr, bufnr)
  t.check('of the session', { view.session.uri, agent.id }, { 'fake://one', 'one' })
  t.check('a prompt buffer', { vim.bo[bufnr].buftype, vim.bo[bufnr].filetype }, { 'prompt', 'otto' })
  t.check('folded by hand', vim.wo.foldmethod, 'manual')
  t.check('its history, and the draft', t.lines(bufnr), { 'from one', '', '', 'draft' })
  t.check(
    'the draft is forgotten',
    vim.json.decode(table.concat(vim.fn.readfile(state .. '/drafts.json'))),
    vim.empty_dict()
  )
end)

t.describe('log and state', function()
  agent.opts.on_log({ type = 'text', text = 'live', at = 0 })
  t.check('renders what the agent logs', t.lines(bufnr), { 'from one', '', 'live', '', '', 'draft' })

  agent.opts.on_state({ status = 'working' })
  t.check('counts while it works', view.footer.timer ~= nil, true)
  agent.opts.on_log({ type = 'tool_call', id = 'c', tool = 'bash', args = { command = 'make' }, at = 0 })
  t.check('running tools in the footer', footer(bufnr), { '  $ make', '', 'Working... 0s' })
  agent.opts.on_state({ queue = { { text = 'later', follow_up = true } } })
  t.check('queued prompts', footer(bufnr)[5], 'later  follow-up')
  agent.opts.on_state({ status = false, queue = {} })
  t.check('stops counting', view.footer.timer, nil)
  t.check('empty footer', footer(bufnr), {})

  agent.opts.on_state({ id = 'two' })
  t.check('renamed once the agent has an id', vim.api.nvim_buf_get_name(bufnr), 'fake://two')
end)

t.describe('submit', function()
  submit(bufnr, 'hello\nthere')
  t.check('sent', agent.prompts, { { 'hello\nthere', 'steer' } })
  t.check('out of the transcript until the agent reads it', t.lines(bufnr), { 'from one', '', 'live', '', '', '' })
  t.check('in the history', history.list(vim.fn.getcwd())[1].session, 'fake://two')

  view.follow_up = true
  submit(bufnr, 'after')
  t.check('waits for the agent', agent.prompts[2], { 'after', 'follow_up' })
  t.check('once', view.follow_up, nil)

  submit(bufnr, ' private ')
  t.check('trimmed', agent.prompts[3], { 'private', 'steer' })
  t.check('kept out of the history', history.list(vim.fn.getcwd())[1].text, 'after')

  submit(bufnr, '  ')
  t.check('nothing to send', #agent.prompts, 3)
  t.check('the input stays empty', t.lines(bufnr), { 'from one', '', 'live', '', '', '' })
end)

t.describe('commands', function()
  local commands = require('otto.ui.commands')
  local ui_input = vim.ui.input
  vim.ui.input = function(_, on_confirm) on_confirm('  New name  ') end
  commands.run(view, 'name')
  vim.wait(100, function() return agent.renamed ~= nil end)
  vim.ui.input = ui_input
  t.check('names the session, trimmed', agent.renamed, 'New name')

  agent.queue = { 'first', 'second' }
  input.set(bufnr, 'typed')
  commands.run(view, 'abort')
  vim.wait(100, function() return agent.aborted end)
  t.check('aborts', agent.aborted, true)
  t.check('taking back the queue above the input', vim.fn.prompt_getinput(bufnr), 'first\nsecond\ntyped')

  agent.queue = { 'older', 'newest' }
  view.session.state.queue = { { text = 'older', follow_up = true }, { text = 'newest', follow_up = true } }
  input.set(bufnr, '')
  commands.run(view, 'history_older')
  vim.wait(100, function() return #agent.queue == 1 end)
  t.check(
    'takes back the newest queued prompt',
    { vim.fn.prompt_getinput(bufnr), agent.queue },
    { 'newest', { 'older' } }
  )
  view.session.state.queue = {}
  input.set(bufnr, '')

  t.check('keys of those that return them', commands.run(view, 'newline'), '<S-CR>')
  local notified = t.notified(function() commands.run(view, 'nope') end)
  t.check('unknown', notified, { 'otto: unknown command: nope' })
end)

t.describe('restart', function()
  local restarted = view:restart()
  t.check('closes the agent', agent.closed, true)
  t.check('a new view', { restarted ~= nil, restarted ~= view, buffers.get(bufnr) == restarted }, { true, true, true })
  t.check('of a new agent', agents[#agents].id, 'two')
  t.check('which renders again', t.lines(bufnr), { 'from two', '', '', '' })

  local switched = restarted:restart('three')
  t.check('to another session', vim.api.nvim_buf_get_name(bufnr), 'fake://three')
  t.check('its agent', agents[#agents].id, 'three')
  t.check('its transcript', t.lines(bufnr), { 'from three', '', '', '' })

  require('otto.ui.commands').run(switched, 'clear')
  vim.wait(100, function() return agents[#agents].id == 'cleared' end)
  t.check('cleared to a new session', { vim.api.nvim_buf_get_name(bufnr), agents[#agents].id }, {
    'fake://cleared',
    'cleared',
  })
  t.check('closing the one before', agents[#agents - 1].closed, true)
  view = buffers.get(bufnr)
end)

t.describe('unload', function()
  local session = view.session
  views.unload(bufnr)
  t.check('closes the agent', agents[#agents].closed, true)
  t.check('forgets the view', buffers.get(bufnr), nil)
  t.check('and the session', sessions.sessions[session], nil)
  views.unload(bufnr)
  t.check('once', buffers.get(bufnr), nil)
end)

t.describe('open', function()
  local group = vim.api.nvim_create_augroup('otto.view_spec', {})
  vim.api.nvim_create_autocmd('BufReadCmd', {
    group = group,
    pattern = 'fake://*',
    callback = function(ev) views.load(ev.buf) end,
  })
  views.open('fake://new', 'Named')
  t.check('a buffer of the session', vim.api.nvim_buf_get_name(0), 'fake://new')
  t.check('which starts with its name', agents[#agents].opts.name, 'Named')
  views.unload(vim.api.nvim_get_current_buf())
  vim.api.nvim_del_augroup_by_id(group)

  local unknown = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(unknown, 'nope://x')
  local notified = t.notified(function() views.load(unknown) end)
  t.check('unknown agents', notified, { 'otto: unknown agent: nope://x' })
  t.check('without a view', buffers.get(unknown), nil)

  local broken = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(broken, 'fake://broken')
  notified = t.notified(function() views.load(broken) end)
  t.check("agents that can't start", { notified, buffers.get(broken) }, { { 'otto: fake: ENOENT' }, nil })

  local fine = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(fine, 'fake://fine')
  views.load(fine)
  local restarted
  notified = t.notified(function() restarted = buffers.get(fine):restart('broken_too') end)
  t.check('restarting into one', { restarted, buffers.get(fine), notified }, { nil, nil, { 'otto: fake: ENOENT' } })
end)

providers.providers.fake = nil
