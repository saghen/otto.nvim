-- The winbar of a session: the agent's icon, the session's name, model, thinking level, context usage, cost and
-- whether Remote Control is on. Context usage is of where the agent compacts, or of its window when it doesn't

local M = {}

--- @param text string
--- @param group string
--- @return string
local function item(text, group) return ('%%#%s#%s'):format(group, (text:gsub('%%', '%%%%'))) end

local separator = item(' | ', 'OttoWinbarSeparator')

--- @param view otto.View
--- @return string like "󰏿 investigate | model: deepseek/deepseek-v4.1-flash | effort: high"
function M.render(view)
  local state = view.session.state
  local limit = state.compact_at or state.context_window
  local context = state.context_tokens and limit and state.context_tokens / limit * 100
  local fields = {
    { 'model', state.model },
    { 'effort', state.effort },
    { 'context', context and ('%d%%'):format(context) },
    { 'cost', (state.cost or 0) >= 0.005 and ('$%.2f'):format(state.cost) or nil },
    { 'remote', state.remote and 'on' },
  }
  local bar = '  ' .. item(view.session.provider.icon, 'OttoWinbarIcon') .. item(state.name or state.id, 'Normal')
  for _, field in ipairs(fields) do
    if field[2] ~= nil then
      bar = bar .. separator .. item(field[1] .. ': ', 'OttoWinbarLabel') .. item(field[2], 'Normal')
    end
  end
  return bar
end

return M
