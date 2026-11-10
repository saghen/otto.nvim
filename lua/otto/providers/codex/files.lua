-- Codex's session files, in ~/.codex/sessions, of every folder, which are only listed, since they hold items of
-- another kind than the app-server's

local jsonl = require('otto.jsonl')

local M = {}

--- @param file string
--- @param modified integer
--- @return otto.ParsedSession?
function M.parse(file, modified)
  -- closed before returning, since this reads the sessions of every folder
  local handle = io.open(file)
  if handle == nil then return end
  local ok, first = pcall(jsonl.decode, handle:read('*l') or '{}')
  local meta = ok and type(first) == 'table' and type(first.payload) == 'table' and first.payload or {}
  -- sub-agents, like its reviewer, have sessions of their own
  if meta.cwd ~= vim.fn.getcwd() or type(meta.source) ~= 'string' then
    handle:close()
    return
  end
  local saved = { provider = 'codex', id = meta.id, message_count = 0, modified = modified }
  local first_prompt
  local function read(line)
    if line:find('"type":"item_completed"', 1, true) then
      saved.message_count = saved.message_count + 1
      if first_prompt == nil and line:find('"type":"UserMessage"', 1, true) then
        local content = jsonl.decode(line).payload.item.content
        first_prompt = (content[1] or {}).text
      end
    -- of older versions, which don't save items
    elseif line:find('"type":"user_message"', 1, true) or line:find('"type":"agent_message"', 1, true) then
      saved.message_count = saved.message_count + 1
      if first_prompt == nil and line:find('"type":"user_message"', 1, true) then
        first_prompt = jsonl.decode(line).payload.message
      end
    end
  end
  jsonl.each_line(handle, read)
  saved.prompt = first_prompt
  return saved
end

--- @return string[] files of the saved sessions
function M.list() return vim.fn.glob('~/.codex/sessions/**/rollout-*.jsonl', false, true) end

--- Codex keeps the names apart from the sessions
--- @return table<string, string> names by id
function M.names()
  local names = {}
  local handle = io.open(vim.fs.normalize('~/.codex/session_index.jsonl'))
  if handle == nil then return names end
  jsonl.each_line(handle, function(line)
    local entry = jsonl.decode(line)
    if type(entry.id) == 'string' then names[entry.id] = entry.thread_name end
  end)
  return names
end

return M
