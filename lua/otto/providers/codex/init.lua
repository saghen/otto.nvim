-- Codex: `codex app-server`, JSON-RPC over stdio. Turns are made of items, the same in its history and once they
-- complete, which `decode.lua` turns into the log. Its session files hold items of another kind, so `agent.lua` gets
-- the history from the app-server too, and `files.lua` only lists them

local files = require('otto.providers.codex.files')
local agent = require('otto.providers.codex.agent')

local M = { name = 'codex', icon = '󰚩 ' }

--- @param name? string
--- @return string id of a new session, until Codex creates its thread
function M.new_id(name) return ((name or os.date('%Y_%m_%d_%H%M%S')):gsub('[^%w._-]+', '_')) end

M.open = agent.open
M.files = files.list
M.parse = files.parse
M.names = files.names

return M
