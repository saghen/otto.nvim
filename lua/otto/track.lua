-- Tracks what agents change in the workspace, including through their commands, by running them under otto-track,
-- which records each change in a store that every agent of the workspace shares. Opt in with `track = true`

local jsonl = require('otto.jsonl')
local util = require('otto.util')

--- @class otto.Change One line of the store's log, by an agent
--- @field at integer Milliseconds since the epoch
--- @field op 'write' | 'rename' | 'remove'
--- @field path string Relative to the workspace
--- @field from? string Of renames
--- @field before? string Hash of what the path held before, if anything
--- @field after? string Hash of what it holds, if a file, unless removed
--- @field pid integer
--- @field cmd? string Of the process that made it
--- @field argvs? string[][] Command lines of the processes from the agent's child down to the one that made it, unless
--- the agent made it itself
--- @field call? string Id of the tool call that made it, see `otto.TrackedAgent:call_of`

--- @class otto.TrackedAgent
--- @field name string
--- @field cwd string Its workspace, which changes' paths are relative to
--- @field pid? integer Once its wrapper started it
--- @field store otto.Store
--- @field calls fun(): otto.RunningCall[] That its agent runs, which its changes are attributed to, see `call_of`
--- @field changes otto.Change[] What its agent changed, in order
--- @field missing table<string, true> Blobs that are gone from the store, which it warned of
local Tracked = {}
Tracked.__index = Tracked

--- @class otto.Store The log, as far as it's been read
--- @field dir string
--- @field offset integer Bytes of whole lines read
--- @field last table<string, string | false> Hash of each path, or false once removed
--- @field agents table<string, otto.TrackedAgent> By name
--- @field watcher? uv.uv_fs_event_t
local Store = {}
Store.__index = Store

local M = {}

local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2))))
M.bin = root .. '/target/release/otto-track'
--- Of otto-track's CLI and log, which a build from before an update may not speak, see `PROTOCOL` in src/main.rs
M.protocol = 1

--- @type { bin: string, mtime: integer, ok: boolean }? Of the last build that was asked, until it's rebuilt
local checked

--- @return boolean whether the built otto-track speaks this otto's protocol
local function current_build()
  local stat = vim.uv.fs_stat(M.bin)
  local mtime = stat and stat.mtime.sec or 0
  if checked == nil or checked.bin ~= M.bin or checked.mtime ~= mtime then
    local ok, result = pcall(function() return vim.system({ M.bin, '--protocol' }, { text = true }):wait() end)
    checked = { bin = M.bin, mtime = mtime, ok = ok and vim.trim(result.stdout or '') == tostring(M.protocol) }
  end
  return checked.ok
end

--- @type table<string, otto.Store> By directory
local stores = {}

--- Of the workspace, outside it
--- @param cwd string
--- @return string
function M.store_dir(cwd) return vim.fn.stdpath('state') .. '/otto/track/' .. vim.fn.sha256(cwd):sub(1, 16) end

--- @param dir string
--- @return otto.Store
local function open_store(dir)
  if stores[dir] then return stores[dir] end
  vim.fn.mkdir(dir, 'p')
  local store = setmetatable({ dir = dir, offset = 0, last = {}, agents = {} }, Store)
  stores[dir] = store
  -- which has what the paths held before this session's agents
  store:catch_up()
  return store
end

--- @param line table
function Store:apply(line)
  local agent = line.agent and self.agents[line.agent]
  if line.op == 'start' then
    if agent then agent.pid = line.pid end
    return
  end
  local path = line.path
  if path == nil then return end
  -- unless it says, when its wrapper claims a change that another caught up on as one from outside. Then it's the hash
  -- before that change, or '' when there was nothing, since a nil wouldn't say so, see `Before` in log.rs
  local before = line.before or self.last[path] or nil
  if before == '' then before = nil end
  if line.op == 'write' then
    self.last[path] = line.hash
  elseif line.op == 'remove' then
    self.last[path] = false
  elseif line.op == 'rename' and line.hash then
    self.last[line.from] = false
    self.last[path] = line.hash
  elseif line.op == 'rename' then
    -- a directory, which moves everything under it
    local prefix = line.from .. '/'
    for key, hash in pairs(vim.deepcopy(self.last)) do
      if vim.startswith(key, prefix) then
        self.last[key] = false
        self.last[path .. '/' .. key:sub(#prefix + 1)] = hash
      end
    end
  end
  if agent == nil then return end
  agent:add({
    at = line.at,
    op = line.op,
    path = path,
    from = line.from,
    before = before,
    after = line.hash,
    pid = line.pid,
    cmd = line.cmd,
    argvs = line.commands,
  })
end

--- Reads what's been appended since, which waits for nothing, so that changes arrive before the tool results that
--- follow them
function Store:catch_up()
  local lines
  lines, self.offset = jsonl.read_appended(self.dir .. '/log.jsonl', self.offset)
  for _, line in ipairs(lines) do
    local ok, decoded = pcall(jsonl.decode, line)
    if ok and type(decoded) == 'table' then self:apply(decoded) end
  end
end

function Store:watch()
  if self.watcher then return end
  local log = self.dir .. '/log.jsonl'
  -- so that there's a file to watch
  local fd = vim.uv.fs_open(log, 'a', 420)
  if fd then vim.uv.fs_close(fd) end
  self.watcher = vim.uv.new_fs_event()
  local ok, err = self.watcher:start(log, {}, vim.schedule_wrap(function() self:catch_up() end))
  -- then changes only arrive with the tool results and turns that catch up on them
  if not ok then util.notify('track: not watching ' .. log .. ': ' .. tostring(err), vim.log.levels.WARN) end
end

local warned = false
local agent_count = 0

--- Whether the kernel lets otto-track make its namespaces, which Ubuntu restricts by default
--- @return boolean
local function namespaces_off()
  local function sysctl(name)
    local file = io.open('/proc/sys/' .. name)
    if file == nil then return nil end
    local value = vim.trim(file:read('*a'))
    file:close()
    return value
  end
  return sysctl('kernel/unprivileged_userns_clone') == '0'
    or sysctl('user/max_user_namespaces') == '0'
    or sysctl('kernel/apparmor_restrict_unprivileged_userns') == '1'
end

--- Starts tracking an agent of the current directory, whose command `wrap` puts under otto-track, or nothing when it
--- can't be tracked
--- @param provider string
--- @param calls fun(): otto.RunningCall[] That the agent runs, those in the background first
--- @return otto.TrackedAgent?
function M.start(provider, calls)
  local cwd = vim.fn.getcwd()
  local dir = M.store_dir(cwd)
  local message = vim.fn.has('linux') == 0 and 'only on Linux'
    or vim.fn.executable(M.bin) == 0 and 'build otto-track with `cargo build --release`'
    or not current_build() and 'rebuild otto-track with `cargo build --release`, since it is older than this otto'
    or namespaces_off() and 'needs unprivileged user namespaces, which are off'
    -- which would record its own writes, like when Neovim runs in ~
    or vim.fs.relpath(cwd, dir) and 'not of a folder that has its store, ' .. dir
  if message then
    if not warned then util.notify('track: ' .. message, vim.log.levels.WARN) end
    warned = true
    return nil
  end
  local store = open_store(dir)
  agent_count = agent_count + 1
  local name = ('%s-%d-%d'):format(provider, vim.fn.getpid(), agent_count)
  local tracked =
    setmetatable({ name = name, cwd = cwd, store = store, calls = calls, changes = {}, missing = {} }, Tracked)
  store.agents[name] = tracked
  store:watch()
  return tracked
end

--- @param cmd string[]
--- @param on_host string[] See `otto.Config`
--- @return string[]
function Tracked:wrap(cmd, on_host)
  local wrapped = { M.bin, 'run', '--store', self.store.dir, '--agent', self.name }
  for _, name in ipairs(on_host) do
    vim.list_extend(wrapped, { '--host', name })
  end
  table.insert(wrapped, '--')
  return vim.list_extend(wrapped, cmd)
end

function Tracked:stop()
  local store = self.store
  store.agents[self.name] = nil
  if next(store.agents) == nil and store.watcher then
    store.watcher:close()
    store.watcher = nil
  end
end

function Tracked:catch_up() self.store:catch_up() end

--- Without quotes, which agents escape when they wrap commands, like Claude Code's `eval '...'`
--- @param text string
--- @return string
local function bare(text) return (text:gsub('[\'"\\]', '')) end

--- The command whose command line made the change, the longest when one's in another, like `prettier src` and
--- `prettier src/a.ts`, or else the last
--- @param change otto.Change
--- @param bash_calls otto.RunningCall[]
--- @return otto.RunningCall
local function bash_call_of(change, bash_calls)
  local lines = vim.tbl_map(function(argv) return bare(table.concat(argv, ' ')) end, change.argvs or {})
  local best, length = bash_calls[#bash_calls], -1
  for _, call in ipairs(bash_calls) do
    local command = type(call.args.command) == 'string' and bare(call.args.command)
    if
      command
      and #command > length
      and vim.iter(lines):any(function(line) return line:find(command, 1, true) ~= nil end)
    then
      best, length = call, #command
    end
  end
  return best
end

--- The running call that made a change, by the first rule that finds one. Codex edits in a process of its own, so who
--- made the change doesn't rule out edits
--- @param change otto.Change
--- @param calls otto.RunningCall[] Those in the background first, so that the turn's take precedence
--- @return string? id
function Tracked:call_of(change, calls)
  local own = change.pid == self.pid
  local edits, bash_calls, agent = {}, {}, nil
  for _, call in ipairs(calls) do
    if call.tool == 'edit' or call.tool == 'write' then
      local path = call.args.path
      -- of the agent's folder, not the current window's
      path = type(path) == 'string'
        and vim.fs.relpath(self.cwd, vim.startswith(path, '/') and path or self.cwd .. '/' .. path)
      if path == change.path then return call.id end
      table.insert(edits, call)
    end
    if call.tool == 'bash' then table.insert(bash_calls, call) end
    if call.tool == 'agent' then agent = call end
  end
  -- the only edit, which the agent made itself, like through a temp file
  if #edits == 1 and (own or #bash_calls == 0) then return edits[1].id end
  -- one of several edits by the agent, which only its rename tells apart
  if own and #edits > 1 then return nil end
  -- a command, since the agent didn't make it itself
  if not own and #bash_calls > 0 then return bash_call_of(change, bash_calls).id end
  return agent and agent.id
end

--- Keeps a change of the agent, with the call that made it
--- @param change otto.Change
function Tracked:add(change)
  change.call = self:call_of(change, self.calls())
  table.insert(self.changes, change)
  -- what became it, like the temp file of an edit, which only its rename tells apart when several edits run
  if change.from and change.call then
    for _, earlier in ipairs(self.changes) do
      if earlier.path == change.from and earlier.call == nil then earlier.call = change.call end
    end
  end
end

--- @param hash? string
--- @return string? contents Nothing without a hash, or when the store lost it, which it warns of once
function Tracked:blob(hash)
  if hash == nil then return nil end
  local fd = vim.uv.fs_open(self.store.dir .. '/blobs/' .. hash, 'r', 438)
  if fd == nil then
    if not self.missing[hash] then util.notify('track: missing blob ' .. hash, vim.log.levels.WARN) end
    self.missing[hash] = true
    return nil
  end
  local data = vim.uv.fs_read(fd, vim.uv.fs_fstat(fd).size, 0)
  vim.uv.fs_close(fd)
  return data
end

--- @class otto.NetChange What changes did to a file, from before the first to after the last
--- @field path string
--- @field from? string Of the file that moved there
--- @field before? string Hash, none when it was created
--- @field after? string Hash, none once removed
--- @field at integer Of the first change
--- @field cmd? string Of the first change

--- What the changes did to each file, in the order they first changed. Files that they created and that are gone
--- again do nothing, like temp files to save through, or the files that Claude Code's sandbox mounts over
--- @param changes otto.Change[]
--- @return otto.NetChange[]
function M.net(changes)
  local files, order = {}, {}
  local function file(path, change, before)
    if files[path] == nil then
      files[path] = { path = path, before = before, at = change.at, cmd = change.cmd }
      table.insert(order, files[path])
    end
    return files[path]
  end
  for _, change in ipairs(changes) do
    if change.from then
      local existing = files[change.path]
      -- new to the changes, or moved away by them
      local vacant = existing == nil and change.before == nil
        or existing ~= nil and existing.before == nil and existing.after == nil
      -- what it held, if it's new to the changes
      local source = file(change.from, change, change.after)
      local target = file(change.path, change, change.before)
      -- moved, rather than removed and created, so the target holds what the source did
      if source.before and vacant then
        target.before = source.before
        target.from = source.from or change.from
        source.before = nil
      end
      -- moved back to where it started, which isn't a move
      if target.from == target.path then target.from = nil end
      source.after = nil
      target.after = change.after
    else
      file(change.path, change, change.before).after = change.after
    end
  end
  -- moved away to make room for a new file, like Vim's backups, whose before it is
  for _, net in ipairs(order) do
    local back = net.after == nil and net.from and files[net.from]
    if back and back.before == nil and back.after ~= nil then
      back.before = net.before
      net.before = nil
      net.from = nil
    end
  end
  return vim.tbl_filter(
    function(net) return (net.before ~= net.after or net.from ~= nil) and (net.before or net.after) ~= nil end,
    order
  )
end

--- What the file held before and after the change, as far as the store has it
--- @param net otto.NetChange
--- @return string before
--- @return string after
function Tracked:contents(net) return self:blob(net.before) or '', self:blob(net.after) or '' end

return M
