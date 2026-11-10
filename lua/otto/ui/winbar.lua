-- The winbar of a session: the agent's icon, the session's name, model, thinking level, context usage, cost and
-- whether Remote Control is on

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
  local context = state.context_tokens and state.context_window and state.context_tokens / state.context_window * 100
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
