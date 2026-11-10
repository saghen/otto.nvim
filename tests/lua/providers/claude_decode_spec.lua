-- Claude Code's entries as the log, as its session files have them

local t = ...
local decode = require('otto.providers.claude.decode')
local event = require('otto.event')

local base = event.parse_iso('2026-10-21T17:15:00.000Z')
local function at(s) return base + s * 1000 end
local function ts(s) return ('2026-10-21T17:%02d:%02d.000Z'):format(15 + math.floor(s / 60), s % 60) end

local function user(uuid, s, content, extra)
  local entry = { type = 'user', uuid = uuid, timestamp = ts(s), message = { role = 'user', content = content } }
  return vim.tbl_extend('force', entry, extra or {})
end
local function assistant(uuid, s, content, extra)
  local message = {
    model = 'claude-opus-4-5',
    role = 'assistant',
    content = content,
    usage = { input_tokens = 10, cache_read_input_tokens = 1000, cache_creation_input_tokens = 5, output_tokens = 3 },
  }
  return vim.tbl_extend('force', { type = 'assistant', uuid = uuid, timestamp = ts(s), message = message }, extra or {})
end
local function tool_use(uuid, s, id, name, input)
  return assistant(uuid, s, { { type = 'tool_use', id = id, name = name, input = input } })
end
local function tool_result(uuid, s, id, content, details, is_error)
  local block = { type = 'tool_result', tool_use_id = id, content = content, is_error = is_error }
  return user(uuid, s, { block }, { toolUseResult = details })
end

--- @param entries table[]
--- @return otto.Event[] events
--- @return otto.StatePatch[] patches
--- @return otto.ClaudeDecoder decoder
local function decode_all(entries)
  local log, events, patches = t.log()
  local decoder = decode.new()
  for _, entry in ipairs(entries) do
    decode.add(log, decoder, entry)
  end
  log:end_turn()
  return events, patches, decoder
end

t.describe('is_tagged', function()
  t.check('command', decode.is_tagged('<command-name>/clear</command-name>'), true)
  t.check('with attributes', decode.is_tagged('<system-reminder id="1">x'), true)
  t.check('task notification', decode.is_tagged('<task-notification>\n<task-id>'), true)
  t.check('html of the user', decode.is_tagged('<div>hi</div>'), false)
  t.check('plain', decode.is_tagged('fix <command-name>'), false)
end)

t.describe('a turn with tools', function()
  local events, patches, decoder = decode_all({
    { type = 'file-history-snapshot', messageId = 'm', snapshot = {} },
    user('u1', 0, 'fix the failing test\n'),
    assistant('a1', 1, { { type = 'thinking', thinking = 'hmm', signature = 'x' } }),
    assistant('a2', 2, { { type = 'text', text = 'Let me run the tests.\n\n' } }),
    tool_use('a3', 2, 't1', 'Bash', { command = 'make test', description = 'Run tests' }),
    tool_result('u2', 4, 't1', 'Exit code 2\nFAIL spec\n\n', 'Error: Exit code 2\nFAIL spec', true),
    tool_use('a4', 5, 't2', 'Read', { file_path = '/w/a.lua', offset = 2, limit = 2 }),
    tool_result('u3', 6, 't2', '     2\tb\n     3\tc', {
      type = 'text',
      file = { filePath = '/w/a.lua', content = 'b\nc\n', numLines = 2, startLine = 2, totalLines = 9 },
    }),
    tool_use('a5', 7, 't3', 'Edit', { file_path = '/w/a.lua', old_string = 'b', new_string = 'B' }),
    tool_result('u4', 8, 't3', 'The file /w/a.lua has been updated.\n', {
      filePath = '/w/a.lua',
      structuredPatch = {
        { oldStart = 1, oldLines = 3, newStart = 1, newLines = 3, lines = { ' a', '-b', '+B', ' c' } },
        {
          oldStart = 8,
          oldLines = 1,
          newStart = 8,
          newLines = 2,
          lines = { ' h', '+i', '\\ No newline at end of file' },
        },
      },
    }),
    tool_use('a6', 9, 't4', 'Write', { file_path = '/w/new.lua', content = 'x\n' }),
    tool_result('u5', 10, 't4', 'File created successfully at: /w/new.lua', {
      type = 'create',
      filePath = '/w/new.lua',
      content = 'x\n',
      structuredPatch = {},
    }),
    tool_use('a7', 11, 't5', 'Grep', { pattern = 'TODO', path = 'lua', output_mode = 'content' }),
    tool_result('u6', 12, 't5', { { type = 'text', text = 'lua/a.lua:3:-- TODO' } }),
    tool_use('a8', 13, 't6', 'mcp__docs__lookup', { q = 'x' }),
    tool_result('u7', 14, 't6', 'found it'),
    assistant('a9', 15, { { type = 'text', text = 'Fixed.' } }),
    { type = 'system', subtype = 'turn_duration', durationMs = 15000, uuid = 's1', timestamp = ts(15) },
  })
  t.check('events', events, {
    { type = 'user', text = 'fix the failing test', at = at(0) },
    { type = 'text', text = 'Let me run the tests.', at = at(2) },
    {
      type = 'tool_call',
      id = 't1',
      tool = 'bash',
      args = { command = 'make test', description = 'Run tests' },
      at = at(2),
    },
    { type = 'tool_result', id = 't1', ok = false, output = 'FAIL spec', exit_code = 2, at = at(4) },
    { type = 'tool_call', id = 't2', tool = 'read', args = { path = '/w/a.lua', offset = 2, limit = 2 }, at = at(5) },
    -- the file's lines, rather than numbered ones
    { type = 'tool_result', id = 't2', ok = true, output = 'b\nc', at = at(6) },
    { type = 'tool_call', id = 't3', tool = 'edit', args = { path = '/w/a.lua' }, at = at(7) },
    {
      type = 'tool_result',
      id = 't3',
      ok = true,
      output = 'The file /w/a.lua has been updated.',
      diff = {
        { sign = ' ', lnum = 1, text = 'a' },
        { sign = '-', lnum = 2, text = 'b' },
        { sign = '+', lnum = 2, text = 'B' },
        { sign = ' ', lnum = 3, text = 'c' },
        { sign = ' ', lnum = 8, text = 'h' },
        { sign = '+', lnum = 9, text = 'i' },
      },
      at = at(8),
    },
    { type = 'tool_call', id = 't4', tool = 'write', args = { path = '/w/new.lua', content = 'x\n' }, at = at(9) },
    -- new files have an empty patch
    { type = 'tool_result', id = 't4', ok = true, output = 'File created successfully at: /w/new.lua', at = at(10) },
    { type = 'tool_call', id = 't5', tool = 'grep', args = { pattern = 'TODO', path = 'lua' }, at = at(11) },
    { type = 'tool_result', id = 't5', ok = true, output = 'lua/a.lua:3:-- TODO', at = at(12) },
    { type = 'tool_call', id = 't6', tool = 'mcp__docs__lookup', args = { q = 'x' }, at = at(13) },
    { type = 'tool_result', id = 't6', ok = true, output = 'found it', at = at(14) },
    { type = 'text', text = 'Fixed.', at = at(15) },
    { type = 'turn_end', aborted = false, started = at(0), worked = true, at = at(15) },
  })
  t.check('model once, and context', patches[1], { model = 'claude-opus-4-5' })
  t.check('context tokens', patches[2], { context_tokens = 1015 })
  t.check('patches', #patches, 1 + 9)
  t.check('prompts', decoder.prompts, { { uuid = 'u1', text = 'fix the failing test' } })
  t.check('last', decoder.last, 's1')
end)

t.describe('tools', function()
  local function call(name, input)
    local events = decode_all({ user('u', 0, 'go'), tool_use('a', 1, 't', name, input) })
    return { events[2].tool, events[2].args }
  end
  t.check('MultiEdit', call('MultiEdit', { file_path = 'a', edits = {} }), { 'edit', { path = 'a' } })
  t.check('Glob', call('Glob', { pattern = '*.lua', path = 'lua' }), { 'find', { pattern = '*.lua', path = 'lua' } })
  t.check('WebSearch', call('WebSearch', { query = 'nvim' }), { 'web_search', { query = 'nvim' } })
  t.check('WebFetch', call('WebFetch', { url = 'https://a', prompt = 'p' }), { 'fetch', { urls = { 'https://a' } } })
  t.check('Task', call('Task', { description = 'd', prompt = 'p', subagent_type = 'Explore' }), {
    'agent',
    { description = 'd', prompt = 'p', type = 'Explore' },
  })
  t.check('background Bash', call('Bash', { command = 'srv', run_in_background = true }), {
    'bash',
    { command = 'srv', background = true },
  })
end)

t.describe('skipped and tagged', function()
  local events = decode_all({
    user('m', 0, '<local-command-caveat>Caveat</local-command-caveat>', { isMeta = true }),
    user('u1', 1, 'hello'),
    assistant('side', 2, { { type = 'text', text = 'subagent' } }, { isSidechain = true }),
    assistant('sub', 2, { { type = 'text', text = 'streamed subagent' } }, { parent_tool_use_id = 'x' }),
    assistant('a1', 3, { { type = 'text', text = 'hi' } }),
    -- a local command ends the turn like a prompt, and shows nothing
    user('c', 4, '<command-name>/model</command-name>\n<command-args></command-args>'),
    user('o', 4, '<local-command-stdout>Set model</local-command-stdout>'),
    user('k', 5, '/compact keep the tests'),
    user('h', 6, { { type = 'text', text = '<b>bold</b> is HTML' }, { type = 'image', source = {} } }),
    assistant('e', 7, { { type = 'text', text = '   ' } }),
  })
  t.check('events', t.without(events, { 'at', 'started' }), {
    { type = 'user', text = 'hello' },
    { type = 'text', text = 'hi' },
    { type = 'turn_end', aborted = false, worked = true },
    { type = 'user', text = '<b>bold</b> is HTML' },
    -- blank answers do nothing
    { type = 'turn_end', aborted = false, worked = false },
  })
end)

t.describe('titles', function()
  local _, patches = decode_all({
    { type = 'ai-title', aiTitle = 'Fix tests', sessionId = 's' },
    { type = 'custom-title', customTitle = 'Mine', sessionId = 's' },
    { type = 'ai-title', aiTitle = 'Later', sessionId = 's' },
  })
  t.check('custom wins', patches, { { name = 'Fix tests' }, { name = 'Mine' } })
end)

t.describe('compaction', function()
  local events, patches = decode_all({
    {
      type = 'system',
      subtype = 'compact_boundary',
      uuid = 'b',
      timestamp = ts(0),
      compactMetadata = { trigger = 'manual', preTokens = 150000, postTokens = 20000 },
    },
    user('s', 1, 'This session is being continued.\nSummary.', { isCompactSummary = true }),
  })
  t.check('events', events, {
    {
      type = 'compaction',
      summary = 'This session is being continued.\nSummary.',
      before = 150000,
      after = 20000,
      at = at(1),
    },
  })
  t.check('context', patches, { { context_tokens = 20000 } })
  -- the stream's keys
  local stream =
    decode_all({ { type = 'system', subtype = 'compact_boundary', compact_metadata = { pre_tokens = 9 } } })
  t.check('stream', stream, {})
end)

t.describe('errors and aborts', function()
  local events = decode_all({
    user('u1', 0, 'go'),
    assistant('e1', 1, { { type = 'text', text = 'API Error: 529 overloaded\n' } }, { isApiErrorMessage = true }),
    user('u2', 2, 'again'),
    tool_use('a1', 3, 't1', 'Bash', { command = 'sleep 99' }),
    tool_result('u3', 4, 't1', '[Request interrupted by user for tool use]', nil, true),
    user('u4', 4, { { type = 'text', text = '[Request interrupted by user for tool use]' } }),
    user('u5', 5, 'next'),
    -- which Claude Code adds once a killed session resumes
    assistant('s1', 6, { { type = 'text', text = 'No response requested.' } }, {
      message = { model = '<synthetic>', role = 'assistant', content = { { type = 'text', text = 'No.' } } },
    }),
  })
  t.check('events', events, {
    { type = 'user', text = 'go', at = at(0) },
    { type = 'error', message = 'API Error: 529 overloaded', at = at(1) },
    { type = 'turn_end', aborted = false, started = at(0), worked = true, at = at(1) },
    { type = 'user', text = 'again', at = at(2) },
    { type = 'tool_call', id = 't1', tool = 'bash', args = { command = 'sleep 99' }, at = at(3) },
    { type = 'tool_result', id = 't1', ok = false, output = '[Request interrupted by user for tool use]', at = at(4) },
    { type = 'turn_end', aborted = true, started = at(2), worked = true, at = at(4) },
    { type = 'user', text = 'next', at = at(5) },
    { type = 'turn_end', aborted = true, started = at(5), worked = false, at = at(5) },
  })
end)

t.describe('queued prompts', function()
  local events, _, decoder = decode_all({
    user('u1', 0, 'start'),
    tool_use('a1', 1, 't1', 'Read', { file_path = 'a' }),
    {
      type = 'attachment',
      uuid = 'q1',
      parentUuid = 'a1',
      timestamp = ts(2),
      attachment = { type = 'queued_command', prompt = ' also docs ', commandMode = 'prompt' },
    },
    {
      type = 'attachment',
      uuid = 'q2',
      timestamp = ts(2),
      attachment = { type = 'queued_command', prompt = '<agent-message>hi</agent-message>', commandMode = 'prompt' },
    },
    tool_result('u2', 3, 't1', 'x'),
  })
  t.check('steers', t.without(events, { 'at', 'started' }), {
    { type = 'user', text = 'start' },
    { type = 'tool_call', id = 't1', tool = 'read', args = { path = 'a' } },
    { type = 'user', text = 'also docs' },
    { type = 'tool_result', id = 't1', ok = true, output = 'x' },
    { type = 'turn_end', aborted = false, worked = true },
  })
  t.check('prompts and their parents', decoder.prompts, {
    { uuid = 'u1', text = 'start' },
    { uuid = 'q1', parent = 'a1', text = 'also docs' },
  })
end)

t.describe('started prompt', function()
  local log, events = t.log()
  local decoder = decode.new()
  decode.add(log, decoder, user('u1', 0, 'one'))
  decode.add_started_prompt(log, decoder, 'u2', ' two ')
  t.check('event', events[#events].text, 'two')
  t.check('follows the last entry', decoder.prompts[2], { uuid = 'u2', parent = 'u1', text = 'two' })
  t.check('last', decoder.last, 'u2')
end)

t.describe('subagents and the background', function()
  local output = vim.fn.tempname()
  vim.fn.writefile({ 'listening', 'crash', '[exited with code 1]', '' }, output)
  local notification = table.concat({
    '<task-notification>',
    '<task-id>c3d4</task-id>',
    '<status>completed</status>',
    '<summary>Agent "Audit" completed</summary>',
    '<result>raw result</result>',
    '</task-notification>',
  }, '\n')
  local entries = {
    user('u1', 0, 'review'),
    tool_use('a1', 1, 't1', 'Task', { description = 'Review', prompt = 'look', subagent_type = 'general-purpose' }),
    tool_result('u2', 2, 't1', {
      { type = 'text', text = 'Looks good.' },
      { type = 'text', text = "agentId: a1b2 (for resuming to continue this agent's work if needed)" },
    }, { status = 'completed', agentId = 'a1b2' }),
    tool_use('a2', 3, 't2', 'Agent', { description = 'Audit', prompt = 'p', run_in_background = true }),
    tool_result('u3', 4, 't2', {
      { type = 'text', text = 'Async agent launched successfully.\nagentId: c3d4 (use it)' },
    }, { isAsync = true, status = 'async_launched', agentId = 'c3d4' }),
    tool_use('a3', 5, 't3', 'Bash', { command = 'npm run dev', run_in_background = true }),
    tool_result('u4', 6, 't3', 'Command running in background with ID: b1. Output is being written to: ' .. output),
    assistant('a4', 7, { { type = 'text', text = 'Started both.' } }),
    -- the report, before the end
    {
      type = 'user',
      uuid = 'p1',
      timestamp = ts(8),
      origin = {
        kind = 'peer',
        from = 'c3d4',
        handback = true,
        body = '[Subagent hand-back]\n  Found 2 issues.\n  - one',
      },
      message = { role = 'user', content = 'report' },
    },
    user('n1', 9, notification),
    -- which the stream may have reported too
    user('n2', 9, notification),
    {
      type = 'attachment',
      uuid = 'n3',
      timestamp = ts(10),
      attachment = {
        type = 'queued_command',
        prompt = table.concat({
          '<task-notification>',
          '<task-id>b1</task-id>',
          '<tool-use-id>t3</tool-use-id>',
          '<output-file>' .. output .. '</output-file>',
          '<status>failed</status>',
          '<summary>Background command "npm run dev" failed with exit code 1</summary>',
          '</task-notification>',
        }, '\n'),
      },
    },
    -- of a task that's not a tool
    user('n4', 11, '<task-notification>\n<task-id>zz</task-id>\n<status>completed</status>\n</task-notification>'),
  }
  local events = decode_all(entries)
  local agent_args = { description = 'Audit', prompt = 'p', background = true }
  local bash_args = { command = 'npm run dev', background = true }
  t.check('events', t.without(events, { 'at', 'started' }), {
    { type = 'user', text = 'review' },
    {
      type = 'tool_call',
      id = 't1',
      tool = 'agent',
      args = { description = 'Review', prompt = 'look', type = 'general-purpose' },
    },
    -- the answer, without its id
    { type = 'tool_result', id = 't1', ok = true, output = 'Looks good.' },
    { type = 'tool_call', id = 't2', tool = 'agent', args = agent_args },
    { type = 'tool_result', id = 't2', ok = true, output = '', background = true },
    { type = 'tool_call', id = 't3', tool = 'bash', args = bash_args },
    { type = 'tool_result', id = 't3', ok = true, output = '', background = true },
    { type = 'text', text = 'Started both.' },
    -- the report ends the turn like a prompt
    { type = 'turn_end', aborted = false, worked = true },
    { type = 'tool_call', id = 'c3d4:end', tool = 'agent', args = agent_args },
    { type = 'tool_result', id = 'c3d4:end', ok = true, output = 'Found 2 issues.\n- one' },
    { type = 'tool_call', id = 'b1:end', tool = 'bash', args = bash_args },
    { type = 'tool_result', id = 'b1:end', ok = false, output = 'listening\ncrash', exit_code = 1 },
    { type = 'turn_end', aborted = false, worked = true },
  })

  -- the stream's notification, which has the report and no file
  local log, stream = t.log()
  local decoder = decode.new()
  decoder.calls.t9 = { tool = 'bash', args = { command = 'x', background = true } }
  decode.add_task_end(
    log,
    decoder,
    { task_id = 'b9', tool_use_id = 't9', status = 'completed', summary = 'exit code 0' }
  )
  t.check(
    'missing output',
    stream[2],
    { type = 'tool_result', id = 'b9:end', ok = true, output = '', exit_code = 0, at = stream[2].at }
  )
  decode.add_task_end(log, decoder, { task_id = 'b8', tool_use_id = 't9', skip_transcript = true })
  t.check('skip_transcript', #stream, 2)
end)
