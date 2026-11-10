-- providers/log.lua: turns and their ends

local t = ...

t.describe('a turn', function()
  local log, events = t.log()
  log:user('hi', 1000)
  t.check('in turn', log.in_turn, true)
  t.check('prompt alone did nothing', log.worked, false)
  log:text('looking', 2000, true)
  log:tool_call('c1', 'bash', { command = 'ls' }, 3000)
  log:tool_result({ id = 'c1', ok = true, output = 'a' }, 4000)
  log:text('done', 5000)
  log:end_turn()
  t.check('events', events, {
    { type = 'user', text = 'hi', at = 1000 },
    { type = 'text', text = 'looking', at = 2000 },
    { type = 'tool_call', id = 'c1', tool = 'bash', args = { command = 'ls' }, at = 3000 },
    { type = 'tool_result', id = 'c1', ok = true, output = 'a', at = 4000 },
    { type = 'text', text = 'done', at = 5000 },
    { type = 'turn_end', aborted = false, started = 1000, worked = true, at = 5000 },
  })
  log:end_turn()
  t.check('ends once', #events, 6)
end)

t.describe('prompts', function()
  local log, events = t.log()
  log:user('one', 1)
  log:text('answer', 2)
  log:user('two', 3)
  t.check(
    'after an answer end the turn',
    events[3],
    { type = 'turn_end', aborted = false, started = 1, worked = true, at = 2 }
  )
  t.check('and start the next', { log.in_turn, log.started }, { true, 3 })

  log:tool_call('c', 'read', { path = 'a' }, 4)
  log:tool_result({ id = 'c', ok = true }, 5)
  log:user('steer', 6)
  t.check('after a tool steer', events[#events].type, 'user')

  log:text('thinking out loud', 7, true)
  log:user('steer again', 8)
  t.check('after commentary steer', events[#events].type, 'user')

  log:error('boom', 9)
  log:user('three', 10)
  t.check('after an error end the turn', events[#events - 1].type, 'turn_end')
end)

t.describe('only a prompt', function()
  local log, events = t.log()
  log:user('/compact', 1)
  log:end_turn(false, 7)
  t.check('turn_end', events[2], { type = 'turn_end', aborted = false, started = 1, worked = false, at = 7 })
end)

t.describe('aborts', function()
  local log, events = t.log()
  log:user('one', 1)
  log:tool_call('c', 'bash', { command = 'sleep 9' }, 2)
  log:mark_aborted()
  log:interject()
  t.check(
    'interject ends an aborted turn',
    events[3],
    { type = 'turn_end', aborted = true, started = 1, worked = true, at = 2 }
  )
  log:user('two', 3)
  t.check('next turn starts clean', log.aborted, false)
  log:end_turn(true)
  t.check('end_turn aborted', events[5].aborted, true)

  log:user('three', 4)
  log:interject()
  t.check('interject without an answer keeps the turn', log.in_turn, true)
end)

t.describe('compaction', function()
  local log, events = t.log()
  log:compaction({ before = 100 }, 1)
  t.check('outside turns', events, { { type = 'compaction', before = 100, at = 1 } })
  t.check('starts no turn', log.in_turn, false)
  log:user('hi', 2)
  log:text('ok', 3)
  log:compaction({}, 9)
  log:end_turn()
  t.check('does not move the end', events[#events].at, 3)
end)

t.describe('now by default', function()
  local log, events = t.log()
  local before = require('otto.event').now()
  log:user('hi')
  t.check('at', events[1].at >= before, true)
end)

t.describe('patch_state', function()
  local log, events, patches = t.log()
  log:patch_state({ name = 'x' })
  t.check('goes to the state', patches, { { name = 'x' } })
  t.check('not the log', events, {})
end)
