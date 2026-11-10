-- pi's messages as the log, as its session files and events have them

local t = ...
local decode = require('otto.providers.pi.decode')

local function text(value) return { { type = 'text', text = value } } end
local function result(id, output, extra)
  local msg = { role = 'toolResult', toolCallId = id, toolName = 'bash', content = text(output), isError = false }
  return vim.tbl_extend('force', msg, extra or {})
end

--- @param messages table[]
--- @return otto.Event[] without times
--- @return otto.StatePatch[]
local function decode_all(messages)
  local log, events, patches = t.log()
  local decoder = decode.new()
  for i, msg in ipairs(messages) do
    decode.add(log, decoder, msg, i * 1000)
  end
  log:end_turn()
  return t.without(events, { 'at', 'started' }), patches
end

t.describe('a turn', function()
  local events, patches = decode_all({
    { role = 'user', content = text('fix it\n'), timestamp = 1 },
    {
      role = 'assistant',
      content = {
        { type = 'thinking', thinking = 'hmm' },
        { type = 'text', text = 'Running.\n' },
        { type = 'toolCall', id = 'c1', name = 'bash', arguments = { command = 'make' } },
        { type = 'toolCall', id = 'c2', name = 'search', arguments = { pattern = 'TODO' } },
      },
      stopReason = 'toolUse',
      usage = { totalTokens = 1200, cost = { total = 0.25 } },
    },
    result('c1', 'a\nb\n\n'),
    result('c2', 'x:1:TODO', { toolName = 'search' }),
    {
      role = 'assistant',
      content = { { type = 'toolCall', id = 'c3', name = 'edit', arguments = { path = 'a.lua', edits = {} } } },
      usage = { totalTokens = 1500, cost = { total = 0.5 } },
    },
    result('c3', 'Successfully replaced text in a.lua.', {
      toolName = 'edit',
      details = { diff = '  1 a\n- 2 b\n+ 2 c\n+ 3 d\n  3 e\n    ...\n 10 j\n 11' },
    }),
    { role = 'assistant', content = text('Done.'), stopReason = 'stop', usage = { totalTokens = 1600 } },
    { role = 'custom', customType = 'note', content = 'ignored' },
  })
  t.check('events', events, {
    { type = 'user', text = 'fix it' },
    { type = 'text', text = 'Running.' },
    { type = 'tool_call', id = 'c1', tool = 'bash', args = { command = 'make' } },
    { type = 'tool_call', id = 'c2', tool = 'grep', args = { pattern = 'TODO' } },
    { type = 'tool_result', id = 'c1', ok = true, output = 'a\nb' },
    { type = 'tool_result', id = 'c2', ok = true, output = 'x:1:TODO' },
    { type = 'tool_call', id = 'c3', tool = 'edit', args = { path = 'a.lua', edits = {} } },
    {
      type = 'tool_result',
      id = 'c3',
      ok = true,
      output = 'Successfully replaced text in a.lua.',
      -- context lines move by the lines changed above them
      diff = {
        { sign = ' ', lnum = 1, text = 'a' },
        { sign = '-', lnum = 2, text = 'b' },
        { sign = '+', lnum = 2, text = 'c' },
        { sign = '+', lnum = 3, text = 'd' },
        { sign = ' ', lnum = 4, text = 'e' },
        { text = '...' },
        { sign = ' ', lnum = 11, text = 'j' },
        { sign = ' ', lnum = 12, text = '' },
      },
    },
    { type = 'text', text = 'Done.' },
    { type = 'turn_end', aborted = false, worked = true },
  })
  t.check('cost adds up', patches, {
    { context_tokens = 1200, cost = 0.25 },
    { context_tokens = 1500, cost = 0.75 },
    { context_tokens = 1600, cost = 0.75 },
  })
end)

t.describe('exit codes', function()
  local function output(value)
    local events = decode_all({ result('c', value, { isError = true }) })
    return { events[1].ok, events[1].output, events[1].exit_code }
  end
  t.check('code', output('out\n\nCommand exited with code 2'), { false, 'out', 2 })
  t.check('no output', output('(no output)\n\nCommand exited with code 1'), { false, '', 1 })
  t.check(
    'line after',
    output('x\n\nCommand exited with code 3\n\n[Output truncated: 20 lines]'),
    { false, 'x\n\n[Output truncated: 20 lines]', 3 }
  )
  t.check(
    'only the line after',
    output('(no output)\nCommand exited with code 4\n[Truncated]'),
    { false, '[Truncated]', 4 }
  )
  t.check('other errors', output('Error: no such file\n'), { false, 'Error: no such file', nil })
end)

t.describe('tools of extensions', function()
  local events = decode_all({
    {
      role = 'assistant',
      content = {
        { type = 'toolCall', id = 's', name = 'kagi_search', arguments = { query = 'nvim' } },
        { type = 'toolCall', id = 'f', name = 'web_fetch', arguments = { urls = { 'https://a' } } },
        { type = 'toolCall', id = 'k', name = 'kagi_extract', arguments = { urls = { 'https://b' } } },
      },
    },
    result('s', '<b>Neovim</b> https://neovim.io', {
      details = { results = { { title = 'Neovim', url = 'https://neovim.io' }, { url = 'https://x' } } },
    }),
    result('f', 'page', { details = { results = { { snippet = 'no url' } } } }),
  })
  t.check('names', vim.tbl_map(function(e) return e.tool end, { events[1], events[2], events[3] }), {
    'web_search',
    'fetch',
    'fetch',
  })
  t.check('results from details', events[4].output, 'Neovim  https://neovim.io\nhttps://x')
  t.check('details without urls', events[5].output, 'page')
end)

t.describe('errors and aborts', function()
  local events = decode_all({
    { role = 'user', content = text('go') },
    { role = 'assistant', content = {}, stopReason = 'error', errorMessage = '429 rate limited' },
    { role = 'user', content = text('again') },
    { role = 'assistant', content = text('partial'), stopReason = 'aborted' },
    { role = 'user', content = text('once more') },
    { role = 'assistant', content = {}, stopReason = 'error', errorMessage = 'The operation was aborted.' },
  })
  t.check('events', events, {
    { type = 'user', text = 'go' },
    { type = 'error', message = '429 rate limited' },
    { type = 'turn_end', aborted = false, worked = true },
    { type = 'user', text = 'again' },
    { type = 'text', text = 'partial' },
    { type = 'turn_end', aborted = true, worked = true },
    { type = 'user', text = 'once more' },
    { type = 'error', message = 'The operation was aborted.' },
    { type = 'turn_end', aborted = true, worked = true },
  })
end)

t.describe('times', function()
  local log, events = t.log()
  decode.add(log, decode.new(), { role = 'user', content = text('hi') }, 42)
  t.check('given', events[1].at, 42)
end)
