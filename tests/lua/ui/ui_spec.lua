-- The input, folds, winbar and keymaps of a session's buffer, over a scratch buffer and fake views

local t = ...
local commands = require('otto.ui.commands')
local folds = require('otto.render.folds')
local input = require('otto.input')
local winbar = require('otto.ui.winbar')

local scratch = t.scratch

t.describe('input', function()
  local bufnr = scratch({ 'transcript', 'more', 'typed', 'lines' }, 2)
  t.check('row', input.row(bufnr), 2)
  input.set(bufnr, 'new\ntext')
  t.check(
    'replaces the input',
    vim.api.nvim_buf_get_lines(bufnr, 0, -1, false),
    { 'transcript', 'more', 'new', 'text' }
  )
  input.set(bufnr, '')
  t.check('empties it', vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), { 'transcript', 'more', '' })
end)

t.describe('folds', function()
  local bufnr = scratch({ 'a', 'b', 'c', 'd', 'e', 'f' }, 5)
  vim.wo.foldmethod = 'manual'
  local list = {}
  folds.add(bufnr, list, 2, 3, true)
  folds.add(bufnr, list, 1, 5, false)
  t.check('kept', #list, 2)
  t.check('closed in the window', { vim.fn.foldclosed(2), vim.fn.foldclosedend(2) }, { 1, 5 })
  vim.cmd('normal! zE')
  folds.apply(list)
  t.check('applied again', { vim.fn.foldclosed(4), vim.fn.foldclosedend(4) }, { 1, 5 })
  vim.cmd('1foldopen')
  t.check('nested inside', { vim.fn.foldclosed(2), vim.fn.foldclosedend(2) }, { 2, 3 })
  t.check('not past it', vim.fn.foldclosed(6), -1)
end)

t.describe('winbar', function()
  local function view(state) return { session = { provider = { icon = 'P ' }, state = state } } end
  t.check(
    'name and fields',
    winbar.render(view({ id = 'x', name = 'n', model = 'm', effort = 'high' })),
    table.concat({
      '  %#OttoWinbarIcon#P %#Normal#n',
      '%#OttoWinbarSeparator# | %#OttoWinbarLabel#model: %#Normal#m',
      '%#OttoWinbarSeparator# | %#OttoWinbarLabel#effort: %#Normal#high',
    })
  )
  t.match('id without a name', winbar.render(view({ id = 'abc' })), '%%#Normal#abc$')
  t.match(
    'context and cost',
    winbar.render(view({ id = 'x', context_tokens = 50, context_window = 200, cost = 1.234 })),
    'context: %%#Normal#25%%%%.*cost: %%#Normal#%$1%.23$'
  )
  t.match(
    'context of where the agent compacts',
    winbar.render(view({ id = 'x', context_tokens = 50, context_window = 400, compact_at = 100 })),
    'context: %%#Normal#50%%%%$'
  )
  t.match('no cost under a cent', winbar.render(view({ id = 'x', cost = 0.004 })), '^[^$]*$')
  t.match('escapes %', winbar.render(view({ id = '100%' })), '100%%%%$')
end)

t.describe('commands', function()
  t.check('plug', commands.plug('submit'), '<Plug>(otto-submit)')
  t.check('known', commands.get('submit') ~= nil, true)
  t.check('unknown', commands.get('nope'), nil)
  t.check('by mode of a table', commands.by_mode({ n = 'submit', i = false }), { n = 'submit' })
  t.check('turned off', commands.by_mode(false), {})
  local modes = commands.get('submit').modes or { 'n' }
  t.check('by mode of a name', vim.tbl_count(commands.by_mode('submit')), #modes)
  t.check('not in insert mode of the local leader', commands.by_mode('history', '<LocalLeader>h'), { n = 'history' })
  t.check('unless mapped there', commands.by_mode({ i = 'history' }, '<LocalLeader>h'), { i = 'history' })
end)

if not pcall(require, 'blink.lib.config') then return t.skip('the config needs blink.lib, in BLINK_LIB') end

t.describe('keymaps', function()
  local keymaps = require('otto.ui.keymaps')
  local config = require('otto.config')
  keymaps.define_plugs()
  t.check('plugs', vim.fn.maparg(commands.plug('submit'), (commands.get('submit').modes or { 'n' })[1]) ~= '', true)

  local bufnr = scratch({ '' }, 0)
  vim.keymap.set('n', '<F2>', '<Nop>', { buf = bufnr })
  config.set({ keymaps = { ['<F2>'] = 'submit', ['<F3>'] = { n = 'submit' } } }, { bufnr = bufnr })
  keymaps.attach({ bufnr = bufnr })
  t.check('maps to the plug', vim.fn.maparg('<F3>', 'n'), commands.plug('submit'))
  t.check("not over the buffer's own", vim.fn.maparg('<F2>', 'n'), '<Nop>')
  local mapped = vim.tbl_map(function(map) return map.mode .. map.lhs end, vim.b[bufnr].otto_keymaps)
  -- submit maps in insert mode too, where the buffer has none of its own
  t.check(
    'remembers what it mapped',
    { vim.list_contains(mapped, 'n<F3>'), vim.list_contains(mapped, 'n<F2>') },
    { true, false }
  )

  config.set({ keymaps = { ['<F3>'] = false } }, { bufnr = bufnr })
  keymaps.attach({ bufnr = bufnr })
  t.check('unmaps what the config dropped', vim.fn.maparg('<F3>', 'n'), '')

  config.set({ keymaps = { ['<F4>'] = 'nope', ['<F5>'] = { i = 'open' } } }, { bufnr = bufnr })
  local notified = t.notified(function() keymaps.attach({ bufnr = bufnr }) end)
  table.sort(notified)
  t.check('notifies commands that it can not map', notified, {
    'otto: keymaps[<F4>]: unknown command "nope"',
    'otto: keymaps[<F5>]: open has no keymap in mode i',
  })
  t.check('without mapping them', { vim.fn.maparg('<F4>', 'n'), vim.fn.maparg('<F5>', 'i') }, { '', '' })
  local ok, err = pcall(config.set, { keymaps = { ['<F6>'] = 1 } }, { bufnr = bufnr })
  t.check('the config checks the shape', ok, false)
  t.match('of each', tostring(err), 'expected command or false, got 1')
end)
