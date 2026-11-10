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

t.describe('where it compacts', function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  local settings =
    { compaction = { reserveTokens = 20000, modelOverrides = { ['p/small'] = { reserveTokens = 1000 } } } }
  vim.fn.writefile({ vim.json.encode(settings) }, dir .. '/settings.json')
  local agent_dir = vim.env.PI_CODING_AGENT_DIR
  vim.env.PI_CODING_AGENT_DIR = dir
  local function open(enabled)
    local _, _, patches = t.open_agent('pi', 'compacts', function(msg)
      if msg.type ~= 'get_state' then return nil, {} end
      return nil, { model = { provider = 'p', id = 'big', contextWindow = 200000 }, autoCompactionEnabled = enabled }
    end)
    vim.wait(100, function() return #patches > 0 end)
    return patches[#patches], patches
  end
  t.check('the window less the reserved tokens', open(true).compact_at, 180000)
  local _, patches = open(true)
  local agent = t.open_agent('pi', 'compacts', function(msg)
    if msg.type == 'set_model' then return nil, { contextWindow = 10000 } end
    return nil, { model = { provider = 'p', id = 'big', contextWindow = 200000 } }
  end)
  agent.on_state = function(patch) table.insert(patches, patch) end
  t.run(function() agent:set_model('p/small') end)
  t.check('of the model', patches[#patches].compact_at, 9000)
  t.check('not when it is off', open(false).compact_at, false)
  vim.env.PI_CODING_AGENT_DIR = agent_dir
end)
