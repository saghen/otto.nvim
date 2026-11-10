-- Codex's threads log and render the same live as replayed: the same items, through the app-server's pages of turns
-- and through its notifications, without the process

local t = ...
local event = require('otto.event')

local base = event.parse_iso(t.ts(0))

local thread = '019a2b3c-0000-7000-8000-00000000abcd'
local s0 = math.floor(base / 1000)
local function user(id, text)
  return { type = 'userMessage', id = id, content = { { type = 'text', text = text, text_elements = {} } } }
end
local function shell(id, command, extra)
  local item = {
    type = 'commandExecution',
    id = id,
    command = "/bin/bash -lc '" .. command .. "'",
    cwd = '/w',
    commandActions = {},
    status = 'completed',
    aggregatedOutput = '',
    exitCode = 0,
    durationMs = 30,
  }
  return vim.tbl_extend('force', item, extra or {})
end
local turns = {
  {
    id = 't1',
    status = 'completed',
    startedAt = s0,
    completedAt = s0 + 60,
    items = {
      user('u1', 'fix the test'),
      { type = 'agentMessage', id = 'm1', text = 'Looking.', phase = 'commentary' },
      shell('c1', 'cat a.lua', {
        commandActions = { { type = 'read', command = 'cat a.lua', name = 'a.lua', path = '/w/a.lua' } },
        aggregatedOutput = 'x\ny\n',
      }),
      user('u2', 'also lint'),
      {
        type = 'fileChange',
        id = 'f1',
        status = 'completed',
        changes = {
          { path = '/w/a.lua', kind = { type = 'update' }, diff = '@@ -1,2 +1,2 @@\n x\n-y\n+z\n' },
          { path = '/w/b.lua', kind = { type = 'add' }, diff = 'new\n' },
        },
      },
      shell('c2', 'make lint', { aggregatedOutput = 'ok\n', durationMs = 16000 }),
      { type = 'agentMessage', id = 'm2', text = 'Fixed and linted.', phase = 'final_answer' },
    },
  },
  {
    id = 't2',
    status = 'interrupted',
    startedAt = s0 + 100,
    completedAt = s0 + 105,
    items = { user('u3', 'run everything'), shell('c3', 'make all', { status = 'failed', exitCode = 130 }) },
  },
  {
    id = 't3',
    status = 'completed',
    startedAt = s0 + 200,
    completedAt = s0 + 230,
    items = { { type = 'contextCompaction', id = 'k1' } },
  },
  {
    id = 't4',
    status = 'failed',
    startedAt = s0 + 300,
    durationMs = 2000,
    error = { message = 'stream disconnected' },
    items = { user('u4', 'hello?') },
  },
}

-- replayed from the app-server's pages of turns
local function history(msg)
  if msg.method == 'thread/resume' then
    return nil, { thread = { id = thread, name = 'Fix' }, model = 'gpt-5', reasoningEffort = 'medium' }
  end
  if msg.method == 'model/list' then return nil, { data = {} } end
  if msg.method == 'thread/turns/list' then
    if msg.params.cursor == nil then return nil, { data = { turns[1], turns[2] }, nextCursor = 'p2' } end
    return nil, { data = { turns[3], turns[4] } }
  end
  return nil, {}
end
local replay, replayed, _, replay_sent = t.open_agent('codex', thread, history)
t.run(function() replay:replay() end)
local pages = vim.tbl_filter(function(msg) return msg.method == 'thread/turns/list' end, replay_sent)
t.check('pages', vim.tbl_map(function(msg) return msg.params.cursor or 'first' end, pages), { 'first', 'p2' })

-- live, as the app-server notifies them
local live, logged, state, sent = t.open_agent('codex', thread, history)
local function notify(method, params) live:on_message({ method = method, params = params }) end
local tools = { commandExecution = true, fileChange = true }
--- @return string id that the prompt goes with
local function prompt(text)
  local count = #sent
  live:prompt(text, 'steer')
  vim.wait(100, function() return #sent > count end)
  return sent[#sent].params.clientUserMessageId
end
for i, turn in ipairs(turns) do
  -- the prompt that starts the turn, before Codex starts it
  local first = turn.items[1].type == 'userMessage' and prompt(turn.items[1].content[1].text)
  local summary = { id = turn.id, status = 'inProgress', startedAt = turn.startedAt, items = {} }
  notify('turn/started', { threadId = thread, turn = summary })
  for j, item in ipairs(turn.items) do
    local completed = vim.deepcopy(item)
    if item.type == 'userMessage' then completed.clientId = j == 1 and first or prompt(item.content[1].text) end
    if tools[item.type] or item.type == 'contextCompaction' then
      local started = vim.tbl_extend('force', vim.deepcopy(item), { status = 'inProgress', aggregatedOutput = '' })
      notify('item/started', { threadId = thread, turnId = turn.id, item = started })
    end
    notify('item/completed', { threadId = thread, turnId = turn.id, item = completed })
  end
  if turn.status == 'interrupted' then live:abort() end
  if turn.error then notify('error', { error = turn.error, willRetry = false, threadId = thread, turnId = turn.id }) end
  notify('turn/completed', { threadId = thread, turn = vim.tbl_extend('force', turn, { items = {} }) })
  t.check('turn ' .. i .. ' read its prompts', live.unread, {})
end
t.check('methods', vim.tbl_map(function(msg) return msg.method end, vim.list_slice(sent, 5)), {
  'turn/start',
  'turn/steer',
  'turn/start',
  'turn/interrupt',
  'turn/start',
})

t.check('events', t.types(replayed), {
  'user',
  'text',
  'tool_call',
  'tool_result',
  'user',
  'tool_call',
  'tool_call',
  'tool_result',
  'tool_result',
  'tool_call',
  'tool_result',
  'text',
  'turn_end',
  'user',
  'tool_call',
  'tool_result',
  'turn_end',
  'compaction',
  'user',
  'error',
  'turn_end',
})
t.check('aborted', replayed[17].aborted, true)
t.check('turn times', { replayed[13].started, replayed[13].at, replayed[21].at }, {
  base,
  base + 60000,
  base + 302000,
})
-- items have no times, so live and replayed times are the same
t.check('live matches', logged, replayed)
t.check('layout matches', t.layout(logged), t.layout(replayed))
t.check('stopped', state[#state].status, false)
