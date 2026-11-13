-- Otto's commands, which its keymaps and the palette (<M-x>) run. The agents' own commands, like pi's extensions,
-- prompt templates and skills, are prompts like "/review", which the palette lists as "pi-review" and starts in the
-- input, and which the input completes after a / at its start, see `lsp.lua`

local changes = require('otto.ui.changes')
local history = require('otto.ui.history')
local input = require('otto.input')
local pick = require('otto.ui.pick')
local prompts = require('otto.ui.prompts')
local uri = require('otto.uri')
local util = require('otto.util')

local M = {}

--- @class otto.Command One of `run` or `keys`
--- @field name string
--- @field description? string
--- @field modes? string[] Of its keymaps, normal mode by default
--- @field run? async fun(view: otto.View) Runs inside a task
--- @field keys? fun(view: otto.View): string The keys to run instead, right away, which keeps it out of the palette
--- @field palette? false Whether the palette skips it, like for moving around
--- @field available? fun(view: otto.View): boolean Commands that only some agents support

--- Opens the location in the previous window, or this one when there's no other
--- @param target otto.Target
function M.open_target(target)
  local previous = vim.fn.win_getid(vim.fn.winnr('#'))
  if previous ~= 0 and previous ~= vim.api.nvim_get_current_win() then vim.api.nvim_set_current_win(previous) end
  vim.cmd.edit(vim.fn.fnameescape(target.path))
  if target.lnum ~= nil then
    vim.api.nvim_win_set_cursor(0, { math.max(math.min(target.lnum, vim.api.nvim_buf_line_count(0)), 1), 0 })
    vim.cmd('normal! zz')
  end
end

--- Puts queued prompts back above what the input holds, in the order they were sent
--- @param view otto.View
--- @param texts string[]
local function take_back(view, texts)
  if #texts == 0 then return end
  local typed = vim.fn.prompt_getinput(view.bufnr)
  if typed ~= '' then table.insert(texts, typed) end
  input.set(view.bufnr, table.concat(texts, '\n'))
end

--- Inserts text into the input, and goes on inserting after it
--- @param view otto.View
--- @param lnum integer
--- @param col integer
--- @param text string
local function insert(view, lnum, col, text)
  vim.api.nvim_buf_set_text(view.bufnr, lnum - 1, col, lnum - 1, col, { text })
  if vim.api.nvim_get_current_buf() ~= view.bufnr then return end
  vim.api.nvim_win_set_cursor(0, { lnum, col + #text })
  if vim.fn.mode() == 'i' then return end
  -- not with keys, which the prompt buffer types once it starts insert mode again itself, like after a picker. At the
  -- end of the line, past its last character, which normal mode can't put the cursor after
  local line = vim.api.nvim_buf_get_lines(view.bufnr, lnum - 1, lnum, false)[1]
  vim.cmd.startinsert({ bang = col + #text >= #line })
end

--- @param view otto.View
--- @param backward boolean
local function jump_to_prompt(view, backward)
  local row = view.transcript:find_prompt(vim.fn.line('.') - 1, backward)
  if row ~= nil then vim.api.nvim_win_set_cursor(0, { row + 1, 0 }) end
end

--- @type otto.Command[]
M.builtin = {
  {
    name = 'model',
    description = 'Select a model',
    run = function(view)
      local models = view.session.agent:models()
      local function current(id) return id == view.session.state.model end
      pick.select({
        prompt = 'Model: ',
        items = models,
        format = function(id)
          local notes = current(id) and view.session.state.effort and { { view.session.state.effort, 'Comment' } }
            or nil
          return { { current(id) and '● ' or '  ', 'OttoStatus' }, { id } }, notes
        end,
        on_accept = function(id)
          util.run_task(function() view.session.agent:set_model(id) end)
        end,
      })
    end,
  },
  {
    name = 'effort',
    description = 'Pick the thinking level',
    run = function(view)
      local agent = view.session.agent
      local function current(level) return level == view.session.state.effort end
      pick.select({
        prompt = 'Effort: ',
        items = agent:efforts(),
        format = function(level) return { { current(level) and '● ' or '  ', 'OttoStatus' }, { level } } end,
        on_accept = function(level)
          util.run_task(function() agent:set_effort(level) end)
        end,
      })
    end,
  },
  {
    name = 'cycle_effort',
    description = 'Cycle the thinking level',
    run = function(view) view.session.agent:cycle_effort() end, -- the winbar shows the level
  },
  {
    name = 'compact',
    description = 'Compact the context, optionally with custom instructions',
    run = function(view)
      local agent = view.session.agent
      if not agent.compact_instructions then return agent:compact() end
      local instructions = util.input({ prompt = 'Compact instructions (optional): ' })
      if instructions == nil then return end
      agent:compact(vim.trim(instructions) ~= '' and instructions or nil)
    end,
  },
  {
    name = 'rename',
    description = 'Rename the session',
    run = function(view)
      local name = util.input({ prompt = 'Name: ', default = view.session.state.name })
      if name == nil or vim.trim(name) == '' then return end
      view.session.agent:rename(vim.trim(name))
    end,
  },
  {
    name = 'clear',
    description = 'Start a new session in this buffer, keeping this one saved',
    run = function(view)
      local provider = view.session.provider
      view:restart(uri.id(uri.unique(provider.name, provider.new_id())))
    end,
  },
  {
    name = 'resume',
    description = 'Switch to another session',
    run = function() pick.sessions({ saved = true }) end,
  },
  {
    name = 'prompts',
    description = 'Jump to a prompt of the session',
    run = function(view) prompts.pick(view) end,
  },
  {
    name = 'rewind',
    description = 'Rewind the session to an earlier prompt, keeping the session it leaves saved',
    available = function(view) return view.session.agent.fork ~= nil end,
    run = function(view) prompts.pick(view, { rewind = true }) end,
  },
  {
    name = 'remote_control',
    description = 'Continue the session from claude.ai or the Claude app, copying its link',
    available = function(view) return view.session.agent.remote_control ~= nil end,
    run = function(view)
      local agent = view.session.agent
      local link = view.session.state.remote
      if link == nil then
        link = agent:remote_control(true)
      else
        local choice = util.select({ 'Copy link', 'Turn off' }, { prompt = 'Remote Control: ' })
        if choice == 'Turn off' then agent:remote_control(false) end
        if choice ~= 'Copy link' then return end
      end
      if link == nil then return util.notify(view.session.provider.name .. " didn't return a link") end
      vim.fn.setreg(vim.fn.has('clipboard') == 1 and '+' or '"', link)
      util.notify('copied ' .. link, vim.log.levels.INFO)
    end,
  },
  {
    name = 'reload',
    description = 'Restart the agent, reloading its extensions, skills, prompt templates and context files',
    run = function(view) view:restart() end,
  },
  {
    name = 'history',
    description = 'Pick a prompt from the history of this folder',
    modes = { 'n', 'i' },
    run = function(view) history.pick(view) end,
  },
  {
    name = 'history_all',
    description = 'Pick a prompt from the history of every folder',
    run = function(view) history.pick(view, { all = true }) end,
  },
  {
    name = 'edits',
    description = 'Edits of the session to quickfix, with what else its tools changed while tracked',
    run = function(view) changes.to_quickfix(view.session) end,
  },
  {
    name = 'changes',
    description = 'What the tool under the cursor changed, or else the session, as a diff',
    available = function(view) return view.session.tracked ~= nil end,
    run = function(view) changes.open_at_cursor(view) end,
  },
  {
    name = 'abort',
    description = 'Stop the agent, taking back the queued prompts',
    run = function(view)
      -- first, since the agent would go on with them
      take_back(view, view.session.agent:take_queue())
      view.session.agent:abort()
    end,
  },
  {
    name = 'open',
    description = 'Open the location under the cursor, or submit',
    keys = function(view)
      local target = view.transcript:target_at(vim.fn.line('.') - 1)
      if target == nil then return 'A<CR><Esc>' end
      vim.schedule(function() M.open_target(target) end) -- windows can't change while the mapping evaluates
      return ''
    end,
  },
  {
    name = 'submit',
    description = 'Submit, which steers while the agent is working',
    modes = { 'n', 'i' },
    keys = function() return vim.fn.mode() == 'i' and '<CR>' or 'A<CR><Esc>' end,
  },
  {
    name = 'follow_up',
    description = 'Submit as a follow-up, which waits for the agent to finish',
    modes = { 'i' },
    keys = function(view)
      view.follow_up = true
      return '<CR>'
    end,
  },
  {
    -- <CR> in insert mode adds a line, like <S-CR> in prompt buffers
    name = 'newline',
    description = 'New line',
    modes = { 'i' },
    keys = function() return '<S-CR>' end,
  },
  {
    -- prompt buffers start window commands with <C-w> in insert mode, and delete words with <C-S-w>
    name = 'delete_word',
    description = 'Delete word',
    modes = { 'i' },
    keys = function() return '<C-S-w>' end,
  },
  {
    name = 'next_prompt',
    description = 'Next prompt',
    palette = false,
    run = function(view) jump_to_prompt(view, false) end,
  },
  {
    name = 'previous_prompt',
    description = 'Previous prompt',
    palette = false,
    run = function(view) jump_to_prompt(view, true) end,
  },
  {
    name = 'history_older',
    description = 'Take back the newest queued prompt, or the older prompt in history',
    modes = { 'n', 'i' },
    palette = false,
    run = function(view)
      local count = vim.v.count1
      -- like when the agent read them meanwhile
      local texts = #view.session.state.queue > 0 and view.session.agent:take_queue(true) or {}
      if #texts == 0 then return history.step(view, count) end
      take_back(view, texts)
    end,
  },
  {
    name = 'history_newer',
    description = 'Newer prompt in history',
    modes = { 'n', 'i' },
    palette = false,
    run = function(view) history.step(view, -vim.v.count1) end,
  },
  {
    name = 'commands',
    description = 'Commands',
    modes = { 'n', 'i' },
    palette = false,
    run = function(view) M.palette(view) end,
  },
}

--- @param view otto.View
--- @return otto.Command[] that the session's agent supports
function M.available(view)
  return vim.tbl_filter(function(command) return command.available == nil or command.available(view) end, M.builtin)
end

--- @param name string
--- @return otto.Command?
function M.get(name)
  return vim.iter(M.builtin):find(function(command) return command.name == name end)
end

--- @param name string Of the command
--- @return string Of the map that runs it, like <Plug>(otto-submit), which after/ftplugin/otto.lua can map too
function M.plug(name) return ('<Plug>(otto-%s)'):format(name) end

--- @param value otto.Keymap
--- @return table<string, string> Command by mode, without those turned off, of commands that may not exist
function M.by_mode(value)
  if type(value) == 'string' then
    local command = M.get(value)
    local by_mode = {}
    for _, mode in ipairs(command and command.modes or { 'n' }) do
      by_mode[mode] = value
    end
    return by_mode
  end
  local by_mode = {}
  for mode, name in pairs(type(value) == 'table' and value or {}) do
    if name then by_mode[mode] = name end
  end
  return by_mode
end

--- Runs a built-in command, returning the keys to run of those that return them
--- @param view otto.View
--- @param name string
--- @return string?
function M.run(view, name)
  local command = M.get(name)
  if command == nil then return util.notify('unknown command: ' .. name) end
  if command.available and not command.available(view) then
    return util.notify(name .. " isn't supported by " .. view.session.provider.name)
  end
  if command.keys then return command.keys(view) end
  util.run_task(function() command.run(view) end)
end

--- @param view otto.View
--- @return otto.AgentCommand[] Without those of the same name as otto's
function M.agent_commands(view)
  local builtin = {}
  for _, command in ipairs(M.available(view)) do
    builtin[command.name] = true
  end
  return vim.tbl_filter(function(command) return not builtin[command.name] end, view.session.state.commands)
end

--- @param lhs string
--- @param than? string
--- @return boolean Whether it's the better key to show, the one of fewer keys, like <M-x> over <localleader>x
local function shorter(lhs, than)
  if than == nil then return true end
  local keys, than_keys = #lhs:gsub('<[^<>]+>', '_'), #than:gsub('<[^<>]+>', '_')
  return keys < than_keys or keys == than_keys and #lhs < #than
end

--- @param bufnr integer
--- @return table<string, string> The key of each command that has one in the buffer, for the palette
local function keys_by_command(bufnr)
  local keys = {}
  for _, mode in ipairs({ 'n', 'i' }) do
    local maps = vim.api.nvim_buf_get_keymap(bufnr, mode)
    local local_lhs = {}
    for _, map in ipairs(maps) do
      local_lhs[map.lhs] = true
    end
    -- unless the buffer's own hide them
    for _, map in ipairs(vim.api.nvim_get_keymap(mode)) do
      if not local_lhs[map.lhs] then table.insert(maps, map) end
    end
    for _, map in ipairs(maps) do
      local name = map.rhs and map.rhs:match('^<Plug>%(otto%-(.+)%)$')
      if name ~= nil and shorter(map.lhs, keys[name]) then keys[name] = map.lhs end
    end
  end
  return keys
end

--- Picks a command. Otto's run, and the agent's start in the input, to finish writing
--- @param view otto.View
function M.palette(view)
  local keys = keys_by_command(view.bufnr)

  --- @class otto.PaletteItem
  --- @field command otto.Command | otto.AgentCommand
  --- @field builtin boolean

  local items = {} --- @type otto.PaletteItem[]
  for _, command in ipairs(M.available(view)) do
    if command.run and command.palette ~= false then table.insert(items, { command = command, builtin = true }) end
  end
  for _, command in ipairs(M.agent_commands(view)) do
    table.insert(items, { command = command, builtin = false })
  end

  --- @param item otto.PaletteItem
  --- @return string name With the provider before the agent's own, like "pi-review", which tells them from otto's
  local function name(item)
    return item.builtin and item.command.name or view.session.provider.name .. '-' .. item.command.name
  end

  --- @param item otto.PaletteItem
  local function format(item)
    local command = item.command
    local chunks = { { name(item), 'OttoToolName' } }
    if command.arg_hint then table.insert(chunks, { ' ' .. command.arg_hint, 'OttoToolArg' }) end
    if command.description then table.insert(chunks, { '  ' .. command.description:gsub('\n.*', ''), 'Comment' }) end
    local key = item.builtin and keys[command.name]
    return chunks, key and { { key, 'OttoToolDetail' } } or nil
  end

  --- @param item otto.PaletteItem
  local function run(item)
    if item.builtin then return M.run(view, item.command.name) end
    -- before what the input holds, which becomes its argument
    insert(view, input.row(view.bufnr) + 1, 0, '/' .. item.command.name .. ' ')
  end

  -- by name, then by the words of the descriptions
  pick.select({ prompt = 'Command: ', items = items, format = format, text = name, fuzzy = true, on_accept = run })
end

return M
