-- Claude Code's session files, in ~/.claude/projects/<folder>

local decode = require('otto.providers.claude.decode')
local jsonl = require('otto.jsonl')

local M = {}

--- @param id string
--- @return string
function M.session_file(id)
  -- like Claude Code, which replaces each UTF-16 unit, so characters past U+FFFF take two
  local folder = vim.fn.getcwd():gsub('[%z\1-\127\194-\244][\128-\191]*', function(char)
    if char:match('^%w$') then return char end
    return #char == 4 and '--' or '-'
  end)
  return ('%s/.claude/projects/%s/%s.jsonl'):format(vim.env.HOME, folder, id)
end

--- @param file string
--- @param modified integer
--- @return otto.ParsedSession?
function M.parse(file, modified)
  local handle = io.open(file)
  if handle == nil then return end
  local id = vim.fs.basename(file):gsub('%.jsonl$', '')
  local saved = { provider = 'claude', id = id, message_count = 0, modified = modified }
  local custom, ai, first_prompt
  local function read(line)
    if line:find('"type":"custom-title"', 1, true) then
      custom = jsonl.decode(line).customTitle
    elseif line:find('"type":"ai-title"', 1, true) then
      ai = jsonl.decode(line).aiTitle
    elseif line:find('"type":"user"', 1, true) or line:find('"type":"assistant"', 1, true) then
      saved.message_count = saved.message_count + 1
      local content = first_prompt == nil and line:find('"type":"user"', 1, true) and jsonl.decode(line).message.content
      -- tool results and the output of local commands aren't prompts
      if type(content) == 'string' then first_prompt = decode.command_prompt(content) or content end
      if first_prompt and decode.is_tagged(first_prompt) then first_prompt = nil end
    end
  end
  jsonl.each_line(handle, read)
  saved.name = custom or ai
  saved.prompt = first_prompt
  return saved
end

--- @return string[] files of the saved sessions
function M.list() return vim.fn.glob(vim.fs.dirname(M.session_file('')) .. '/*.jsonl', false, true) end

return M
