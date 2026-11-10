-- codex/agent.lua over a fake process: what replay doesn't cover, like bad items, the models, aborts and approvals

local t = ...

local thread = '019a2b3c-0000-7000-8000-00000000abcd'

--- Resumes the thread, and answers the rest without an error
local function resume(msg)
  if msg.method == 'thread/resume' then
    return nil, { thread = { id = thread }, model = 'gpt-5', reasoningEffort = 'low' }
  end
  return nil, {}
end

--- @param sent table[]
--- @return string[]
local function methods(sent)
  return vim.tbl_map(function(msg) return msg.method or '' end, sent)
end

t.describe('replay', function()
  local function history(msg)
    if msg.method ~= 'thread/turns/list' then return resume(msg) end
    local text = { type = 'agentMessage', id = 'm', text = 'fine', phase = 'final_answer' }
    return nil,
      {
        data = {
          -- without its text
          { id = 't1', status = 'completed', items = { { type = 'agentMessage', id = 'bad' } } },
          { id = 't2', status = 'completed', items = { text } },
        },
      }
  end
  local agent, events = t.open_agent('codex', thread, history)
  local notified = t.notified(function()
    t.run(function() agent:replay() end)
  end)
  t.check('notifies the bad item', #notified, 1)
  t.match('as codex', notified[1], '^otto: codex: ')
  t.check('replays the turns after it', t.types(events), { 'text', 'turn_end' })
end)

t.describe('models', function()
  local agent, _, patches = t.open_agent('codex', thread, function(msg)
    if msg.method == 'model/list' then return t.later end
    return resume(msg)
  end)
  local models
  local task = vim.async.run(function() models = agent:models() end)
  t.check('wait for the list', models, nil)
  local efforts = { { reasoningEffort = 'low' }, { reasoningEffort = 'high' } }
  agent.rpc.held['model/list'](nil, { data = { { id = 'gpt-5', supportedReasoningEfforts = efforts } } })
  task:wait(1000)
  t.check('once it arrives', models, { 'gpt-5' })
  t.run(function() agent:cycle_effort() end)
  t.check('cycles through those of the model', patches[#patches], { effort = 'high' })

  local failed = t.open_agent('codex', thread, function(msg)
    if msg.method == 'model/list' then return 'codex: no models' end
    return resume(msg)
  end)
  local ok, err
  t.run(function()
    ok, err = pcall(failed.models, failed)
  end)
  t.check('raise when the list failed', { ok, err }, { false, 'codex: no models' })
end)

t.describe('abort before the turn starts', function()
  local agent, _, _, sent = t.open_agent('codex', thread, resume)
  agent:prompt('go', 'steer')
  vim.wait(100, function() return vim.list_contains(methods(sent), 'turn/start') end)
  agent:prompt('more', 'steer')
  agent:abort()
  t.check('waits for the turn', vim.list_contains(methods(sent), 'turn/interrupt'), false)

  agent:on_message({ method = 'turn/started', params = { turn = { id = 't1', status = 'inProgress', items = {} } } })
  local last = sent[#sent]
  t.check('interrupts it once it starts', { last.method, last.params.turnId }, { 'turn/interrupt', 't1' })
  t.check('keeps the prompt of the turn, which Codex reads', vim.tbl_map(function(u) return u.text end, agent.unread), {
    'go',
  })
  t.check('and the others for after it', agent.follow_ups, { 'more' })

  agent:on_message({ method = 'turn/completed', params = { turn = { id = 't1', status = 'interrupted' } } })
  local count = #methods(sent)
  agent:on_message({ method = 'turn/started', params = { turn = { id = 't2', status = 'inProgress', items = {} } } })
  t.check('once', #methods(sent), count)

  local idle, _, _, idle_sent = t.open_agent('codex', thread, resume)
  idle:abort()
  idle:on_message({ method = 'turn/started', params = { turn = { id = 't3', status = 'inProgress', items = {} } } })
  t.check('nothing to abort while idle', vim.list_contains(methods(idle_sent), 'turn/interrupt'), false)
end)

t.describe('approvals', function()
  local agent, _, _, sent, requests = t.open_agent('codex', thread, resume)
  local cases = {
    { 'Allow', 'accept' },
    { 'Always allow', 'acceptForSession' },
    { 'Deny', 'decline' },
    { nil, 'decline' },
  }
  for i = 1, #cases do
    local choice, decision = cases[i][1], cases[i][2]
    local params = { command = 'rm -rf x', reason = 'cleanup' }
    agent:on_message({ id = i, method = 'item/commandExecution/requestApproval', params = params })
    local request = requests[#requests]
    request.respond(choice)
    t.check(decision, sent[#sent], { id = i, result = { decision = decision } })
  end
  t.check('asks', { requests[1].kind, requests[1].prompt, requests[1].items }, {
    'select',
    'Codex wants to run rm -rf x (cleanup): ',
    { 'Allow', 'Always allow', 'Deny' },
  })
  agent:on_message({ id = 9, method = 'item/fileChange/requestApproval', params = {} })
  t.check('of file changes', requests[#requests].prompt, 'Codex wants to change files: ')

  local count = #requests
  agent:on_message({ id = 10, method = 'item/permissions/requestApproval', params = {} })
  t.check('not of permissions', #requests, count)
  t.check('which it refuses', sent[#sent].error.code, -32601)
end)

--- @param agent table
--- @param id string
local function started(agent, id)
  agent:on_message({ method = 'turn/started', params = { turn = { id = id, status = 'inProgress', items = {} } } })
end

--- @param sent table[]
--- @param method string
--- @return integer
local function count(sent, method)
  return #vim.tbl_filter(function(name) return name == method end, methods(sent))
end

t.describe('a steer that fails while a follow-up starts', function()
  local agent, _, _, sent = t.open_agent('codex', thread, function(msg)
    if msg.method == 'turn/steer' then return t.later end
    return resume(msg)
  end)
  agent:prompt('first', 'steer')
  vim.wait(100, function() return count(sent, 'turn/start') == 1 end)
  started(agent, 't1')
  agent:prompt('later', 'follow_up')
  agent:prompt('steer', 'steer')
  -- the turn ends before Codex gets the prompt, and the follow-up starts
  agent:on_message({ method = 'turn/completed', params = { turn = { id = 't1', status = 'completed' } } })
  vim.wait(100, function() return count(sent, 'turn/start') == 2 end)
  agent.rpc.held['turn/steer']('codex: no active turn')
  vim.wait(20)
  t.check('starts no other turn', count(sent, 'turn/start'), 2)
  t.check('waits for the follow-up', agent.follow_ups, { 'steer' })
end)

t.describe('take_queue', function()
  local agent, _, _, sent = t.open_agent('codex', thread, resume)
  agent:prompt('first', 'steer')
  vim.wait(100, function() return count(sent, 'turn/start') == 1 end)
  started(agent, 't1')
  agent:prompt('steer', 'steer')
  agent:prompt('later', 'follow_up')
  local texts
  t.run(function() texts = agent:take_queue() end)
  t.check('takes the prompts that steer, and the follow-ups', texts, { 'steer', 'later' })
  t.check('interrupting the turn, which drops those that steer', count(sent, 'turn/interrupt'), 1)
  t.check("but not the turn's own", vim.tbl_map(function(u) return u.text end, agent.unread), { 'first' })
  agent:abort()
  t.check('once', count(sent, 'turn/interrupt'), 1)

  local follow_ups, _, _, follow_ups_sent = t.open_agent('codex', thread, resume)
  follow_ups:prompt('first', 'steer')
  vim.wait(100, function() return count(follow_ups_sent, 'turn/start') == 1 end)
  started(follow_ups, 't2')
  follow_ups:on_message({
    method = 'item/completed',
    params = {
      turnId = 't2',
      item = {
        type = 'userMessage',
        clientId = follow_ups_sent[#follow_ups_sent].params.clientUserMessageId,
        content = { { type = 'text', text = 'first' } },
      },
    },
  })
  follow_ups:prompt('later', 'follow_up')
  t.run(function() texts = follow_ups:take_queue() end)
  t.check('only follow-ups', texts, { 'later' })
  t.check("which don't interrupt", count(follow_ups_sent, 'turn/interrupt'), 0)
end)
