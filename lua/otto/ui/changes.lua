-- What an agent changed: its edits, in the quickfix list

local tools = require('otto.render.tools')
local util = require('otto.util')

local M = {}

--- Files that the agent edited, at the first changed line, for the quickfix list
--- @param events otto.Event[] The log
--- @return vim.quickfix.entry[]
function M.quickfix_edits(events)
  local calls = {} --- @type table<string, otto.ToolCall>
  local edits = {} --- @type vim.quickfix.entry[]
  for _, event in ipairs(events) do
    if event.type == 'tool_call' then calls[event.id] = tools.display_call(event.tool, event.args) end
    local call = event.type == 'tool_result' and calls[event.id] or nil
    -- which results without a call don't have
    if call and event.diff ~= nil and call.args.path ~= nil then
      local _, first_changed = tools.format_diff(event.diff)
      local text = util.join(tools.diff_header(call, event.diff))
      -- a string, which `display_call` checked
      local path = call.args.path --[[@as string]]
      table.insert(edits, { filename = path, lnum = first_changed or 1, text = text })
    end
  end
  return edits
end

--- Puts the session's edits in the quickfix list, and opens it
--- @param session otto.Session
function M.to_quickfix(session)
  local items = M.quickfix_edits(session.events)
  vim.fn.setqflist({}, ' ', { title = session.state.id .. ' edits', items = items })
  vim.cmd.copen()
end

return M
