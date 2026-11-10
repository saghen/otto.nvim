-- track.lua without otto-track: which call made a change, and blobs that the store lost. tests/track.lua runs the
-- rest with otto-track

local t = ...
local track = require('otto.track')

--- @param protocol string What the fake otto-track says it speaks
--- @return string path of it
local function fake_bin(protocol)
  local path = vim.fn.tempname()
  assert(vim.fn.writefile({ '#!/bin/sh', 'echo ' .. protocol }, path) == 0)
  vim.fn.setfperm(path, 'rwx------')
  return path
end

local bin = track.bin
track.bin = fake_bin('0')
local stale
local warnings = t.notified(function()
  stale = track.start('fake', function() return {} end)
end)
track.bin = fake_bin(tostring(track.protocol))
local tracked = track.start('fake', function() return {} end)
track.bin = bin
if tracked == nil then return t.skip('tracking needs Linux and user namespaces') end
t.check('not with an old build', stale, nil)
t.match('which says to rebuild', warnings[1] or '', 'rebuild otto%-track')
if tracked == nil then return t.skip('tracking needs Linux and user namespaces') end
tracked.pid = 100
local cwd = tracked.cwd
local changes = tracked.changes

--- @param id string
--- @param tool string
--- @param args table
--- @return otto.RunningCall
local function call(id, tool, args) return { id = id, tool = tool, args = args } end

t.describe('call_of', function()
  local own = { pid = 100, path = 'a.lua' }
  local edit_a = call('ea', 'edit', { path = 'a.lua' })
  local edit_b = call('eb', 'write', { path = cwd .. '/b.lua' })
  local make = call('make', 'bash', { command = 'make' })
  local agent = call('agent', 'agent', { description = 'x' })
  t.check('an edit of the path', tracked:call_of(own, { make, edit_b, edit_a }), 'ea')
  t.check('absolute', tracked:call_of({ pid = 1, path = 'b.lua' }, { edit_a, edit_b }), 'eb')
  t.check('the only edit, by the agent', tracked:call_of({ pid = 100, path = 'tmp' }, { make, edit_a }), 'ea')
  t.check('none of several', tracked:call_of({ pid = 100, path = 'tmp' }, { edit_a, edit_b }), nil)
  t.check('the only edit, without commands', tracked:call_of({ pid = 1, path = 'tmp' }, { agent, edit_a }), 'ea')
  local short = call('short', 'bash', { command = "prettier 'src'" })
  local long = call('long', 'bash', { command = 'prettier src/a.ts' })
  local change = { pid = 1, path = 'src/a.ts', argvs = { { 'sh', '-c', 'prettier src/a.ts' } } }
  t.check('the longest command', tracked:call_of(change, { short, long, make }), 'long')
  t.check('or the last', tracked:call_of({ pid = 1, path = 'x' }, { make, short }), 'short')
  t.check('else a subagent', tracked:call_of({ pid = 100, path = 'x' }, { make, agent }), 'agent')
  t.check('or none', tracked:call_of({ pid = 100, path = 'x' }, {}), nil)
end)

t.describe('missing blobs', function()
  local blob
  local notified = t.notified(function()
    blob = tracked:blob('gone')
    tracked:blob('gone')
  end)
  t.check('read as nothing', blob, nil)
  t.check('warned once', notified, { 'otto: track: missing blob gone' })
  t.check('nothing without a hash', t.notified(function() tracked:blob(nil) end), {})
end)

t.describe('the store', function()
  local log = tracked.store.dir .. '/log.jsonl'
  --- @param text string
  local function append(text)
    local file = assert(io.open(log, 'a'))
    file:write(text)
    file:close()
    tracked:catch_up()
  end
  --- @param line table
  --- @return string
  local function encode(line)
    return vim.json.encode(vim.tbl_extend('force', { agent = tracked.name, pid = 7, at = 1 }, line)) .. '\n'
  end

  append(encode({ op = 'start', pid = 42 }))
  t.check('the pid of the agent', tracked.pid, 42)
  append(encode({ op = 'write', path = 'd/f', hash = 'h1', before = '' }))
  t.check('a write, without a hash before it', { changes[#changes].path, changes[#changes].before }, { 'd/f', nil })
  append(encode({ op = 'rename', from = 'd', path = 'e' }))
  t.check('a folder that moved', { changes[#changes].op, changes[#changes].path }, { 'rename', 'e' })
  append(encode({ op = 'write', path = 'e/f', hash = 'h2' }))
  t.check('its files move too', changes[#changes].before, 'h1')
  append(encode({ op = 'remove', path = 'd/f' }))
  t.check('and are gone from where they were', changes[#changes].before, nil)

  local count = #changes
  local line = encode({ op = 'write', path = 'g', hash = 'h3', argvs = {} })
  append(line:sub(1, 10))
  t.check('waits for the whole line', #changes, count)
  append(line:sub(11))
  t.check('then reads it once', { #changes, changes[#changes].path }, { count + 1, 'g' })
  append(encode({ op = 'write', path = 'h', hash = 'h4', agent = 'another' }))
  t.check("not another agent's", #changes, count + 1)
end)

tracked:stop()
