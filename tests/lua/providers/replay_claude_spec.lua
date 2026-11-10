-- Claude Code's sessions log and render the same live as replayed: the same entries, through its session file and
-- through its stream, without the process

local t = ...
local event = require('otto.event')

local base = event.parse_iso(t.ts(0))

local function entry(kind, uuid, parent, s, message, extra)
  local fields = {
    type = kind,
    uuid = uuid,
    parentUuid = parent,
    timestamp = t.ts(s),
    sessionId = 'sess',
    cwd = '/w',
    message = message,
  }
  return vim.tbl_extend('force', fields, extra or {})
end
local function prompt(uuid, parent, s, text)
  local message = { role = 'user', content = text }
  return entry('user', uuid, parent, s, message)
end
local function answer(uuid, parent, s, blocks, extra)
  local usage = { input_tokens = 1, cache_read_input_tokens = 100, cache_creation_input_tokens = 0, output_tokens = 1 }
  local message = { model = 'claude-opus-4-5', role = 'assistant', content = blocks, usage = usage }
  return entry('assistant', uuid, parent, s, message, extra)
end
local function result(uuid, parent, s, id, content, details, is_error)
  local block = { type = 'tool_result', tool_use_id = id, content = content, is_error = is_error }
  return entry('user', uuid, parent, s, { role = 'user', content = { block } }, { toolUseResult = details })
end
local patch = {
  filePath = '/w/a.lua',
  structuredPatch = { { oldStart = 3, oldLines = 2, newStart = 3, newLines = 2, lines = { ' x', '-y', '+z' } } },
}

-- the entries of both, by turn
local turns = {
  {
    prompt('u1', nil, 0, 'fix the test'),
    answer('a1', 'u1', 1, { { type = 'text', text = 'Running it.' } }),
    answer('a2', 'a1', 1, { { type = 'tool_use', id = 't1', name = 'Bash', input = { command = 'make test' } } }),
    result('r1', 'a2', 3, 't1', 'Exit code 1\nFAIL', 'Error: Exit code 1\nFAIL', true),
    answer('a3', 'r1', 4, { { type = 'tool_use', id = 't2', name = 'Edit', input = { file_path = '/w/a.lua' } } }),
    result('r2', 'a3', 5, 't2', 'The file /w/a.lua has been updated.', patch),
    answer('a4', 'r2', 6, { { type = 'text', text = 'Fixed.' } }),
  },
  {
    prompt('u2', 'a4', 60, 'run lint'),
    answer('a5', 'u2', 61, { { type = 'tool_use', id = 't3', name = 'Bash', input = { command = 'make lint' } } }),
    -- a prompt that steers, which the file has as an attachment and the stream echoes
    entry('attachment', 'q1', 'a5', 62, nil, {
      attachment = { type = 'queued_command', prompt = 'also format', commandMode = 'prompt' },
    }),
    result('r3', 'q1', 63, 't3', 'ok'),
    entry(
      'user',
      'i1',
      'r3',
      64,
      { role = 'user', content = { { type = 'text', text = '[Request interrupted by user]' } } }
    ),
  },
  {
    prompt('u3', 'i1', 120, 'hello?'),
    answer('e1', 'u3', 121, { { type = 'text', text = 'API Error: 500' } }, {
      isApiErrorMessage = true,
      message = {
        model = '<synthetic>',
        role = 'assistant',
        content = { { type = 'text', text = 'API Error: 500' } },
      },
    }),
  },
}

-- replayed from the file, with what only the file has
local file = vim.fn.tempname() .. '/sess.jsonl'
local records = { { type = 'file-history-snapshot', messageId = 'm', snapshot = {} } }
for _, turn in ipairs(turns) do
  vim.list_extend(records, turn)
end
table.insert(records, { type = 'ai-title', aiTitle = 'Fix the test', sessionId = 'sess' })
t.write_jsonl(file, records)
vim.fn.writefile({ '{"type":"user",' }, file, 'a')
local replay, replayed, replay_state = t.open_agent('claude', 'sess', t.respond)
replay.file = file
local bad = t.notified(function() replay:replay() end)
t.check('bad line', #bad, 1)
t.check(
  'name',
  vim.tbl_contains(replay_state, function(p) return p.name == 'Fix the test' end, { predicate = true }),
  true
)

-- live, as the stream has the entries
local live, logged, state, sent = t.open_agent('claude', 'sess', t.respond)
local function stream(e)
  local msg = vim.deepcopy(e)
  msg.timestamp, msg.parentUuid, msg.cwd, msg.sessionId = nil, nil, nil, nil
  msg.session_id = 'sess'
  msg.tool_use_result, msg.toolUseResult = msg.toolUseResult, nil
  -- echoed prompts that steer
  if msg.type == 'attachment' then
    msg = {
      type = 'user',
      uuid = msg.uuid,
      session_id = 'sess',
      message = { role = 'user', content = msg.attachment.prompt },
    }
  end
  live:on_message(msg)
end
local function prompted(text)
  live:prompt(text, 'steer')
  t.check('sent ' .. text, sent[#sent].message, { role = 'user', content = text })
end
local ends =
  { { subtype = 'success' }, { subtype = 'error_during_execution' }, { subtype = 'success', is_error = true } }
for i, turn in ipairs(turns) do
  live:on_message({ type = 'system', subtype = 'init', model = 'claude-opus-4-5', session_id = 'sess' })
  for _, e in ipairs(turn) do
    if e.type == 'user' and type(e.message.content) == 'string' then prompted(e.message.content) end
    if e.type == 'attachment' then prompted(e.attachment.prompt) end
    if e.uuid == 'a1' then
      live:on_message({
        type = 'stream_event',
        event = { type = 'content_block_start', content_block = { type = 'thinking' } },
      })
      live:on_message({ type = 'stream_event', event = { type = 'content_block_stop' } })
    end
    if e.uuid == 'i1' then live:abort() end
    stream(e)
  end
  local usage = { ['claude-opus-4-5'] = { contextWindow = 200000 } }
  live:on_message(vim.tbl_extend('force', { type = 'result', modelUsage = usage, session_id = 'sess' }, ends[i]))
end

t.check('events', t.types(replayed), {
  'user',
  'text',
  'tool_call',
  'tool_result',
  'tool_call',
  'tool_result',
  'text',
  'turn_end',
  'user',
  'tool_call',
  'user',
  'tool_result',
  'turn_end',
  'user',
  'error',
  'turn_end',
})
t.check('replay times', { replayed[1].at, replayed[8].at, replayed[8].started }, { base, base + 6000, base })
t.check('live matches', t.untimed(logged), t.untimed(replayed))
t.check('layout matches', t.layout(t.untimed(logged)), t.layout(t.untimed(replayed)))
local queues = vim.tbl_filter(function(p) return p.queue ~= nil end, state)
t.check('queue read', queues[#queues].queue, {})
t.check('stopped', state[#state].status, false)
