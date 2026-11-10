-- pi's session files, in ~/.pi/agent/sessions/<folder>

local event = require('otto.event')
local jsonl = require('otto.jsonl')

local M = {}

--- @return string folder of the current folder's sessions
local function folder()
  return ('%s/.pi/agent/sessions/--%s--'):format(vim.env.HOME, (vim.fn.getcwd():sub(2):gsub('[/\\:]', '-')))
end

--- @param id string
--- @return string? path of the session's file
function M.session_file(id)
  -- files are named <time>_<id>.jsonl, and `*_fix.jsonl` would match the id auth_fix too
  return vim
    .iter(vim.fn.glob(('%s/*_%s.jsonl'):format(folder(), id), false, true))
    :find(function(file) return vim.fs.basename(file):match('^[^_]*_(.+)%.jsonl$') == id end)
end

--- @param file string
--- @param modified integer
--- @return otto.ParsedSession?
function M.parse(file, modified)
  local handle = io.open(file)
  if handle == nil then return end
  local id = file:match('_([^/]+)%.jsonl$')
  local saved = { provider = 'pi', id = id, message_count = 0, modified = modified }
  local first_prompt
  -- decodes only the lines it needs, since sessions can be large
  local function read(line)
    if line:find('"type":"session_info"', 1, true) then
      saved.name = jsonl.decode(line).name
    elseif line:find('"type":"message"', 1, true) then
      saved.message_count = saved.message_count + 1
      if first_prompt == nil and line:find('"role":"user"', 1, true) then
        -- not prompts of only images
        local text = event.text_of(jsonl.decode(line).message.content)
        if vim.trim(text) ~= '' then first_prompt = text end
      end
    end
  end
  jsonl.each_line(handle, read)
  saved.prompt = first_prompt
  return saved
end

--- @return string[] files of the saved sessions
function M.list() return vim.fn.glob(folder() .. '/*.jsonl', false, true) end

return M
