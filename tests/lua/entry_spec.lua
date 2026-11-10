-- What loads otto: the providers' entries, require('otto'), plugin/otto.lua and ftplugin/otto.lua

local t = ...

t.describe('providers', function()
  local claude = require('otto.providers.claude')
  local codex = require('otto.providers.codex')
  local pi = require('otto.providers.pi')

  for _, provider in ipairs({ claude, codex, pi }) do
    t.check(provider.name .. ' is whole', {
      type(provider.icon),
      type(provider.new_id),
      type(provider.open),
      type(provider.files),
      type(provider.parse),
    }, { 'string', 'function', 'function', 'function', 'function' })
  end
  t.match('claude ids are uuids', claude.new_id(), '^%x+%-%x+%-%x+%-%x+%-%x+$')
  t.check('codex ids of names', codex.new_id('fix the bug!'), 'fix_the_bug_')
  t.match('codex ids without', codex.new_id(), '^%d+_%d+_%d+_%d+$')
  t.check('codex names', codex.names, require('otto.providers.codex.files').names)

  local home = vim.env.HOME
  vim.env.HOME = vim.fn.tempname()
  t.check('pi ids start and end with a letter', pi.new_id('  -fix the bug!- '), 'fix_the_bug')
  t.match('pi ids without a name', pi.new_id('!!'), '^%d+_%d+_%d+_%d+$')
  local folder = ('%s/.pi/agent/sessions/--%s--'):format(vim.env.HOME, (vim.fn.getcwd():sub(2):gsub('[/\\:]', '-')))
  vim.fn.mkdir(folder, 'p')
  vim.fn.writefile({}, folder .. '/2026_taken.jsonl')
  t.match('pi ids of sessions that exist', pi.new_id('taken'), '^taken_%d+$')
  vim.fn.delete(vim.env.HOME, 'rf')
  vim.env.HOME = home
end)

if not pcall(require, 'blink.lib.config') then return t.skip('the config needs blink.lib, in BLINK_LIB') end

local otto = require('otto')
local providers = require('otto.providers')
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.abspath(debug.getinfo(1, 'S').source:sub(2)))))

t.describe('otto', function()
  otto.setup({ default_provider = 'claude' })
  t.check('setup', require('otto.config').get().default_provider, 'claude')
  t.check('unknown agent', t.notified(function() otto.new(nil, 'nope') end), { 'otto: unknown agent: nope' })
  vim.g.statusline_winid = vim.api.nvim_get_current_win()
  t.check('statuscolumn outside sessions', otto.statuscolumn(), '  ')
  t.check('winbar outside sessions', otto.winbar(), '')
end)

t.describe('plugin', function()
  vim.g.loaded_otto = nil
  vim.cmd.source(root .. '/plugin/otto.lua')
  t.check('links highlights', vim.api.nvim_get_hl(0, { name = 'OttoPrompt' }).link, 'QuickFixLine')
  vim.cmd.colorscheme('default')
  t.check('again after a colorscheme', vim.api.nvim_get_hl(0, { name = 'OttoPrompt' }).link, 'QuickFixLine')
  t.check('loads once', pcall(vim.cmd.source, root .. '/plugin/otto.lua'), true)

  local complete = vim.fn.getcompletion('Otto ', 'cmdline')
  for _, name in ipairs({ 'claude', 'codex', 'pi', 'pick', 'resume', 'send' }) do
    t.check('completes ' .. name, vim.list_contains(complete, name), true)
  end
  t.check('completes by prefix', vim.fn.getcompletion('Otto co', 'cmdline'), { 'codex' })
  t.check('unknown subcommand', t.notified(function() vim.cmd('Otto nope') end), { 'otto: unknown subcommand: nope' })

  local saved = providers.saved
  providers.saved = function() return { { provider = 'pi', id = 'abc' }, { provider = 'pi', id = 'xyz' } } end
  t.check('completes saved ids', vim.fn.getcompletion('Otto resume ', 'cmdline'), { 'abc', 'xyz' })
  t.check(
    'resumes only saved',
    t.notified(function() vim.cmd('Otto resume nope') end),
    { 'otto: no saved session nope' }
  )
  providers.saved = saved
end)

t.describe('ftplugin', function()
  local bufnr = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_set_current_buf(bufnr)
  vim.cmd.runtime('ftplugin/otto.lua')
  t.check('once per buffer', vim.b[bufnr].did_ftplugin, true)
  t.check('plugs', vim.fn.maparg('<Plug>(otto-submit)', 'n') ~= '', true)
  t.match('undoes its autocmds', vim.b[bufnr].undo_ftplugin, ('buffer = %d'):format(bufnr))
  vim.api.nvim_exec_autocmds('BufWinEnter', { buffer = bufnr })
  local wo = vim.wo[0][0]
  t.check('window options', { wo.foldmethod, wo.wrap, wo.number, wo.signcolumn }, { 'manual', true, false, 'no' })
  t.match('winbar from otto', wo.winbar, "require'otto'%.winbar")
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)
