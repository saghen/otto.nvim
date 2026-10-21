-- Run with: nvim --headless -u NONE --cmd 'set rtp+=/path/to/blink.lib' -l tests/config.lua
vim.opt.runtimepath:prepend(vim.fn.getcwd())

local config = require('otto.config')
local pi = require('otto.providers.pi')
local pick = require('otto.ui.pick')
local tmp, cwd = vim.fn.tempname(), vim.fn.getcwd()
local saved_env = {}
for _, key in ipairs({ 'HOME', 'PI_CODING_AGENT_DIR', 'PI_CODING_AGENT_SESSION_DIR' }) do
  saved_env[key] = vim.env[key]
end
local system, select = vim.system, vim.ui.select
local count = 0
local function eq(expected, actual)
  assert(vim.deep_equal(expected, actual), 'expected ' .. vim.inspect(expected) .. ', got ' .. vim.inspect(actual))
  count = count + 1
end
local function pi_file(root, id)
  local folder = '--' .. vim.fn.getcwd():sub(2):gsub('[/\\:]', '-') .. '--'
  local path = vim.fs.joinpath(root, folder, '2026-01-01_' .. id .. '.jsonl')
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  vim.fn.writefile(
    vim.tbl_map(vim.json.encode, {
      { type = 'session_info', name = 'Saved session' },
      { type = 'message', message = { role = 'user', content = 'Hello' } },
    }),
    path
  )
  return path
end

local ok, err = xpcall(function()
  vim.fn.mkdir(tmp .. '/home', 'p')
  vim.env.HOME = tmp .. '/home'
  vim.env.PI_CODING_AGENT_DIR, vim.env.PI_CODING_AGENT_SESSION_DIR = nil, nil
  vim.fn.mkdir(tmp .. '/project [one]', 'p')
  vim.api.nvim_set_current_dir(tmp .. '/project [one]')

  eq('auto', config.picker)
  eq({ 'pi' }, config.providers.pi.cmd)
  local base = { cmd = { 'pi' }, args = {}, env = {} }
  for _, case in ipairs({
    { {}, nil, nil, tmp .. '/home/.pi/agent/sessions' },
    { {}, '', '', tmp .. '/home/.pi/agent/sessions' },
    { {}, tmp .. '/env agent', nil, tmp .. '/env agent/sessions' },
    { {}, nil, tmp .. '/env sessions', tmp .. '/env sessions' },
    {
      { PI_CODING_AGENT_DIR = '~/configured agent' },
      tmp .. '/ignored',
      nil,
      tmp .. '/home/configured agent/sessions',
    },
    {
      { PI_CODING_AGENT_SESSION_DIR = '$HOME/sessions [x]*?' },
      tmp .. '/ignored',
      tmp .. '/ignored too',
      tmp .. '/home/sessions [x]*?',
    },
  }) do
    config.set({ providers = { pi = vim.tbl_extend('force', base, { env = case[1] }) } })
    vim.env.PI_CODING_AGENT_DIR, vim.env.PI_CODING_AGENT_SESSION_DIR = case[2], case[3]
    local file = pi_file(case[4], 'saved-id')
    local files = pi.files()
    eq(1, #files)
    eq(file, files[1].file)
    local info = files[1].read(file, 1)
    eq('saved-id', info.id)
    eq('Saved session', info.title)
    eq(1, info.messages)
  end
  pi_file(tmp .. '/home/sessions xABCz', 'wrong')
  eq(1, #pi.files())
  config.set({ providers = { pi = { env = { PI_CODING_AGENT_SESSION_DIR = tmp .. '/missing' } } } })
  eq(0, #pi.files())

  config.set({ picker = 'vim_ui' })
  package.preload.minibuffer = function() error('minibuffer must not load') end
  local items = { { label = 'same' }, { label = 'same' } }
  local chosen, cancelled
  local picker = {
    prompt = 'Test: ',
    items = function() return items end,
    format = function(item) return { { item.label } } end,
    on_accept = function(item) chosen = item end,
    on_cancel = function() cancelled = true end,
  }
  vim.ui.select = function(actual, opts, callback)
    assert(actual == items)
    eq('Test: ', opts.prompt)
    eq('same', opts.format_item(actual[2]))
    callback(actual[2])
  end
  pick.select(picker)
  assert(chosen == items[2])
  eq(nil, package.loaded.minibuffer)
  vim.ui.select = function(_, _, callback) callback(nil) end
  pick.select(picker)
  eq(true, cancelled)
  config.set({ picker = 'auto' })
  cancelled = false
  pick.select(picker)
  eq(true, cancelled)

  local launched, options
  vim.system = function(cmd, opts)
    launched, options = cmd, opts
    return { is_closing = function() return false end, kill = function() end }
  end
  -- Do not run the initial RPC state request in this process-stub test.
  local util = require('otto.util')
  local run = util.run
  util.run = function() end
  vim.env.PI_CODING_AGENT_DIR, vim.env.PI_CODING_AGENT_SESSION_DIR = nil, nil
  local settings = {
    cmd = { '/opt/Pi Tools/pi', '--model', 'test model' },
    args = { '--no-skills' },
    env = { PI_CODING_AGENT_DIR = '~/agent', PI_CODING_AGENT_SESSION_DIR = '~/sessions [x]*?' },
  }
  local handle = pi.open('saved-id', { config = settings, on_log = function() end, on_status = function() end })
  eq({
    '/opt/Pi Tools/pi',
    '--model',
    'test model',
    '--mode',
    'rpc',
    '--session-dir',
    vim.fs.dirname(pi_file(tmp .. '/home/sessions [x]*?', 'saved-id')),
    '--session-id',
    'saved-id',
    '--no-skills',
  }, launched)
  eq(tmp .. '/home/agent', options.env.PI_CODING_AGENT_DIR)
  eq('~/agent', settings.env.PI_CODING_AGENT_DIR) -- launch does not mutate setup
  handle:close()
  util.run = run

  -- One-shot prompts use the same native provider command and directory configuration.
  local proc = require('otto.proc')
  local start = proc.start_provider
  local captured
  proc.start_provider = function(settings, args)
    captured = { settings = settings, args = args }
    return {
      request = function(_, _, callback)
        if callback then callback('test stop') end
      end,
      close = function() end,
    }
  end
  local done
  vim.async
    .run(function()
      local success = pcall(pi.ask, 'question', { config = settings })
      eq(false, success)
      done = true
    end)
    :detach()
  assert(vim.wait(1000, function() return done end))
  eq(settings.cmd, captured.settings.cmd)
  eq('--session-dir', captured.args[3])
  eq('--no-session', captured.args[5])
  proc.start_provider = start
end, debug.traceback)

vim.system, vim.ui.select = system, select
vim.api.nvim_set_current_dir(cwd)
for key, value in pairs(saved_env) do
  vim.env[key] = value
end
vim.fn.delete(tmp, 'rf')
if not ok then error(err) end
print(('Passed %d configuration checks'):format(count))
