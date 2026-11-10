-- render/layout.lua: events into blocks

local t = ...
local layout = require('otto.render.layout')
local util = require('otto.util')

--- @param events table[]
--- @return table[] what blocks show, without highlights
local function shapes(events)
  return vim.tbl_map(function(block)
    if block == 'turn_end' then return 'turn_end' end
    return {
      kind = block.kind,
      spaced = block.spaced,
      lines = block.lines,
      group = block.group and { util.join(block.group.summary), block.group.first },
      fold = block.fold,
    }
  end, t.layout(events))
end

local call, result = t.call, t.result

t.describe('spaced', function()
  local l = layout.new()
  t.check('first block', l:spaced('tool'), true)
  l.last_kind = 'text'
  t.check('tool after text', l:spaced('tool'), false)
  t.check('text after text', l:spaced('text'), true)
  l.last_kind = 'tool'
  t.check('tool after tool', l:spaced('tool'), false)
  l.last_kind = 'user'
  t.check('tool after prompt', l:spaced('tool'), true)
end)

t.describe('a turn', function()
  local diff = {
    { sign = ' ', lnum = 1, text = 'a' },
    { sign = '-', lnum = 2, text = 'b' },
    { sign = '+', lnum = 2, text = 'c' },
  }
  local events = {
    { type = 'user', text = 'fix it\nplease', at = 0 },
    { type = 'text', text = 'Looking.', at = 0 },
    call('r', 'read', { path = 'a.lua' }),
    result('r', { output = 'a\nb' }),
    call('b', 'bash', { command = 'make' }),
    result('b', { ok = false, output = 'error: x', exit_code = 2 }),
    call('e', 'edit', { path = 'a.lua' }),
    result('e', { diff = diff }),
    call('g', 'grep', { pattern = 'c' }),
    result('g', { output = '' }),
    { type = 'text', text = 'Fixed.', at = 0 },
  }
  t.check('blocks', shapes(events), {
    { kind = 'user', spaced = true, lines = { 'fix it', 'please' } },
    { kind = 'text', spaced = true, lines = { 'Looking.' } },
    {
      kind = 'tool',
      spaced = false,
      lines = { '  read a.lua', '    a', '    b' },
      group = { 'read 1 file', true },
      fold = true,
    },
    {
      kind = 'tool',
      spaced = false,
      lines = { '  $ make  exit 2', '    error: x' },
      group = { 'read 1 file, ran 1 command, 1 failed', false },
      fold = true,
    },
    { kind = 'tool', spaced = false, lines = { 'edit a.lua  +1 -1', '   1 a', '  -2 b', '  +2 c' }, fold = true },
    { kind = 'tool', spaced = false, lines = { '  grep c' }, group = { 'searched 1 pattern', true }, fold = false },
    { kind = 'text', spaced = true, lines = { 'Fixed.' } },
  })

  local blocks = t.layout(events)
  local edit = blocks[5]
  t.check('edit filetype', edit.diff, { filetype = 'lua' })
  t.check('edit call', edit.call, { id = 'e', tool = 'edit', args = { path = 'a.lua' } })
  t.check('edit targets', edit.targets, {
    { index = 0, path = 'a.lua', lnum = 2 },
    { index = 1, count = 3, path = 'a.lua', parse = 'diff' },
  })
  t.check(
    'edit highlights',
    edit.highlights,
    { { index = 2, hl_group = 'DiffDelete' }, { index = 3, hl_group = 'DiffAdd' } }
  )
  t.check(
    'read target',
    blocks[3].targets,
    { { index = 1, count = 2, path = 'a.lua', lnum = 1 }, { index = 0, path = 'a.lua', lnum = 1 } }
  )
  t.check('bash call keeps output', blocks[4].call.output, 'error: x')
end)

t.describe('tools', function()
  local function only(events) return shapes(events)[1] end
  t.check('write', only({ call('w', 'write', { path = 'n.py', content = 'x\ny\n' }), result('w') }), {
    kind = 'tool',
    spaced = true,
    lines = { 'write n.py  +2', '  x', '  y' },
    fold = true,
  })
  t.check(
    'write empty',
    only({ call('w', 'write', { path = 'e', content = '' }), result('w') }).lines,
    { 'write e  +0' }
  )
  t.check(
    'failed write is grouped',
    only({ call('w', 'write', { path = 'n', content = 'x' }), result('w', { ok = false, output = 'denied' }) }),
    {
      kind = 'tool',
      spaced = true,
      lines = { '  write n  failed denied', '    denied' },
      group = { 'wrote 1 file, 1 failed', true },
      fold = true,
    }
  )
  t.check(
    'described command shows it',
    only({ call('b', 'bash', { command = 'make', description = 'Build' }), result('b') }).lines,
    {
      '  $ Build',
      '    make',
    }
  )
  t.check(
    'long command shows it',
    only({ call('b', 'bash', { command = 'a\nb' }), result('b', { output = 'o' }) }).lines,
    {
      '  $ a  +1 lines',
      '    a',
      '    b',
      '    o',
    }
  )
  t.check(
    'slow command',
    only({ call('b', 'bash', { command = 'make' }, 1000), result('b', { at = 76000 }) }).lines,
    { '  $ make  1m 15s' }
  )
  t.check(
    'quick command',
    only({ call('b', 'bash', { command = 'make' }, 1000), result('b', { at = 15999 }) }).lines,
    { '  $ make' }
  )
  t.check(
    'fetch counts pages',
    only({ call('f', 'fetch', { urls = { 'https://a', 'https://b' } }), result('f') }).group,
    { 'read 2 web pages', true }
  )
  t.check('invalid args', only({ call('r', 'read', { file = 'a' }), result('r') }).lines, { '  read? {"file":"a"}' })
  t.check('result without call', only({ result('x', { output = 'o' }) }).lines, { '  ? []', '    o' })
  t.check('blank output lines', only({ call('l', 'lookup', {}), result('l', { output = 'a\n\nb' }) }).lines, {
    '  lookup []',
    '    a',
    '',
    '    b',
  })
end)

t.describe('grep locations', function()
  local block = t.layout({ call('g', 'grep', { pattern = 'x' }), result('g', { output = 'a.lua:12:x\nother' }) })[1]
  t.check('targets', block.targets, { { index = 1, count = 2, parse = 'location', col = 4 } })
  t.check('highlights', block.highlights, {
    { index = 1, col = 4, end_col = 9, hl_group = 'OttoPath' },
    { index = 1, col = 10, end_col = 12, hl_group = 'OttoLineNumber' },
  })
end)

t.describe('truncated output', function()
  local lines = {}
  for i = 1, 52 do
    lines[i] = 'l' .. i
  end
  local block =
    t.layout({ call('b', 'bash', { command = 'seq' }), result('b', { output = table.concat(lines, '\n') }) })[1]
  t.check('more line', { #block.lines, block.lines[#block.lines] }, { 52, '    ... 2 more lines' })
  t.check('keeps whole output', block.call.output, table.concat(lines, '\n'))
end)

t.describe('groups', function()
  local events = {
    call('a', 'read', { path = 'a' }),
    result('a'),
    { type = 'error', message = 'oops', at = 0 },
    call('b', 'read', { path = 'b' }),
    result('b'),
    { type = 'turn_end', aborted = false, started = 0, worked = false, at = 0 },
    call('c', 'read', { path = 'c' }),
    result('c'),
  }
  local blocks = shapes(events)
  t.check('error', blocks[2], { kind = 'error', spaced = true, lines = { 'oops' } })
  t.check('restart after other blocks', blocks[3].group, { 'read 1 file', true })
  t.check('nothing done notes nothing', blocks[4], 'turn_end')
  t.check('restart after turns', blocks[5].group, { 'read 1 file', true })
end)

t.describe('turn_end', function()
  local start = 1792602904000
  local ops =
    layout.new():add({ type = 'turn_end', aborted = false, started = start, worked = true, at = start + 65000 })
  t.check('ops', vim.tbl_map(function(op) return op.type end, ops), { 'block', 'turn_end' })
  t.match('note', ops[1].block.lines[1], '^Worked for 1m 5s · done %d%d?:%d%d [ap]%.m$')
  t.check('kind', ops[1].block.kind, 'note')
  local aborted = layout.new():add({ type = 'turn_end', aborted = true, started = start, worked = false, at = start })
  t.match('aborted', aborted[1].block.lines[1], '^Worked for 0s · aborted ')
  local skew = layout.new():add({ type = 'turn_end', aborted = false, started = start + 5, worked = true, at = start })
  t.match('never negative', skew[1].block.lines[1], '^Worked for 0s ')
  local l = layout.new()
  l:add(call('x', 'read', { path = 'a' }))
  l:add({ type = 'turn_end', aborted = false, started = 0, worked = false, at = 0 })
  t.check('forgets calls', l.calls, {})
end)

t.describe('compaction', function()
  local function first(fields)
    fields.type, fields.at = 'compaction', 0
    return shapes({ fields })[1]
  end
  t.check('summary', first({ summary = 'did a\ndid b', before = 150000, after = 20500 }), {
    kind = 'note',
    spaced = true,
    lines = { 'compacted  150k -> 20k tokens', '  did a', '  did b' },
    fold = true,
  })
  t.check(
    'before only',
    first({ before = 99999 }),
    { kind = 'note', spaced = true, lines = { 'compacted  from 99k tokens' } }
  )
  t.check('nothing known', first({}).lines, { 'compacted' })
end)
