-- Claude Code: `claude -p` with stream-json in both directions. Its session files and its stream hold the same
-- entries, which `decode.lua` turns into the log. `agent.lua` runs its process, and `files.lua` lists the saved
-- sessions

local files = require('otto.providers.claude.files')
local agent = require('otto.providers.claude.agent')
local util = require('otto.util')

local M = { name = 'claude', icon = '󰛄  ' }

--- @return string random UUID, which Claude Code requires for session ids
function M.new_id() return util.uuid() end

M.open = agent.open
M.files = files.list
M.parse = files.parse

return M
