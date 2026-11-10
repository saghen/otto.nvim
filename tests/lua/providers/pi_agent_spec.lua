-- pi/agent.lua over a fake process: what replay doesn't cover, like its extensions' dialogs and its queue

local t = ...

t.describe('dialogs', function()
  local agent, _, _, sent, requests = t.open_agent('pi', 'dialogs', t.respond)
  agent:on_message({ type = 'extension_ui_request', id = 'd1', method = 'confirm', title = 'Run', message = 'make' })
  local request = requests[#requests]
  t.check('confirm', { request.kind, request.prompt }, { 'confirm', 'Run: make' })
  request.respond(true)
  t.check('confirmed', sent[#sent], { type = 'extension_ui_response', id = 'd1', confirmed = true })

  agent:on_message({ type = 'extension_ui_request', id = 'd2', method = 'select', title = 'Pick', options = { 'a' } })
  request = requests[#requests]
  t.check('select', { request.kind, request.prompt, request.items }, { 'select', 'Pick', { 'a' } })
  request.respond(nil)
  t.check('cancelled', sent[#sent], { type = 'extension_ui_response', id = 'd2', cancelled = true })

  agent:on_message({ type = 'extension_ui_request', id = 'd3', method = 'editor', title = 'Edit', prefill = 'x' })
  request = requests[#requests]
  t.check('editor as input', { request.kind, request.default }, { 'input', 'x' })
  request.respond('y')
  t.check('with the value', sent[#sent], { type = 'extension_ui_response', id = 'd3', value = 'y' })

  local count = #requests
  local notified = t.notified(
    function() agent:on_message({ type = 'extension_ui_request', id = 'd4', method = 'notify', message = 'hi' }) end
  )
  t.check('notifications', { notified, #requests }, { { 'otto: hi' }, count })
end)

t.describe('take_queue', function()
  local agent, _, _, sent = t.open_agent('pi', 'queue', function(msg)
    if msg.type == 'clear_queue' then return nil, { steering = { 'a' }, followUp = { 'b', 'c' } } end
    return nil, {}
  end)
  local texts
  t.run(function() texts = agent:take_queue(true) end)
  t.check('the newest', texts, { 'c' })
  local prompts = vim.tbl_filter(function(msg) return msg.type == 'prompt' end, sent)
  t.check(
    'sends the others again',
    vim.tbl_map(function(msg) return { msg.message, msg.streamingBehavior } end, prompts),
    { { 'a', 'steer' }, { 'b', 'followUp' } }
  )
  t.run(function() texts = agent:take_queue() end)
  t.check('or all', texts, { 'a', 'b', 'c' })
end)

t.describe('responses', function()
  local agent = t.open_agent('pi', 'responses', t.respond)
  local resolved
  agent.rpc.resolve = function(_, id, err) resolved = { id, err } end
  agent:on_message({ type = 'response', id = '5', success = false })
  t.check('an error without a message fails all the same', resolved, { '5', 'request failed' })
end)
