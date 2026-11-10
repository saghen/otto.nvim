-- render/transcript.lua: blocks appended to a prompt buffer, with folds, calls, targets and prompts

local t = ...
local transcript = require('otto.render.transcript')

local call, result = t.call, t.result

--- @return integer bufnr, empty, with folds made in the current window
local function buffer()
  local bufnr = t.scratch({ '' }, 0)
  vim.wo.foldmethod = 'manual'
  return bufnr
end

--- @param bufnr integer
--- @param row integer 0-indexed
--- @return integer[] the closed fold over the row, 1-indexed, or -1
local function closed(bufnr, row)
  return vim.api.nvim_buf_call(
    bufnr,
    function() return { vim.fn.foldclosed(row + 1), vim.fn.foldclosedend(row + 1) } end
  )
end

local diff = {
  { sign = ' ', lnum = 1, text = 'a' },
  { sign = '-', lnum = 2, text = 'b' },
  { sign = '-', lnum = 3, text = 'q' },
  { sign = '+', lnum = 2, text = 'c' },
}
local turn = {
  { type = 'user', text = 'fix it\nplease', at = 0 },
  { type = 'text', text = 'Looking.', at = 0 },
  call('r', 'read', { path = 'a.lua' }),
  result('r', { output = 'a\nb' }),
  call('b', 'bash', { command = 'make' }),
  result('b', { ok = false, output = 'error: x', exit_code = 2 }),
  call('e', 'edit', { path = 'a.lua' }),
  result('e', { diff = diff }),
  { type = 'error', message = 'oops', at = 0 },
}
local turn_end = { type = 'turn_end', at = 60000, started = 0, worked = true, aborted = false }

t.describe('a turn', function()
  local bufnr = buffer()
  local changes = 0
  local tr = t.render(bufnr, turn, function() changes = changes + 1 end)
  t.check('lines', t.lines(bufnr), {
    'fix it',
    'please',
    '',
    'Looking.',
    'read 1 file, ran 1 command, 1 failed',
    '  read a.lua',
    '    a',
    '    b',
    '  $ make  exit 2',
    '    error: x',
    'edit a.lua  +1 -2',
    '   1 a',
    '  -2 b',
    '  -3 q',
    '  +2 c',
    '',
    'oops',
    '',
    '',
    '',
  })
  t.check('input below the separator', vim.api.nvim_buf_get_mark(bufnr, ':')[1], 20)
  t.check('each op changes it', changes, 6)
  t.check('tools fold as they render', tr.folds, {
    { top = 6, bottom = 8, nested = true },
    { top = 9, bottom = 10, nested = true },
    { top = 11, bottom = 15, nested = false },
  })
  t.check('closed in the window', { closed(bufnr, 6), closed(bufnr, 11) }, { { 6, 8 }, { 11, 15 } })
  t.check('the group stays open while the turn runs', closed(bufnr, 4), { -1, -1 })

  tr:apply({ type = 'turn_end' })
  t.check('the group folds once it ends', tr.folds[4], { top = 5, bottom = 10, nested = false })
  t.check('from its summary', closed(bufnr, 7), { 5, 10 })
  t.check('nothing pends', tr.pending_folds, {})

  t.check('call of the header', tr:call_at(5), { id = 'r', tool = 'read', args = { path = 'a.lua' }, output = 'a\nb' })
  t.check('call of the output', tr:call_at(9).id, 'b')
  t.check('call of a diff', tr:call_at(14).id, 'e')
  t.check('no call of a summary', tr:call_at(4), nil)
  t.check('no call of text', tr:call_at(3), nil)
  t.check('no call past the tool', tr:call_at(15), nil)
end)

t.describe('targets', function()
  local bufnr = buffer()
  local tr = t.render(bufnr, turn)
  t.check('read header', tr:target_at(5), { path = 'a.lua', lnum = 1 })
  t.check('read lines count up', tr:target_at(7), { path = 'a.lua', lnum = 2 })
  t.check('not past them', tr:target_at(8), nil)
  t.check('diff header at the first change', tr:target_at(10), { path = 'a.lua', lnum = 2 })
  t.check('kept line', tr:target_at(11), { path = 'a.lua', lnum = 1 })
  t.check('removed lines open at the next new line', { tr:target_at(12), tr:target_at(13) }, {
    { path = 'a.lua', lnum = 2 },
    { path = 'a.lua', lnum = 2 },
  })
  t.check('added line', tr:target_at(14), { path = 'a.lua', lnum = 2 })
  t.check('text has none', tr:target_at(3), nil)

  local grep = buffer()
  local found = t.render(grep, { call('g', 'grep', { pattern = 'x' }), result('g', { output = 'a.lua:12:x\nother' }) })
  t.check('location of a line', found:target_at(2), { path = 'a.lua', lnum = 12 })
  t.check('a line without one', found:target_at(3), nil)
end)

t.describe('groups', function()
  local bufnr = buffer()
  local tr = t.render(bufnr, { call('a', 'read', { path = 'a' }), result('a', { output = 'x' }) })
  t.check('summary on its own line', t.lines(bufnr)[1], 'read 1 file')
  tr:apply({ type = 'block', block = t.layout({ call('b', 'read', { path = 'b' }), result('b') })[1] })
  -- a block that starts its own group, though the transcript has one open
  t.check(
    'a first tool starts another',
    t.lines(bufnr),
    { 'read 1 file', '  read a', '    x', '', 'read 1 file', '  read b', '', '', '' }
  )
  t.check('with a fold of its own', tr.pending_folds[2], { top = 5, bottom = 6, nested = false })

  local more = buffer()
  local events = {
    call('a', 'read', { path = 'a' }),
    result('a', { output = 'x' }),
    call('b', 'grep', { pattern = 'p' }),
    result('b'),
  }
  local grouped = t.render(more, events)
  t.check('summary rewritten', t.lines(more)[1], 'read 1 file, searched 1 pattern')
  t.check('the group grows to the last tool', grouped.group_fold, { top = 1, bottom = 4, nested = false })
  local text = t.layout({ { type = 'text', text = 'done', at = 0 } })[1]
  grouped:apply({ type = 'block', block = text })
  t.check('other blocks end it', grouped.group_fold, nil)
  t.check('still pending until the turn ends', #grouped.pending_folds, 1)
end)

t.describe('prompts', function()
  local bufnr = buffer()
  local tr = t.render(bufnr, {
    { type = 'user', text = 'one', at = 0 },
    { type = 'text', text = 'ok', at = 0 },
    { type = 'user', text = 'two\nlines', at = 0 },
  })
  t.check('lines', t.lines(bufnr), { 'one', '', 'ok', '', 'two', 'lines', '', '', '' })
  t.check('all', tr:prompts(), { { row = 0, text = 'one' }, { row = 4, text = 'two\nlines' } })
  t.check('is prompt', { tr:is_prompt(0), tr:is_prompt(2), tr:is_prompt(5) }, { true, false, true })
  t.check('next', tr:find_prompt(0, false), 4)
  t.check('previous', tr:find_prompt(5, true), 4)
  t.check('previous of the second', tr:find_prompt(4, true), 0)
  t.check('none after the last', tr:find_prompt(4, false), nil)
end)

t.describe('input', function()
  local bufnr = buffer()
  vim.bo[bufnr].undolevels = 100
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'typed' })
  local undo_seq = vim.fn.undotree(bufnr).seq_last
  local tr = t.render(bufnr, { { type = 'text', text = 'hi', at = 0 } })
  t.check('keeps the input below', t.lines(bufnr), { 'hi', '', '', 'typed' })
  t.check('outside the undo history', vim.fn.undotree(bufnr).seq_last, undo_seq)
  t.check('undo levels back', vim.bo[bufnr].undolevels, 100)

  -- the prompt buffer leaves what's submitted above a new input line
  vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { '' })
  vim.api.nvim_buf_set_mark(bufnr, ':', 5, 0, {})
  tr:remove_submitted('typed')
  t.check('submitted removed', t.lines(bufnr), { 'hi', '', '', '' })
  t.check('input after the separator', vim.api.nvim_buf_get_mark(bufnr, ':')[1], 4)

  vim.bo[bufnr].modifiable = false
  tr:apply({ type = 'block', block = t.layout({ { type = 'text', text = 'more', at = 0 } })[1] })
  t.check('appends to an unmodifiable buffer', t.lines(bufnr), { 'hi', '', 'more', '', '', '' })
  t.check('which stays unmodifiable', vim.bo[bufnr].modifiable, false)
  vim.bo[bufnr].modifiable = true

  -- like deleting all of the input
  vim.api.nvim_buf_set_lines(bufnr, 5, -1, false, {})
  tr:anchor()
  t.check('anchored lines', t.lines(bufnr), { 'hi', '', 'more', '', '', '' })
  t.check('anchored mark', vim.api.nvim_buf_get_mark(bufnr, ':')[1], 6)
end)

t.describe('new', function()
  local bufnr = t.scratch({ 'old', 'output', 'typed' }, 2)
  local tr = transcript.new(bufnr, function() end)
  t.check('removes the transcript, keeping the input', t.lines(bufnr), { 'typed' })
  t.check('input mark', vim.api.nvim_buf_get_mark(bufnr, ':')[1], 1)
  t.check('nothing kept', { tr.folds, tr.calls, tr.targets }, { {}, {}, {} })
end)

t.describe('fold', function()
  local bufnr = buffer()
  local tr = t.render(bufnr, vim.list_extend(vim.deepcopy(turn), { turn_end }))
  vim.cmd('normal! zE')
  t.check('unfolded', closed(bufnr, 7), { -1, -1 })
  tr:fold()
  t.check('the group again', closed(bufnr, 7), { 5, 10 })
  vim.cmd('5foldopen')
  t.check('with its tools inside', closed(bufnr, 7), { 6, 8 })
  t.check('and the edit', closed(bufnr, 12), { 11, 15 })
end)
