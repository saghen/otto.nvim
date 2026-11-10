-- track.net and the quickfix list of edits

local t = ...
local changes = require('otto.ui.changes')
local track = require('otto.track')

local function change(at, path, before, after, extra)
  return vim.tbl_extend(
    'force',
    { at = at, op = 'write', path = path, before = before, after = after, pid = 1 },
    extra or {}
  )
end

t.describe('net', function()
  t.check('writes', track.net({ change(1, 'a', nil, 'h1', { cmd = 'vim' }), change(2, 'a', 'h1', 'h2') }), {
    { path = 'a', before = nil, after = 'h2', at = 1, cmd = 'vim' },
  })
  t.check(
    'created and gone',
    track.net({ change(1, 'tmp', nil, 'h1'), change(2, 'tmp', 'h1', nil, { op = 'remove' }) }),
    {}
  )
  t.check('reverted', track.net({ change(1, 'a', 'h1', 'h2'), change(2, 'a', 'h2', 'h1') }), {})
  t.check(
    'order of first change',
    vim.tbl_map(
      function(net) return net.path end,
      track.net({
        change(1, 'b', nil, 'x'),
        change(2, 'a', nil, 'y'),
        change(3, 'b', 'x', 'z'),
      })
    ),
    { 'b', 'a' }
  )
  t.check('moved', track.net({ change(1, 'b', nil, 'h1', { op = 'rename', from = 'a' }) }), {
    { path = 'b', from = 'a', before = 'h1', after = 'h1', at = 1 },
  })
  t.check(
    'moved and back',
    track.net({
      change(1, 'b', nil, 'h1', { op = 'rename', from = 'a' }),
      change(2, 'a', nil, 'h1', { op = 'rename', from = 'b' }),
    }),
    {}
  )
  -- like Vim's backups: the file moves away, a new one is written, and the backup goes
  t.check(
    'saved through a backup',
    track.net({
      change(1, 'a~', nil, 'h1', { op = 'rename', from = 'a', cmd = 'nvim' }),
      change(2, 'a', nil, 'h2'),
      change(3, 'a~', 'h1', nil, { op = 'remove' }),
    }),
    { { path = 'a', before = 'h1', after = 'h2', at = 1, cmd = 'nvim' } }
  )
end)

t.describe('quickfix_edits', function()
  local diff = { { sign = ' ', lnum = 4, text = 'a' }, { sign = '+', lnum = 5, text = 'b' } }
  local events = {
    { type = 'tool_call', id = 'e', tool = 'edit', args = { path = 'a.lua' }, at = 0 },
    { type = 'tool_result', id = 'e', ok = true, diff = diff, at = 0 },
    { type = 'tool_call', id = 'b', tool = 'bash', args = { command = 'make fmt' }, at = 0 },
    { type = 'tool_result', id = 'b', ok = true, at = 0 },
    { type = 'tool_call', id = 'r', tool = 'bash', args = { command = 'sleep 9' }, at = 0 },
  }
  local changed = {
    { filename = '/w/b.lua', call = 'b', lnum = 3, added = 2, removed = 1, at = 5, path = 'b.lua', after = 'h' },
    {
      filename = '/w/c.lua',
      call = 'b',
      lnum = 1,
      added = 0,
      removed = 0,
      at = 6,
      path = 'c.lua',
      from = 'old.lua',
      after = 'h',
    },
    { filename = '/w/gone', call = 'r', lnum = 1, added = 0, removed = 3, at = 4, path = 'gone' },
    { filename = '/w/x', lnum = 1, added = 1, removed = 0, at = 3, path = 'x', after = 'h', cmd = 'git' },
  }
  t.check('entries', changes.quickfix_edits(events, changed), {
    { filename = 'a.lua', lnum = 5, text = 'edit a.lua  +1 -0' },
    { filename = '/w/b.lua', lnum = 3, text = '$ make fmt  +2 -1' },
    { filename = '/w/c.lua', lnum = 1, text = '$ make fmt  +0 -0  from old.lua' },
    -- of no call, and of calls still running, by when they changed
    { filename = '/w/x', lnum = 1, text = 'git  +1 -0' },
    { filename = '/w/gone', lnum = 1, text = '$ sleep 9  removed' },
  })
  t.check('untracked', changes.quickfix_edits(events), { { filename = 'a.lua', lnum = 5, text = 'edit a.lua  +1 -0' } })
  local orphan = { { type = 'tool_result', id = 'z', ok = true, diff = diff, at = 0 } }
  t.check('result without call', changes.quickfix_edits(orphan), {})
end)
