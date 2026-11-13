-- render/tools.lua: how tools look

local t = ...
local tools = require('otto.render.tools')
local util = require('otto.util')

local function header(tool, args) return util.join(tools.header(tool, args)) end

t.describe('valid', function()
  t.check('read', tools.valid('read', { path = 'a.lua', offset = 3 }), true)
  t.check('read without path', tools.valid('read', {}), false)
  t.check('offset as string', tools.valid('read', { path = 'a', offset = '3' }), false)
  t.check('paths', tools.valid('ls', { path = { 'a', 'b' } }), true)
  t.check('paths of numbers', tools.valid('ls', { path = { 'a', 1 } }), false)
  t.check('fetch', tools.valid('fetch', { urls = { 'https://a' } }), true)
  t.check('fetch without urls', tools.valid('fetch', { urls = {} }), false)
  t.check('write without content', tools.valid('write', { path = 'a' }), false)
  t.check('unknown tool', tools.valid('lookup', { anything = 1 }), true)
  t.check('not a table', tools.valid('bash', 'ls'), false)
end)

t.describe('display_call', function()
  t.check('valid', tools.display_call('bash', { command = 'ls' }), { tool = 'bash', args = { command = 'ls' } })
  t.check(
    'invalid shows what was sent',
    tools.display_call('read', { file = 'a' }),
    { tool = 'read?', args = { description = '{"file":"a"}' } }
  )
  t.check('nil args', tools.display_call('lookup'), { tool = 'lookup', args = {} })
end)

t.describe('header', function()
  t.check('bash', header('bash', { command = '  make test\n' }), '$ make test')
  t.check('bash lines', header('bash', { command = 'cd a\nmake\nls' }), '$ cd a  +2 lines')
  t.check('bash description', header('bash', { command = 'make', description = 'Build\nit' }), '$ Build')
  t.check('agent', header('agent', { description = 'Review', type = 'general' }), 'agent Review  general')
  t.check(
    'message',
    header('message', { description = 'Ask\nit', to = 'research', message = 'm' }),
    'message Ask  to research'
  )
  t.check('web', header('web_search', { query = 'neovim' }), 'web neovim')
  t.check('fetch', header('fetch', { urls = { 'https://a', 'https://b', 'https://c' } }), 'fetch https://a +2')
  t.check('grep', header('grep', { pattern = 'foo', path = 'lua' }), 'grep foo  in lua')
  t.check('find', header('find', { pattern = '*.lua' }), 'find *.lua')
  t.check('read range', header('read', { path = 'a.lua', offset = 10, limit = 5 }), 'read a.lua:10-14')
  t.check('read offset', header('read', { path = 'a.lua', offset = 10 }), 'read a.lua:10')
  t.check('read limit', header('read', { path = 'a.lua', limit = 3 }), 'read a.lua:1-3')
  t.check('ls paths', header('ls', { path = { 'a', 'b' } }), 'ls a b')
  t.check('other', header('lookup', { q = 'x' }), 'lookup {"q":"x"}')
  t.check('invalid', header('read?', { description = '{"file":"a"}' }), 'read? {"file":"a"}')
  t.check('highlights', tools.header('grep', { pattern = 'x', path = 'l' }), {
    { 'grep', 'OttoToolName' },
    { ' x', 'OttoToolArg' },
    { '  in l', 'OttoToolDetail' },
  })
end)

t.describe('summary', function()
  local function text(list, failed) return util.join(tools.summary(list, failed or 0)) end
  t.check('one', text({ 'read' }), 'read 1 file')
  t.check('plural', text({ 'read', 'read' }), 'read 2 files')
  t.check('es after h', text({ 'web_search', 'web_search' }), 'ran 2 web searches')
  t.check('grep and find count together', text({ 'grep', 'find' }), 'searched 2 patterns')
  t.check('in order', text({ 'bash', 'read', 'bash', 'lookup' }), 'ran 2 commands, read 1 file, called 1 tool')
  t.check('others', text({ 'a', 'b' }), 'called 2 tools')
  t.check('failed', tools.summary({ 'bash', 'bash' }, 1), {
    { 'ran 2 commands, ', 'OttoToolSummary' },
    { '1 failed', 'OttoToolFailed' },
  })
end)

t.describe('diffs', function()
  local diff = {
    { sign = ' ', lnum = 9, text = 'a' },
    { sign = '-', lnum = 10, text = 'b' },
    { sign = '+', lnum = 10, text = 'c' },
    { text = '...' },
    { sign = '+', lnum = 120, text = 'd' },
  }
  t.check('counts', { tools.diff_counts(diff) }, { 2, 1 })
  local lines, first = tools.format_diff(diff)
  t.check('aligned', lines, { '   9 a', '- 10 b', '+ 10 c', '     ...', '+120 d' })
  t.check('first changed', first, 10)
  t.check('no change', { tools.format_diff({ { sign = ' ', lnum = 1, text = 'x' } }) }, { { ' 1 x' } })
  t.check(
    'diff_header',
    util.join(tools.diff_header({ tool = 'edit', args = { path = 'a.lua' } }, diff)),
    'edit a.lua  +2 -1'
  )
end)

t.describe('output_section', function()
  local read = tools.output_section('read', { path = 'a.lua', offset = 4 }, 'x\ny')
  t.check('read', read, { lines = { 'x', 'y' }, filetype = 'lua', truncated = 0, path = 'a.lua', lnum = 4 })
  t.check('empty', tools.output_section('ls', { path = '.' }, '').lines, {})
  t.check('agent is markdown', tools.output_section('agent', { description = 'a' }, '# x').filetype, 'markdown')
  t.check('grep has locations', tools.output_section('grep', { pattern = 'x' }, 'a:1:x').locations, true)

  local function bash(command, text) return tools.output_section('bash', { command = command }, text or 'out') end
  t.check('cat', { bash('cat lua/a.lua').path, bash('cat lua/a.lua').filetype, bash('cat lua/a.lua').lnum }, {
    'lua/a.lua',
    'lua',
    1,
  })
  t.check('quoted', bash('cat "a.py"').path, 'a.py')
  t.check('sed range', { bash("sed -n '10,20p' a.lua").path, bash("sed -n '10,20p' a.lua").lnum }, { 'a.lua', 10 })
  t.check('tail has no start', { bash('tail -n 5 a.lua').path, bash('tail -n 5 a.lua').lnum }, { 'a.lua', nil })
  t.check('pipe is not a read', bash('cat a.lua | head').path, nil)
  t.check('rg', bash('rg foo').locations, true)
  t.check('git grep', bash('git grep foo').locations, true)
  t.check('git diff', bash('git diff HEAD').filetype, 'diff')
  t.check('diff', bash('diff a b').filetype, 'diff')
  t.check('json', bash('curl x', '{"a": 1}').filetype, 'json')
  t.check('not json', bash('echo', '[x').filetype, nil)
  t.check('plain', bash('make').locations, false)

  local many = {}
  for i = 1, 53 do
    many[i] = tostring(i)
  end
  local section = bash('seq 53', table.concat(many, '\n'))
  t.check('truncated', { #section.lines, section.lines[50], section.truncated }, { 50, '50', 3 })
end)

t.describe('locations', function()
  t.check('match', { tools.location('lua/a.lua:12:x') }, { 'lua/a.lua', '12' })
  t.check('context', { tools.location('a.lua-3-y') }, { 'a.lua', '3' })
  t.check('none', { tools.location('just text') }, {})
  t.check('mixed separators', { tools.location('a.lua:3-y') }, {})
  t.check('list', tools.locations({ 'a:1:x', 'no', 'b:20:y' }), {
    { index = 1, path = 'a', lnum = 1, width = 1 },
    { index = 3, path = 'b', lnum = 20, width = 2 },
  })
end)

t.describe('results', function()
  local section, written = tools.written({ path = 'a.lua', content = 'x\ny\n' })
  t.check('written', { section.lines, section.path, util.join(written) }, { { 'x', 'y' }, 'a.lua', 'write a.lua  +2' })
  local make = { tool = 'bash', args = { command = 'make' } }
  local function result_header(call, result, seconds, detail)
    return util.join(tools.result_header(call, result, seconds, detail))
  end
  t.check('exit codes of commands', result_header(make, { ok = false, exit_code = 2 }, 1), '$ make  exit 2')
  t.check('how long slow commands ran', result_header(make, { ok = true }, 20), '$ make  20s')
  local read = { tool = 'read', args = { path = 'a' } }
  t.check('why others failed', result_header(read, { ok = false }, 1, 'no such file'), 'read a  failed no such file')
  local described = { tool = 'bash', args = { command = 'make\ntest', description = 'build' } }
  local sections = tools.result_sections(described, tools.section({ 'ok' }))
  t.check('the command above the output', vim.tbl_map(function(s) return s.lines end, sections), {
    { 'make', 'test' },
    { 'ok' },
  })
  local message = { tool = 'message', args = { to = 'r', message = 'hi\nthere' } }
  local sent = tools.result_sections(message, tools.section({ '{"success":true}' }))
  t.check('what a message sent', { sent[1].lines, sent[1].filetype, #sent }, { { 'hi', 'there' }, 'markdown', 1 })
end)
