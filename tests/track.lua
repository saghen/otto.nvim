-- Otto's side of tracking, with a fake agent that runs a script of tool calls. otto.rs runs it in headless Neovim:
--   nvim --headless --clean -l tests/track.lua <otto-track> <blink.lib> <workspace>

local bin, blink, workspace = arg[1], arg[2], arg[3]
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.abspath(debug.getinfo(1, 'S').source:sub(2))))
vim.opt.runtimepath:prepend(blink)
vim.opt.runtimepath:prepend(root)
vim.env.XDG_STATE_HOME = workspace .. '/../state'
vim.cmd.cd(workspace)
vim.o.autoread = true

local event = require('otto.event')
local changes = require('otto.ui.changes')
local providers = require('otto.providers')
local rpc = require('otto.providers.rpc')
local sessions = require('otto.session')
local track = require('otto.track')
track.bin = bin
require('otto.config').set({ track = true })

local failed = 0
local function check(name, got, want)
  if vim.deep_equal(got, want) then return end
  failed = failed + 1
  io.stderr:write(('%s: got %s, want %s\n'):format(name, vim.inspect(got), vim.inspect(want)))
end

-- Messages of the script, as tool calls and their results
providers.providers.fake = {
  name = 'fake',
  icon = 'f ',
  new_id = function() return 'one' end,
  files = function() return {} end,
  open = function(_, opts)
    local agent = {}
    local function on_message(msg)
      local at = event.now()
      if msg.type == 'call' then
        local args = { path = msg.path, command = msg.command, content = msg.content }
        opts.on_log({ type = 'tool_call', at = at, id = msg.id, tool = msg.tool, args = args })
      elseif msg.type == 'result' then
        opts.on_log({ type = 'tool_result', at = at, id = msg.id, ok = true })
      elseif msg.type == 'done' then
        opts.on_log({ type = 'turn_end', at = at, aborted = false, worked = true, started = at })
        opts.on_state({ status = false })
      end
    end
    agent.rpc = rpc.start_agent(opts.config, {}, { name = 'fake', on_message = on_message })
    function agent.replay() end
    function agent.commands() return {} end
    function agent.prompt(_, text)
      opts.on_state({ status = 'working' })
      agent.rpc:send({ text = text })
    end
    function agent.close() agent.rpc:close() end
    return agent
  end,
}

-- The agent's own write, then two commands at once, which each change a file, then an edit in a process of its own,
-- like Codex's, then a command that makes a file to move in the next, and one that the agent removes after, like
-- Claude Code's sandbox, then two writes at once, like Claude Code's, which write a temp file and rename it, while a
-- subagent runs
local script = [[
read prompt
echo '{"type":"call","id":"1","tool":"write","path":"a.txt","content":"hello"}'
echo hello > a.txt
echo '{"type":"result","id":"1"}'
echo '{"type":"call","id":"2","tool":"bash","command":"sed -i s/hello/bye/ a.txt"}'
echo '{"type":"call","id":"3","tool":"bash","command":"sleep 0.2; touch b.txt"}'
sh -c 'sleep 0.2; touch b.txt' & sed -i s/hello/bye/ a.txt; wait
echo '{"type":"result","id":"2"}'
echo '{"type":"result","id":"3"}'
echo '{"type":"call","id":"4","tool":"edit","path":"b.txt"}'
sh -c 'echo edited > b.txt'
echo '{"type":"result","id":"4"}'
echo '{"type":"call","id":"5","tool":"bash","command":"echo n > new.txt"}'
sh -c 'echo n > new.txt; : > .sandboxed'
echo '{"type":"result","id":"5"}'
unlink .sandboxed
echo '{"type":"call","id":"6","tool":"bash","command":"mv new.txt moved.txt"}'
mv new.txt moved.txt
echo '{"type":"result","id":"6"}'
echo '{"type":"call","id":"9","tool":"agent"}'
echo '{"type":"call","id":"7","tool":"write","path":"WORKSPACE/c.txt","content":"c"}'
echo '{"type":"call","id":"8","tool":"write","path":"d.txt","content":"d"}'
echo c > c.txt.tmp.1
mv c.txt.tmp.1 c.txt
echo '{"type":"result","id":"7"}'
echo '{"type":"result","id":"8"}'
echo '{"type":"result","id":"9"}'
echo '{"type":"done"}'
read wait
]]
vim.fn.writefile({ 'outside' }, 'a.txt')
vim.cmd.edit('a.txt')
local bufnr = vim.api.nvim_get_current_buf()

-- with the path that Claude Code gives
script = script:gsub('WORKSPACE', workspace)
local session = sessions.open('fake://one', { config = { cmd = { 'sh', '-c', script }, args = {}, env = {} } })
local settled = false
session:subscribe({ on_state = function(patch) settled = settled or patch.status == false end })
session.agent:prompt('go', 'steer')
-- which changes nothing, since changes are of the agent's folder
vim.cmd.cd('/')
if not vim.wait(10000, function() return settled end) then
  io.stderr:write('the agent never finished: ' .. tostring(session.agent.rpc.stderr) .. '\n')
  os.exit(1)
end

local summary = vim.tbl_map(
  function(change) return { change.op, change.path, change.call, change.from and 'from ' .. change.from or nil } end,
  vim.tbl_filter(
    function(change) return not change.path:match('^sed') and change.call and change.call < '5' end,
    session.tracked.changes
  )
)
table.sort(summary, function(a, b) return a[2] .. a[1] < b[2] .. b[1] end)
-- sed's temp file, whose name is random
local sed_temp = vim.iter(session.tracked.changes):find(function(change) return change.path:match('^sed') end)
check('changes', summary, {
  { 'rename', 'a.txt', '2', 'from ' .. (sed_temp and sed_temp.path or '?') },
  { 'write', 'a.txt', '1' },
  { 'write', 'b.txt', '3' },
  { 'write', 'b.txt', '4' },
})
local own_write = vim.iter(session.tracked.changes):find(function(change) return change.call == '1' end)
check('outside', own_write and session.tracked:blob(own_write.before), 'outside\n')
local temp = vim.iter(session.tracked.changes):find(function(change) return change.path == 'c.txt.tmp.1' end)
check('temp file', temp and temp.call, '7')

-- With the write's, since its result has no diff
local edits = changes.quickfix_edits(session.events, changes.changed_files(session.tracked, session.tracked.changes))
local function relative(filename) return vim.fs.relpath(workspace, filename) or filename end
check('quickfix', vim.tbl_map(function(edit) return { relative(edit.filename), edit.lnum, edit.text } end, edits), {
  { 'a.txt', 1, 'write a.txt  +1 -1' },
  { 'a.txt', 1, '$ sed -i s/hello/bye/ a.txt  +1 -1' },
  { 'b.txt', 1, '$ sleep 0.2; touch b.txt  +0 -0' },
  { 'b.txt', 1, 'edit b.txt  +1 -0' },
  { 'new.txt', 1, '$ echo n > new.txt  +1 -0' },
  { 'moved.txt', 1, '$ mv new.txt moved.txt  +0 -0  from new.txt' },
  { 'c.txt', 1, 'write ' .. workspace .. '/c.txt  +1 -0' },
})

-- The session's changes as one diff, which nets out the temp file, and opens the file at the line
check('diff', changes.diff(session.tracked, session.tracked.changes), {
  '--- a/a.txt',
  '+++ b/a.txt',
  '@@ -1 +1 @@',
  '-outside',
  '+bye',
  '--- /dev/null',
  '+++ b/b.txt',
  '@@ -0,0 +1 @@',
  '+edited',
  '--- /dev/null',
  '+++ b/moved.txt',
  '@@ -0,0 +1 @@',
  '+n',
  '--- /dev/null',
  '+++ b/c.txt',
  '@@ -0,0 +1 @@',
  '+c',
})
local call_changes = vim.tbl_filter(function(c) return c.call == '2' end, session.tracked.changes)
check('call diff', changes.diff(session.tracked, call_changes), {
  '--- a/a.txt',
  '+++ b/a.txt',
  '@@ -1 +1 @@',
  '-hello',
  '+bye',
})
changes.open(session, session.tracked.changes, 'test')
vim.api.nvim_win_set_cursor(0, { 9, 0 })
vim.api.nvim_feedkeys(vim.keycode('<CR>'), 'x', false)
check('opened', { vim.fn.expand('%:t'), vim.fn.line('.') }, { 'b.txt', 1 })
vim.cmd.buffer(bufnr)

-- From the session's buffer, on the command's block
vim.api.nvim_create_autocmd('BufReadCmd', {
  pattern = 'fake://*',
  callback = function(ev) require('otto.view').load(ev.buf) end,
})
vim.cmd.edit('fake://one')
local view = require('otto.buffers').current()
local row = vim
  .iter(ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)))
  :find(function(_, line) return line:find('sed %-i') end)
vim.api.nvim_win_set_cursor(0, { row, 0 })
changes.open_at_cursor(view)
check('opened at the call', vim.api.nvim_buf_get_lines(0, 0, -1, false)[4], '-hello')
vim.cmd.close()
vim.cmd.buffer(bufnr)

-- Moves that come back, and Vim's backups, which move the file away to write it anew
local function net(log)
  return vim.tbl_map(function(n) return { n.path, n.before, n.after, n.from } end, track.net(log))
end
check(
  'moved back',
  net({
    { op = 'rename', from = 'f', path = 'b', after = 'h', at = 1 },
    { op = 'rename', from = 'b', path = 'f', after = 'h', at = 2 },
  }),
  {}
)
check(
  'backup',
  net({
    { op = 'rename', from = 'f', path = 'f~', after = 'h0', at = 1 },
    { op = 'write', path = 'f', after = 'h1', at = 2 },
    { op = 'remove', path = 'f~', before = 'h0', at = 3 },
  }),
  { { 'f', 'h0', 'h1' } }
)
check('moved', net({ { op = 'rename', from = 'f', path = 'g', after = 'h', at = 1 } }), { { 'g', 'h', 'h', 'f' } })
-- over a file, which changes it, rather than moves to it
check('replaced', net({ { op = 'rename', from = 'g', path = 'f', before = 'hf', after = 'hg', at = 1 } }), {
  { 'g', 'hg' },
  { 'f', 'hf', 'hg' },
})

-- the command that's longest, when one's in another, of the calls running as the agent logs them
local commands = { short = 'prettier --write src', long = 'prettier --write src/a.ts', other = 'ls' }
for _, id in ipairs({ 'short', 'long', 'other' }) do
  session:on_log({ type = 'tool_call', at = event.now(), id = id, tool = 'bash', args = { command = commands[id] } })
end
local argv = { 'bash', '-c', 'prettier --write src/a.ts' }
local change = { pid = -1, path = 'src/a.ts', argvs = { argv } }
check('longest command', session.tracked:call_of(change, session:calls()), 'long')
for _, id in ipairs({ 'short', 'long', 'other' }) do
  session:on_log({ type = 'tool_result', at = event.now(), id = id, ok = true })
end

vim.cmd.checktime()
check('reloaded', vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), { 'bye' })

session:close()
os.exit(failed == 0 and 0 or 1)
