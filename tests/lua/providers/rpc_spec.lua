-- rpc.lua over a real process: lines split across writes, bad lines, responses by id, and what fails once it exits

local t = ...
local rpc = require('otto.providers.rpc')
local util = require('otto.util')

-- answers the first request, fails the second, and exits on the third
local script = [[
read first
printf '{"split":'
sleep 0.05
printf '"line"}\n'
echo bad
printf '{"id":"1","result":%s}\n' "$first"
read second
printf '{"id":"2","error":"nope"}\n'
read third
echo oops >&2
exit 3
]]

local messages, responses, exits = {}, {}, {}
local process
--- @param name string
--- @return fun(err?: string, data?: any)
local function respond(name)
  return function(err, data) responses[name] = { err = err, data = data } end
end
local function frame(method)
  return function(id) return { id = id, method = method } end
end

local notified = t.notified(function()
  process = rpc.start({ 'sh', '-c', script }, {
    name = 'fake',
    on_message = function(msg)
      if msg.id ~= nil then return process:resolve(msg.id, msg.error, msg.result) end
      table.insert(messages, msg)
    end,
    on_exit = function(code) table.insert(exits, code) end,
  })
  process:request(frame('first'), respond('first'))
  vim.wait(2000, function() return responses.first ~= nil end)
  process:request(frame('second'), respond('second'))
  vim.wait(2000, function() return responses.second ~= nil end)
  process:request(frame('third'), respond('third'))
  vim.wait(2000, function() return #exits > 0 end)
end)

t.check('whole lines, without the bad one', messages, { { split = 'line' } })
t.check('responses by id', responses.first, { data = { id = 1, method = 'first' } })
t.check('errors named after the agent', responses.second, { err = 'fake: nope' })
t.check('fails what it never answered, without notifying it again', responses.third, { err = util.closed })
t.check('exits', exits, { 3 })
t.check('notifies', {
  #notified,
  notified[#notified],
}, { 2, 'otto: fake exited: oops' })
t.match('the bad line', notified[1], '^otto: fake: ')

local sent
local after = t.notified(function() sent = process:send({ method = 'late' }) end)
t.check('sends nothing once it exited', { sent, after }, { false, { 'otto: fake is not running' } })
process:request(frame('late'), respond('late'))
t.check('nor requests', responses.late, { err = 'fake is not running' })

t.describe('exits cleanly', function()
  local pending
  local notifications = t.notified(function()
    local quiet = rpc.start({ 'sh', '-c', 'read line' }, { name = 'fake', on_message = function() end })
    quiet:request(frame('first'), function(err) pending = err end)
    vim.wait(2000, function() return pending ~= nil end)
  end)
  t.check('without a notification', notifications, {})
  t.check('which then fails what it never answered', pending, 'fake: exited')
end)

t.describe("a command that doesn't exist", function()
  local ok, err = pcall(rpc.start, { 'otto-no-such-agent' }, { name = 'fake', on_message = function() end })
  t.check('raises', ok, false)
  t.match('named after the agent', err, '^fake: ENOENT')
end)
