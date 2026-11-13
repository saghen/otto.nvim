-- What the providers share: effort levels, and unified diff hunks

local t = ...
local diff = require('otto.providers.diff')
local util = require('otto.util')

t.describe('next_effort', function()
  t.check('next', util.next_effort({ 'low', 'high' }, 'low'), 'high')
  t.check('wraps', util.next_effort({ 'low', 'high' }, 'high'), 'low')
  t.check('unknown starts over', util.next_effort({ 'low', 'high' }, 'max'), 'low')
  t.check('none has the usual', util.efforts({}), { 'low', 'medium', 'high' })
  t.check('nothing yet', util.next_effort({ 'low', 'high' }, nil), 'low')
end)

t.describe('hunk', function()
  t.check('numbered in each file', diff.hunk({ ' a', '-b', '+c', '+d', ' e' }, 10, 20), {
    { sign = ' ', lnum = 20, text = 'a' },
    { sign = '-', lnum = 11, text = 'b' },
    { sign = '+', lnum = 21, text = 'c' },
    { sign = '+', lnum = 22, text = 'd' },
    { sign = ' ', lnum = 23, text = 'e' },
  })
  t.check('empty context lines', diff.hunk({ '', '+x' }, 1, 1), {
    { sign = ' ', lnum = 1, text = '' },
    { sign = '+', lnum = 2, text = 'x' },
  })
  t.check('without no newline markers', diff.hunk({ '-a', '\\ No newline at end of file', '+b' }, 1, 1), {
    { sign = '-', lnum = 1, text = 'a' },
    { sign = '+', lnum = 1, text = 'b' },
  })
end)

t.describe('names', function()
  local names = vim.tbl_keys(require('otto.providers').providers)
  names = vim.tbl_filter(function(name) return name ~= 'fake' end, names)
  table.sort(names)
  local listed = vim.deepcopy(require('otto.uri').providers)
  table.sort(listed)
  t.check('the registry has those that plugin/otto.lua loads', names, listed)
end)
