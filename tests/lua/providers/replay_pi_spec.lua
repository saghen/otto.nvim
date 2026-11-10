-- pi's sessions log and render the same live as replayed: the same messages, through its session file, along its
-- branch, and through its events, without the process

local t = ...
local event = require('otto.event')
local files = require('otto.providers.pi.files')

local base = event.parse_iso(t.ts(0))

local function text(value) return { { type = 'text', text = value } } end
local function user(value) return { role = 'user', content = text(value), timestamp = 1 } end
local function call(id, name, args, extra)
  local msg = {
    role = 'assistant',
    content = { { type = 'toolCall', id = id, name = name, arguments = args } },
    stopReason = 'toolUse',
    usage = { totalTokens = 1000, cost = { total = 0.5 } },
  }
  return vim.tbl_extend('force', msg, extra or {})
end
local function result(id, output, extra)
  local msg = { role = 'toolResult', toolCallId = id, toolName = 'bash', content = text(output), isError = false }
  return vim.tbl_extend('force', msg, extra or {})
end
local compaction = { summary = 'Fixed a test.', tokensBefore = 120000 }
-- /compact between the turns
local between = { summary = 'Between turns.', tokensBefore = 90000 }

-- messages of both, by turn, and the compaction while the agent works
local turns = {
  {
    user('fix the test'),
    call('c1', 'bash', { command = 'make test' }, {
      content = {
        { type = 'thinking', thinking = 'hmm' },
        { type = 'text', text = 'Running it.' },
        { type = 'toolCall', id = 'c1', name = 'bash', arguments = { command = 'make test' } },
      },
    }),
    result('c1', 'FAIL\n\nCommand exited with code 1', { isError = true }),
    call('c2', 'edit', { path = 'a.lua', oldText = 'y', newText = 'z' }),
    result(
      'c2',
      'Successfully replaced text in a.lua.',
      { toolName = 'edit', details = { diff = '  3 x\n- 4 y\n+ 4 z' } }
    ),
    compaction,
    { role = 'assistant', content = text('Fixed.'), stopReason = 'stop', usage = { totalTokens = 900 } },
  },
  {
    user('run it all'),
    call('c3', 'bash', { command = 'make all' }),
    result('c3', 'ok'),
    -- which steers
    user('and the docs'),
    { role = 'assistant', content = text('Stop'), stopReason = 'aborted' },
  },
}

-- replayed from the file, along its branch
local dir = vim.fn.tempname()
local records = {
  { type = 'session', version = 3, id = 'sess', timestamp = t.ts(0), cwd = '/w' },
  { type = 'model_change', id = 'm1', timestamp = t.ts(0), provider = 'anthropic', modelId = 'claude-opus-4-5' },
  { type = 'thinking_level_change', id = 'm2', parentId = 'm1', timestamp = t.ts(0), thinkingLevel = 'high' },
  -- a branch that was left
  { type = 'message', id = 'x1', parentId = 'm2', timestamp = t.ts(0), message = user('abandoned') },
}
local parent, s = 'm2', 1
for i, turn in ipairs(turns) do
  if i == 2 then table.insert(turn, 1, between) end
  for _, msg in ipairs(turn) do
    local id = 'e' .. s
    local record = (msg == compaction or msg == between) and vim.tbl_extend('force', { type = 'compaction' }, msg)
      or { type = 'message', message = msg }
    table.insert(records, vim.tbl_extend('force', record, { id = id, parentId = parent, timestamp = t.ts(s) }))
    parent, s = id, s + 1
  end
end
table.insert(records, { type = 'session_info', id = 'n1', parentId = parent, timestamp = t.ts(s), name = 'Tests' })
local file = dir .. '/1761066900_sess.jsonl'
t.write_jsonl(file, records)
vim.fn.writefile({ 'not json' }, file, 'a')
local session_file = files.session_file
files.session_file = function(id) return id == 'sess' and file or nil end
local replay, replayed, replay_state = t.open_agent('pi', 'sess', t.respond)
local bad = t.notified(function() replay:replay() end)
files.session_file = session_file
t.check('bad line', #bad, 1)
t.check('state', vim.list_slice(replay_state, 2, 4), {
  { model = 'anthropic/claude-opus-4-5' },
  { effort = 'high' },
  { context_tokens = 1000, cost = 0.5 },
})
t.check('name', replay_state[#replay_state], { name = 'Tests' })

-- live, as pi's events have the messages
local live, logged = t.open_agent('pi', 'sess', t.respond)
-- the compaction while the agent works
for _, turn in ipairs(turns) do
  live:on_message({ type = 'agent_start' })
  for _, msg in ipairs(turn) do
    if msg == between then
      -- before the run, so outside any turn
      live:on_message({ type = 'agent_settled' })
      live:on_message({ type = 'compaction_start', reason = 'manual' })
      live:on_message({ type = 'compaction_end', result = msg })
      live:on_message({ type = 'agent_start' })
    elseif msg == compaction then
      live:on_message({ type = 'compaction_start', reason = 'threshold' })
      live:on_message({ type = 'compaction_end', result = msg })
    else
      if msg.role == 'user' then live:prompt(msg.content[1].text, 'steer') end
      live:on_message({ type = 'message_start', message = msg })
      live:on_message({ type = 'message_end', message = msg })
    end
  end
  live:on_message({ type = 'agent_settled' })
end

t.check('events', t.types(replayed), {
  'user',
  'text',
  'tool_call',
  'tool_result',
  'tool_call',
  'tool_result',
  'compaction',
  'text',
  'turn_end',
  'compaction',
  'user',
  'tool_call',
  'tool_result',
  'user',
  'text',
  'turn_end',
})
t.check('aborted', replayed[#replayed].aborted, true)
t.check('replay times', { replayed[1].at, replayed[9].at }, { base + 1000, base + 7000 })
t.check('live matches', t.untimed(logged), t.untimed(replayed))
t.check('layout matches', t.layout(t.untimed(logged)), t.layout(t.untimed(replayed)))
