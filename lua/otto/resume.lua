-- The current folder's saved sessions, read from the session files of pi (see docs/session-format.md), Claude Code
-- and Codex

local pick = require('otto.pick')

local M = {}

--- @class otto.SavedSession
--- @field id string
--- @field uri string Of the session's buffer, like pi://<id>
--- @field name? string Display name
--- @field title string Display name, or the first prompt
--- @field messages integer
--- @field modified integer Seconds since the epoch

--- @type table<string, { modified: integer, session?: otto.SavedSession }> by file, while unmodified, without the
--- sessions of other folders
local cache = {}

--- @param file string
--- @param modified integer
--- @return otto.SavedSession
local function read_pi(file, modified)
  local id = file:match('_([^/]+)%.jsonl$')
  local session = { id = id, uri = 'pi://' .. id, messages = 0, modified = modified }
  local name, first_prompt
  -- decodes only the lines it needs, since sessions can be large
  for line in io.lines(file) do
    if line:find('"type":"session_info"', 1, true) then
      name = vim.json.decode(line).name
    elseif line:find('"type":"message"', 1, true) then
      session.messages = session.messages + 1
      if first_prompt == nil and line:find('"role":"user"', 1, true) then
        local content = vim.json.decode(line).message.content
        first_prompt = type(content) == 'string' and content or (content[1] or {}).text
      end
    end
  end
  session.name = name
  session.title = name or (first_prompt and vim.trim(first_prompt):gsub('%s+', ' ')) or id
  return session
end

--- @param file string
--- @param modified integer
--- @return otto.SavedSession
function M.read_claude(file, modified)
  local id = vim.fs.basename(file):gsub('%.jsonl$', '')
  local session = { id = id, uri = 'claude://' .. id, messages = 0, modified = modified }
  local name, first_prompt
  for line in io.lines(file) do
    if line:find('"type":"custom-title"', 1, true) then
      name = vim.json.decode(line).customTitle
    elseif line:find('"type":"ai-title"', 1, true) then
      name = name or vim.json.decode(line).aiTitle
    elseif line:find('"type":"user"', 1, true) or line:find('"type":"assistant"', 1, true) then
      session.messages = session.messages + 1
      local content = first_prompt == nil
        and line:find('"type":"user"', 1, true)
        and vim.json.decode(line).message.content
      -- tool results and the output of local commands aren't prompts
      if type(content) == 'string' and not vim.startswith(content, '<') then first_prompt = content end
    end
  end
  session.name = name
  session.title = name or (first_prompt and vim.trim(first_prompt):gsub('%s+', ' ')) or id
  return session
end

--- @return table<string, string> names of Codex's sessions by id
local function codex_names()
  local names = {}
  local index = vim.fs.normalize('~/.codex/session_index.jsonl')
  if vim.uv.fs_stat(index) == nil then return names end
  for line in io.lines(index) do
    local entry = vim.json.decode(line)
    names[entry.id] = entry.thread_name
  end
  return names
end

--- @param file string
--- @param modified integer
--- @return otto.SavedSession?
local function read_codex(file, modified)
  local lines = io.lines(file)
  local meta = vim.json.decode(lines() or '{}').payload or {}
  -- sub-agents, like its reviewer, have sessions of their own
  if meta.cwd ~= vim.fn.getcwd() or type(meta.source) ~= 'string' then return end
  local session = { id = meta.id, uri = 'codex://' .. meta.id, messages = 0, modified = modified }
  local first_prompt
  for line in lines do
    if line:find('"type":"item_completed"', 1, true) then
      session.messages = session.messages + 1
      if first_prompt == nil and line:find('"type":"UserMessage"', 1, true) then
        local content = vim.json.decode(line).payload.item.content
        first_prompt = (content[1] or {}).text
      end
    end
  end
  session.title = first_prompt and vim.trim(first_prompt):gsub('%s+', ' ') or meta.id
  return session
end

--- Newest first
--- @return otto.SavedSession[]
function M.list()
  local sessions = {}
  local function add(file, read)
    local stat = vim.uv.fs_stat(file)
    if stat == nil or stat.type ~= 'file' then return end
    local modified = stat.mtime.sec
    if cache[file] == nil or cache[file].modified ~= modified then
      cache[file] = { modified = modified, session = read(file, modified) }
    end
    if cache[file].session ~= nil then table.insert(sessions, cache[file].session) end
  end
  -- Read Pi paths literally: configured roots and project names can contain glob characters.
  local dir = require('otto.config').session_dir()
  local scan = vim.uv.fs_scandir(dir)
  if scan ~= nil then
    while true do
      local name = vim.uv.fs_scandir_next(scan)
      if name == nil then break end
      if name:sub(-6) == '.jsonl' then add(vim.fs.joinpath(dir, name), read_pi) end
    end
  end
  local globs = {
    [vim.fs.dirname(require('otto.claude').session_file('')) .. '/*.jsonl'] = M.read_claude,
    ['~/.codex/sessions/**/rollout-*.jsonl'] = read_codex,
  }
  for glob, read in pairs(globs) do
    for _, file in ipairs(vim.fn.glob(glob, false, true)) do
      add(file, read)
    end
  end
  -- Codex keeps the names apart from the sessions
  local names = codex_names()
  for _, session in ipairs(sessions) do
    if names[session.id] ~= nil then
      session.name = names[session.id]
      session.title = session.name
    end
  end
  table.sort(sessions, function(a, b) return a.modified > b.modified end)
  return sessions
end

local units = { { 'mo', 30 * 86400 }, { 'w', 7 * 86400 }, { 'd', 86400 }, { 'h', 3600 }, { 'm', 60 } }

--- @param seconds integer
--- @return string like "4d"
local function age(seconds)
  for _, unit in ipairs(units) do
    if seconds >= unit[2] then return math.floor(seconds / unit[2]) .. unit[1] end
  end
  return 'now'
end

--- @param session otto.SavedSession
--- @return minibuffer.util.HighlightLine
local function format(session)
  -- the ids of Claude Code and Codex are UUIDs, which only need their end to be told apart, since Codex's start with
  -- when they were created
  local backend = session.uri:match('^(%a+)://')
  local id = backend == 'pi' and session.id or backend .. ' ' .. session.id:sub(-8)
  local details = ('%s  %d %4s'):format(id, session.messages, age(os.time() - session.modified))
  local width = vim.o.columns - 2 - vim.api.nvim_strwidth(details) -- the picker's margins
  return { { text = pick.column(session.title, width) .. ' ' }, { text = details, hl = 'Comment' } }
end

--- Picks a session, and opens it
function M.pick()
  local opts = {
    prompt = 'Resume session: ',
    text = function(session) return session.title .. ' ' .. session.id end,
    format = format,
  }
  pick.pick(M.list(), opts, function(session)
    if session ~= nil then vim.cmd.edit(session.uri) end
  end)
end

return M
