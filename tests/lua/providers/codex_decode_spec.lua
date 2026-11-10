-- Codex's items as the log, as its app-server has them

local t = ...
local decode = require('otto.providers.codex.decode')

local function shell(id, command, actions, extra)
  local item = {
    type = 'commandExecution',
    id = id,
    command = command,
    cwd = '/w',
    commandActions = actions,
    status = 'completed',
    aggregatedOutput = '',
    exitCode = 0,
    durationMs = 0,
  }
  return vim.tbl_extend('force', item, extra or {})
end

local function call_of(item)
  local calls = decode.calls(item)
  return { calls[1].tool, calls[1].args }
end

t.describe('commands', function()
  t.check(
    'read',
    call_of(
      shell(
        'c',
        "/bin/bash -lc 'cat a.txt'",
        { { type = 'read', command = 'cat a.txt', name = 'a.txt', path = '/w/a.txt' } }
      )
    ),
    {
      'read',
      { path = '/w/a.txt' },
    }
  )
  t.check(
    'read a range',
    call_of(shell('c', 'x', { { type = 'read', command = "sed -n '10,20p' a.lua", path = 'a.lua' } })),
    {
      'read',
      { path = 'a.lua', offset = 10 },
    }
  )
  t.check(
    'tail is a command',
    call_of(
      shell('c', "bash -lc 'tail -n 5 a.lua'", { { type = 'read', command = 'tail -n 5 a.lua', path = 'a.lua' } })
    ),
    {
      'bash',
      { command = 'tail -n 5 a.lua' },
    }
  )
  t.check('ls', call_of(shell('c', 'x', { { type = 'listFiles', command = 'ls' } })), { 'ls', { path = '.' } })
  t.check(
    'search',
    call_of(shell('c', 'x', { { type = 'search', command = 'rg foo lua', query = 'foo', path = 'lua' } })),
    {
      'grep',
      { pattern = 'foo', path = 'lua' },
    }
  )
  t.check('search without query', call_of(shell('c', 'x', { { type = 'search', command = 'rg --files' } })), {
    'grep',
    { pattern = 'rg --files' },
  })
  local two = { { type = 'read', command = 'cat a', path = 'a' }, { type = 'read', command = 'cat b', path = 'b' } }
  t.check(
    'two actions',
    call_of(shell('c', "bash -lc 'cat a && cat b'", two)),
    { 'bash', { command = 'cat a && cat b' } }
  )
  t.check(
    'quotes',
    call_of(shell('c', [[/bin/zsh -lc 'echo '"'"'hi'"'"'']], {})),
    { 'bash', { command = "echo 'hi'" } }
  )
  t.check('double quotes', call_of(shell('c', 'bash -lc "ls -la"', {})), { 'bash', { command = 'ls -la' } })
  t.check('unquoted', call_of(shell('c', 'bash -lc ls', {})), { 'bash', { command = 'ls' } })
  t.check('unwrapped', call_of(shell('c', 'make test', nil)), { 'bash', { command = 'make test' } })
end)

t.describe('items', function()
  local log, events = t.log()
  local decoder = decode.new()
  local function add(item, announced) decode.add(log, decoder, item, announced or {}, 1000) end
  add({ type = 'userMessage', id = 'u', content = { { type = 'text', text = ' fix it \n', text_elements = {} } } })
  add({ type = 'reasoning', id = 'r', summary = {}, content = {} })
  add({ type = 'agentMessage', id = 'm1', text = 'Checking.', phase = 'commentary' })
  add({ type = 'agentMessage', id = 'm2', text = '  ' })
  add(shell('c1', "bash -lc 'make'", {}, { aggregatedOutput = 'ok\n\n', durationMs = 2500 }))
  add(shell('c2', "bash -lc 'make lint'", {}, { status = 'failed', aggregatedOutput = 'bad\n', exitCode = 1 }))
  local declined = shell('c3', "bash -lc 'rm -rf /'", {}, { status = 'declined' })
  declined.aggregatedOutput, declined.exitCode = nil, nil
  add(declined)
  local announced = { c4 = true }
  add(shell('c4', "bash -lc 'ls'", {}), announced)
  add({ type = 'webSearch', id = 'w', query = 'neovim' })
  add({
    type = 'mcpToolCall',
    id = 'm',
    server = 'docs',
    tool = 'lookup',
    arguments = { q = 'x' },
    result = { content = { { type = 'text', text = 'found\n' } } },
  })
  local failed = { type = 'mcpToolCall', id = 'e', server = 'docs', tool = 'lookup', arguments = {} }
  add(vim.tbl_extend('force', failed, { error = { message = 'boom' } }))
  add({ type = 'agentMessage', id = 'm3', text = 'Done.', phase = 'final_answer' })
  log:end_turn()
  t.check('events', t.without(events, { 'at', 'started' }), {
    { type = 'user', text = 'fix it' },
    { type = 'text', text = 'Checking.' },
    { type = 'tool_call', id = 'c1', tool = 'bash', args = { command = 'make' } },
    { type = 'tool_result', id = 'c1', ok = true, output = 'ok', exit_code = 0 },
    { type = 'tool_call', id = 'c2', tool = 'bash', args = { command = 'make lint' } },
    { type = 'tool_result', id = 'c2', ok = false, output = 'bad', exit_code = 1 },
    { type = 'tool_call', id = 'c3', tool = 'bash', args = { command = 'rm -rf /' } },
    { type = 'tool_result', id = 'c3', ok = false, output = '' },
    -- announced when it started
    { type = 'tool_result', id = 'c4', ok = true, output = '', exit_code = 0 },
    { type = 'tool_call', id = 'w', tool = 'web_search', args = { query = 'neovim' } },
    { type = 'tool_result', id = 'w', ok = true, output = '' },
    { type = 'tool_call', id = 'm', tool = 'lookup', args = { q = 'x' } },
    { type = 'tool_result', id = 'm', ok = true, output = 'found' },
    { type = 'tool_call', id = 'e', tool = 'lookup', args = {} },
    { type = 'tool_result', id = 'e', ok = false, output = 'boom' },
    { type = 'text', text = 'Done.' },
    { type = 'turn_end', aborted = false, worked = true },
  })
  t.check('forgets announced', announced, {})
  t.check('items take the turn time', events[1].at, 1000)
  t.check('commands end after their duration', { events[3].at, events[4].at }, { 1000, 3500 })
end)

t.describe('file changes', function()
  local item = {
    type = 'fileChange',
    id = 'f',
    status = 'completed',
    changes = {
      {
        path = 'a.lua',
        kind = { type = 'update' },
        diff = '@@ -1,4 +1,4 @@\n a\n-b\n+c\n\n d\n@@ -10 +10,2 @@\n j\n+k\n\\ No newline at end of file\n',
      },
      { path = 'new.lua', kind = { type = 'add' }, diff = 'x\ny\n' },
      { path = 'old.lua', kind = { type = 'delete' }, diff = 'gone\nline\n' },
    },
  }
  local log, events = t.log()
  decode.add(log, decode.new(), item, {}, 0)
  t.check('events', t.without(events, { 'at' }), {
    { type = 'tool_call', id = 'f:1', tool = 'edit', args = { path = 'a.lua' } },
    { type = 'tool_call', id = 'f:2', tool = 'write', args = { path = 'new.lua', content = 'x\ny\n' } },
    { type = 'tool_call', id = 'f:3', tool = 'edit', args = { path = 'old.lua' } },
    {
      type = 'tool_result',
      id = 'f:1',
      ok = true,
      output = '',
      diff = {
        { sign = ' ', lnum = 1, text = 'a' },
        { sign = '-', lnum = 2, text = 'b' },
        { sign = '+', lnum = 2, text = 'c' },
        -- which lost its space
        { sign = ' ', lnum = 3, text = '' },
        { sign = ' ', lnum = 4, text = 'd' },
        { sign = ' ', lnum = 10, text = 'j' },
        { sign = '+', lnum = 11, text = 'k' },
      },
    },
    { type = 'tool_result', id = 'f:2', ok = true, output = '' },
    {
      type = 'tool_result',
      id = 'f:3',
      ok = true,
      output = '',
      diff = { { sign = '-', lnum = 1, text = 'gone' }, { sign = '-', lnum = 2, text = 'line' } },
    },
  })

  local failed = vim.deepcopy(item)
  failed.status = 'failed'
  failed.changes = { failed.changes[1] }
  local flog, fevents = t.log()
  decode.add(flog, decode.new(), failed, {}, 0)
  t.check('failed', fevents[2], { type = 'tool_result', id = 'f:1', ok = false, output = '', at = 0 })
end)

t.describe('subagents', function()
  local log, events = t.log()
  local decoder = decode.new()
  local thread = '019a0000-0000-7000-8000-0000deadbeef'
  local function add(item)
    item.type = 'subAgentActivity'
    decode.add(log, decoder, item, {}, 5)
  end
  add({ id = 's1', kind = 'started', agentThreadId = thread, agentPath = '/root/reviewer', model = 'gpt-5' })
  add({ id = 's2', kind = 'interacted', agentThreadId = thread })
  add({ id = 's3', kind = 'completed', agentThreadId = thread })
  add({ id = 's4', kind = 'started', agentThreadId = 'other-0000cafe' })
  add({ id = 's5', kind = 'errored', agentThreadId = 'other-0000cafe' })
  add({ id = 's6', kind = 'completed', agentThreadId = 'unknown' })
  local args = { description = 'reviewer', type = 'gpt-5', background = true }
  local unnamed = { description = '0000cafe', background = true }
  t.check('events', t.without(events, { 'at' }), {
    { type = 'tool_call', id = 's1', tool = 'agent', args = args },
    { type = 'tool_result', id = 's1', ok = true, output = '' },
    { type = 'tool_call', id = 's3', tool = 'agent', args = args },
    { type = 'tool_result', id = 's3', ok = true, output = '' },
    { type = 'tool_call', id = 's4', tool = 'agent', args = unnamed },
    { type = 'tool_result', id = 's4', ok = true, output = '' },
    { type = 'tool_call', id = 's5', tool = 'agent', args = unnamed },
    { type = 'tool_result', id = 's5', ok = false, output = '' },
  })
end)

t.describe('compaction', function()
  local log, events = t.log()
  decode.add(log, decode.new(), { type = 'contextCompaction', id = 'x' }, {}, 7)
  t.check('without a summary', events, { { type = 'compaction', at = 7 } })
  t.check('outside turns', log.in_turn, false)
end)

t.describe('times', function()
  t.check('completed', { decode.times({ startedAt = 100, completedAt = 105 }) }, { 100000, 105000 })
  t.check('duration', { decode.times({ startedAt = 100, durationMs = 2500 }) }, { 100000, 102500 })
  t.check('none', { decode.times({}) }, {})
end)
