-- claude/agent.lua over a fake process: what replay doesn't cover, like prompts to a process that's gone, and
-- permissions

local t = ...

t.describe('prompt after the process exited', function()
  local agent, _, patches = t.open_agent('claude', 'gone', t.respond)
  agent.rpc.send = function() return false end
  local count = #patches
  agent:prompt('hello', 'steer')
  t.check('stays idle', agent.working, false)
  t.check('queues nothing', agent.unread, {})
  t.check('reports nothing', #patches, count)
end)

t.describe('permissions', function()
  local agent, _, _, sent, requests = t.open_agent('claude', 'perms', t.respond)
  local suggestions = { { type = 'addRules', rules = { { toolName = 'Bash' } } } }
  local input = { command = 'make' }
  --- @param id string
  --- @param with_suggestions boolean
  --- @return otto.Request
  local function ask(id, with_suggestions)
    agent:on_message({
      type = 'control_request',
      request_id = id,
      request = {
        subtype = 'can_use_tool',
        tool_name = 'Bash',
        display_name = 'Bash',
        description = 'make',
        input = input,
        permission_suggestions = with_suggestions and suggestions or nil,
      },
    })
    return requests[#requests]
  end
  --- @return table response that Claude Code gets
  local function answered() return sent[#sent].response.response end

  local request = ask('1', true)
  t.check('asks', { request.kind, request.prompt, request.items }, {
    'select',
    'Claude wants to use Bash make: ',
    { 'Allow', 'Always allow', 'Deny' },
  })
  request.respond('Allow')
  t.check('allow', answered(), { behavior = 'allow', updatedInput = input })
  t.check('to the request', sent[#sent].response.request_id, '1')
  ask('2', true).respond('Always allow')
  t.check('always', answered(), { behavior = 'allow', updatedInput = input, updatedPermissions = suggestions })
  ask('3', true).respond('Deny')
  t.check('deny', answered(), { behavior = 'deny', message = 'The user denied this' })
  ask('4', true).respond(nil)
  t.check('cancelled', answered().behavior, 'deny')
  t.check('always only with suggestions', ask('5', false).items, { 'Allow', 'Deny' })

  agent:on_message({ type = 'control_request', request_id = '6', request = { subtype = 'elicitation' } })
  t.check('refuses others', sent[#sent].response, {
    subtype = 'error',
    request_id = '6',
    error = 'elicitation is not supported by otto',
  })

  local count = #sent
  local withdrawn = ask('7', false)
  agent:on_message({ type = 'control_cancel_request', request_id = '7' })
  t.check('withdrawn', withdrawn.cancelled, true)
  withdrawn.respond('Allow')
  t.check('answers nothing once withdrawn', #sent, count)
  local unanswered = ask('8', false)
  agent:reset()
  t.check('withdrawn once the process exited', unanswered.cancelled, true)
end)

t.describe('turn that otto did not start', function()
  local agent = t.open_agent('claude', 'unprompted', t.respond)
  agent:on_message({ type = 'stream_event', event = { type = 'message_start' } })
  t.check('works', agent.working, true)
end)

t.describe('remote control', function()
  local link = 'https://claude.ai/code/session_1'
  local agent, _, patches, sent = t.open_agent('claude', 'remote', function(msg)
    local request = msg.request or {}
    if request.subtype == 'remote_control' then return nil, request.enabled and { session_url = link } or {} end
    return nil, {}
  end)
  local got
  t.run(function() got = agent:remote_control(true) end)
  t.check('asks', sent[#sent].request, { subtype = 'remote_control', enabled = true })
  t.check('returns the link', got, link)
  t.check('reports it', patches[#patches].remote, link)
  agent:on_message({ type = 'system', subtype = 'bridge_state', state = 'reconnecting' })
  t.check('stays on while it reconnects', patches[#patches].remote, link)
  agent:on_message({ type = 'system', subtype = 'bridge_state', state = 'failed', failure_kind = 'terminal' })
  t.check('off once it failed for good', patches[#patches].remote, false)
  t.run(function() got = agent:remote_control(false) end)
  t.check('off', { got, patches[#patches].remote }, { nil, false })
end)

t.describe('responses', function()
  local agent = t.open_agent('claude', 'responses', t.respond)
  local resolved
  agent.rpc.resolve = function(_, id, err) resolved = { id, err } end
  agent:on_message({ type = 'control_response', response = { subtype = 'error', request_id = '3' } })
  t.check('an error without a message fails all the same', resolved, { '3', 'request failed' })
  agent:on_message({ type = 'control_response', response = { subtype = 'success', request_id = '4', response = {} } })
  t.check('success', resolved, { '4' })
end)

t.describe('commands of a process that exited', function()
  local agent = t.open_agent('claude', 'commands', t.respond)
  agent.rpc.running = function() return false end
  for _, run in ipairs({
    function() agent:compact('x') end,
    function() agent:rename('x') end,
  }) do
    local ok, err
    t.run(function()
      ok, err = pcall(run)
    end)
    t.check('raise', { ok, err }, { false, 'claude is not running' })
  end
end)

t.describe('take_queue', function()
  local kept = {}
  local agent, _, patches, sent = t.open_agent('claude', 'queue', function(msg)
    local request = msg.request or {}
    if request.subtype == 'cancel_async_message' then
      -- Claude Code read one already
      return nil, { cancelled = not kept[request.message_uuid] }
    end
    return nil, {}
  end)
  agent:prompt('first', 'steer')
  agent:prompt('steer', 'steer')
  agent:prompt('later', 'follow_up')
  kept[sent[#sent - 1].uuid] = true
  local texts
  t.run(function() texts = agent:take_queue() end)
  t.check('takes those it cancels, in the order they were sent', texts, { 'first', 'later' })
  t.check('leaves the one it read', patches[#patches].queue, { { text = 'steer', follow_up = false } })
  t.run(function() texts = agent:take_queue(true) end)
  t.check('nothing that it read', texts, {})
end)
