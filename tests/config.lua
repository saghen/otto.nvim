-- Run with: nvim --headless -u NONE -l tests/config.lua
vim.opt.runtimepath:prepend(vim.fn.getcwd())

local config = require('otto.config')
local pick = require('otto.pick')
local rpc = require('otto.rpc')
local resume = require('otto.resume')
local tmp = vim.fn.tempname()
local cwd = vim.fn.getcwd()
local saved_env = {}
for _, key in ipairs({ 'HOME', 'PI_CODING_AGENT_DIR', 'PI_CODING_AGENT_SESSION_DIR' }) do
  saved_env[key] = vim.env[key]
end
local system, select, notify = vim.system, vim.ui.select, vim.notify
local run = rpc.run
local count = 0
local function eq(expected, actual)
  assert(vim.deep_equal(expected, actual), 'expected ' .. vim.inspect(expected) .. ', got ' .. vim.inspect(actual))
  count = count + 1
end
local function write(path, entries)
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  local lines = vim.tbl_map(vim.json.encode, entries)
  vim.fn.writefile(lines, path)
end
local function pi_file(root, id)
  local folder = '--' .. vim.fn.getcwd():sub(2):gsub('[/\\:]', '-') .. '--'
  local path = vim.fs.joinpath(root, folder, '2026-01-01_' .. id .. '.jsonl')
  write(path, {
    { type = 'session_info', name = 'Saved session' },
    { type = 'message', message = { role = 'user', content = 'Hello' } },
  })
  return path
end

local ok, err = xpcall(function()
  vim.fn.mkdir(tmp .. '/home', 'p')
  vim.env.HOME = tmp .. '/home'
  vim.env.PI_CODING_AGENT_DIR = nil
  vim.env.PI_CODING_AGENT_SESSION_DIR = nil
  -- Test a project path with spaces and glob characters as well as a literal root.
  vim.fn.mkdir(tmp .. '/project [one]', 'p')
  vim.api.nvim_set_current_dir(tmp .. '/project [one]')

  eq('minibuffer', config.options.picker)
  eq('pi', config.options.pi.command)
  eq({}, config.options.pi.args)
  eq(tmp .. '/home/.pi/agent', config.agent_dir())
  eq(tmp .. '/home/.pi/agent/sessions', config.session_root())
  eq(false, config.session_override())
  for _, value in ipairs({ '', false, 1, {}, { 'pi' }, 'pi\0' }) do
    eq(false, pcall(config.setup, { pi = { command = value } }))
  end
  for _, value in ipairs({ '', false, 1, { 1 }, { false }, { [2] = 'arg' }, { 'arg\0' } }) do
    eq(false, pcall(config.setup, { pi = { args = value } }))
  end
  eq(false, pcall(config.setup, false))
  eq(false, pcall(config.setup, { picker = 'invalid' }))
  eq(false, pcall(config.setup, { pi = { agent_dir = '' } }))
  eq('pi', config.options.pi.command) -- failed setup does not replace options

  vim.env.PI_CODING_AGENT_DIR = ''
  vim.env.PI_CODING_AGENT_SESSION_DIR = ''
  eq(tmp .. '/home/.pi/agent/sessions', config.session_root())
  eq(false, config.session_override())
  vim.env.PI_CODING_AGENT_DIR = tmp .. '/env agent'
  eq(tmp .. '/env agent/sessions', config.session_root())
  vim.env.PI_CODING_AGENT_SESSION_DIR = tmp .. '/env sessions'
  eq(tmp .. '/env sessions', config.session_root())
  config.setup({ pi = { agent_dir = '~/configured agent' } })
  eq(tmp .. '/home/configured agent', config.agent_dir())
  eq(tmp .. '/env sessions', config.session_root()) -- session env beats explicit agent dir
  config.setup({ pi = { agent_dir = '$HOME/configured agent', session_dir = '~/sessions [x]*?' } })
  eq(tmp .. '/home/configured agent', config.agent_dir())
  eq(tmp .. '/home/sessions [x]*?', config.session_root())
  eq(true, config.session_override())
  vim.env.PI_CODING_AGENT_SESSION_DIR = nil
  config.setup({ pi = { agent_dir = '~/configured agent' } })
  eq(tmp .. '/home/configured agent/sessions', config.session_root())

  local claude = require('otto.claude')
  write(claude.session_file('claude-id'), { { type = 'custom-title', customTitle = 'Claude' } })
  write(tmp .. '/home/.codex/sessions/2026/rollout-test.jsonl', {
    { payload = { cwd = vim.fn.getcwd(), source = 'cli', id = 'codex-id' } },
    { type = 'event_msg', payload = { type = 'user_message', message = 'Codex' } },
  })
  for _, case in ipairs({
    { {}, nil, nil, tmp .. '/home/.pi/agent/sessions' },
    { {}, tmp .. '/env agent', nil, tmp .. '/env agent/sessions' },
    { {}, nil, tmp .. '/env sessions', tmp .. '/env sessions' },
    { { agent_dir = '~/configured agent' }, tmp .. '/ignored', nil, tmp .. '/home/configured agent/sessions' },
    { { session_dir = '~/sessions [x]*?' }, tmp .. '/ignored', tmp .. '/ignored too', tmp .. '/home/sessions [x]*?' },
  }) do
    config.setup({ pi = case[1] })
    vim.env.PI_CODING_AGENT_DIR, vim.env.PI_CODING_AGENT_SESSION_DIR = case[2], case[3]
    pi_file(case[4], 'saved-id')
    local sessions = resume.list()
    local uris = vim.tbl_map(function(s) return s.uri end, sessions)
    table.sort(uris)
    eq({ 'claude://claude-id', 'codex://codex-id', 'pi://saved-id' }, uris)
    local pi = vim.iter(sessions):find(function(s) return s.uri == 'pi://saved-id' end)
    eq('Saved session', pi.title)
    eq(1, pi.messages)
  end
  config.setup({ pi = { session_dir = tmp .. '/missing' } })
  eq(2, #resume.list()) -- missing Pi root does not affect other backends
  config.setup({ pi = { session_dir = '~/sessions [x]*?' } })
  -- A glob-like sibling must not be read.
  pi_file(tmp .. '/home/sessions xABCz', 'wrong')
  eq(3, #resume.list())

  -- No installed minibuffer is needed for vim_ui, even after modules have loaded.
  package.preload.minibuffer = function() error('minibuffer must not load') end
  config.setup({ picker = 'vim_ui' })
  local items = { { label = 'same', id = 1 }, { label = 'same', id = 2 } }
  local opts = { prompt = 'Test: ', text = function(item) return item.label end, format = function() return {} end }
  local calls, chosen = 0, nil
  vim.ui.select = function(actual, options, callback)
    assert(actual == items)
    eq('Test: ', options.prompt)
    eq('same', options.format_item(actual[2]))
    callback(actual[2], 2)
  end
  pick.pick(items, opts, function(item)
    calls, chosen = calls + 1, item
  end)
  eq(1, calls)
  assert(chosen == items[2])
  vim.ui.select = function(_, _, callback) callback(nil) end
  calls = 0
  pick.pick(items, opts, function(item)
    calls = calls + 1
    eq(nil, item)
  end)
  eq(1, calls)
  eq(nil, package.loaded.minibuffer)

  local mini
  package.preload.minibuffer = function()
    return { select = function(options) mini = options end }
  end
  config.setup()
  pick.pick(items, opts, function(item) chosen = item end)
  eq('Test: ', mini.prompt)
  eq(10, mini.max_height)
  mini.fetch_fn({}, function(actual) assert(actual == items) end)
  assert(mini.filter_fn({ input = '', items = items }) == items)
  eq(items, mini.filter_fn({ input = 'same', items = items }))
  assert(mini.format_fn == opts.format)
  mini.on_accept({ { item = items[2] } })
  assert(chosen == items[2])
  calls = 0
  pick.pick(items, opts, function(item)
    calls = calls + 1
    chosen = item
  end)
  mini.on_cancel()
  eq(nil, chosen)
  eq(1, calls)

  local launched, launch_opts, exit
  local proc = { is_closing = function() return false end, write = function() end, kill = function() end }
  vim.system = function(cmd, options, callback)
    launched, launch_opts, exit = cmd, options, callback
    return proc
  end
  vim.env.PI_CODING_AGENT_DIR, vim.env.PI_CODING_AGENT_SESSION_DIR = nil, nil
  rpc.start('test', { '--session-id', 'main' }, function() end)
  eq({ 'pi', '--mode', 'rpc', '--session-id', 'main' }, launched)
  eq(nil, launch_opts.env)
  eq(nil, launch_opts.clear_env)
  config.setup({ pi = { command = '/opt/Pi Tools/pi', args = { '--model', 'test model', '' }, agent_dir = '~/agent' } })
  rpc.start('test', {}, function() end)
  eq({ '/opt/Pi Tools/pi', '--model', 'test model', '', '--mode', 'rpc' }, launched)
  eq({ PI_CODING_AGENT_DIR = tmp .. '/home/agent' }, launch_opts.env)
  eq(nil, launch_opts.clear_env)
  config.setup({
    pi = {
      command = '/absolute/pi',
      args = { '--model', 'test' },
      agent_dir = '~/agent',
      session_dir = '~/sessions [x]*?',
    },
  })
  local client = rpc.start('test', { '--session-id', 'saved-id' }, function() end)
  eq({
    '/absolute/pi',
    '--model',
    'test',
    '--mode',
    'rpc',
    '--session-dir',
    config.session_dir(),
    '--session-id',
    'saved-id',
  }, launched)
  eq({ PI_CODING_AGENT_DIR = tmp .. '/home/agent' }, launch_opts.env)
  eq(true, vim.uv.fs_stat(config.session_dir() .. '/2026-01-01_saved-id.jsonl') ~= nil)
  local Client = getmetatable(client)
  local original_prompt = Client.prompt
  Client.prompt = function() return 'helper answer' end
  eq('helper answer', rpc.ask('helper', 'question'))
  Client.prompt = original_prompt
  eq({ PI_CODING_AGENT_DIR = tmp .. '/home/agent' }, launch_opts.env)
  eq({
    '/absolute/pi',
    '--model',
    'test',
    '--mode',
    'rpc',
    '--session-dir',
    config.session_dir(),
    '--no-session',
    '--no-mcp',
  }, launched)
  eq({ '--model', 'test' }, config.options.pi.args)
  config.setup()
  vim.env.PI_CODING_AGENT_SESSION_DIR = tmp .. '/env sessions'
  rpc.start('test', {}, function() end)
  eq({ 'pi', '--mode', 'rpc', '--session-dir', config.session_dir() }, launched)
  eq(nil, launch_opts.env)
  vim.env.PI_CODING_AGENT_SESSION_DIR = nil

  local notification
  vim.notify = function(message) notification = message end
  launch_opts.stderr(nil, 'process failed')
  exit({ code = 7 })
  vim.wait(100, function() return notification ~= nil end)
  eq('otto: test exited: process failed', notification)
  config.setup({ pi = { command = tmp .. '/missing executable' } })
  vim.system = system -- only try an executable that does not exist, never an agent
  local started, failure = pcall(rpc.start, 'missing test', {}, function() end)
  eq(false, started)
  assert(failure:find('otto: could not start missing test', 1, true))
  assert(failure:find('missing executable', 1, true))
  vim.system = function(cmd, options)
    launched, launch_opts = cmd, options
    return proc
  end
  claude.start('new-claude-id', function() end, {})
  eq('claude', launched[1])
  eq({ CLAUDECODE = '' }, launch_opts.env)
  require('otto.codex').start('new-codex-id', function() end)
  eq({ 'codex', 'app-server' }, launched)
  eq(nil, launch_opts.env)

  -- Exercise both public picker callers with real buffers and a stub process.
  package.loaded['otto.lsp'] = { attach = function() end }
  package.loaded['otto.prompt'] = { pin = function() end }
  package.loaded['otto.transcript'] = { clear = function() end, fold = function() end }
  package.loaded['otto.winbar'] = { render = function() return '' end }
  rpc.run = function() end
  local otto = require('otto')
  for _, backend in ipairs({ 'vim_ui', 'minibuffer' }) do
    otto.setup({ picker = backend, pi = { session_dir = '~/sessions [x]*?' } })
    otto.open('first')
    local first = vim.api.nvim_get_current_buf()
    otto.open('second')
    local second = vim.api.nvim_get_current_buf()
    local function choose(actual, options, callback)
      if options.prompt == 'Session: ' then
        eq(2, #actual)
        callback(vim.iter(actual):find(function(item) return item.bufnr == first end))
      else
        eq('Resume session: ', options.prompt)
        callback(vim.iter(actual):find(function(item) return item.uri == 'pi://saved-id' end))
      end
    end
    vim.ui.select = choose
    package.loaded.minibuffer = {
      select = function(options)
        options.fetch_fn({}, function(actual)
          choose(actual, options, function(item) options.on_accept({ { item = item } }) end)
        end)
      end,
    }
    vim.cmd('Otto pick')
    eq(first, vim.api.nvim_get_current_buf())
    vim.cmd('Otto resume')
    eq('pi://saved-id', vim.api.nvim_buf_get_name(0))
    vim.api.nvim_buf_delete(first, { force = true })
    vim.api.nvim_buf_delete(second, { force = true })
    vim.api.nvim_buf_delete(0, { force = true })
  end
end, debug.traceback)

vim.system, vim.ui.select, vim.notify, rpc.run = system, select, notify, run
for _, key in ipairs({ 'HOME', 'PI_CODING_AGENT_DIR', 'PI_CODING_AGENT_SESSION_DIR' }) do
  vim.env[key] = saved_env[key]
end
vim.api.nvim_set_current_dir(cwd)
vim.fn.delete(tmp, 'rf')
if not ok then
  io.stderr:write(err .. '\n')
  vim.cmd('cquit 1')
end
print(('Passed %d configuration checks'):format(count))
vim.cmd('qa!')
