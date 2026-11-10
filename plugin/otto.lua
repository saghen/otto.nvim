-- The :Otto command, the autocmds that load sessions into their buffers and follow their windows, and the highlights.
-- The rest of otto loads once it's used. See ftplugin/otto.lua for what each session's buffer sets up, like the <Plug>
-- maps

if vim.g.loaded_otto then return end
vim.g.loaded_otto = true

local buffers = require('otto.buffers')
local uri = require('otto.uri')

local group = vim.api.nvim_create_augroup('otto', {})

-- Otto's highlight groups, linked to the groups that colorschemes already define, so that a theme only sets the ones
-- it wants to change
local links = {
  OttoPrompt = 'QuickFixLine', -- background of the prompts in the transcript, and their sign column
  OttoSeparator = 'NonText', -- the rule above the prompt
  OttoToolName = '@markup.strong', -- like "read" or "$"
  OttoToolArg = 'String', -- the path, command, pattern or query
  OttoToolDetail = 'Comment', -- like "(5 lines)"
  OttoToolFailed = 'DiagnosticError', -- also counts the failed tools in summaries
  OttoToolSummary = 'Comment', -- like "read 2 files, ran 1 command"
  OttoPath = 'Directory', -- of locations in tool output, like `path:12:` from grep
  OttoLineNumber = 'LineNr', -- of those locations, and of the lines in diffs
  OttoStatus = 'Function', -- like "Working..."
  OttoStatusTime = 'Comment', -- how long the agent has been working
  OttoStatusDone = 'Comment', -- like "Worked for 2m 10s · done 4:19 p.m"
  OttoQueued = 'Comment', -- prompts that the agent hasn't read yet
  OttoWinbarIcon = 'Function',
  OttoWinbarLabel = 'Comment', -- like "model:"
  OttoWinbarSeparator = 'NonText',
}

local function link()
  for name, target in pairs(links) do
    vim.api.nvim_set_hl(0, name, { link = target, default = true })
  end
end
link()
-- since colorschemes clear the highlights first
vim.api.nvim_create_autocmd('ColorScheme', { group = group, callback = link })

vim.api.nvim_create_autocmd('BufReadCmd', {
  group = group,
  pattern = vim.tbl_map(function(name) return uri.format(name, '*') end, uri.providers),
  callback = function(ev) require('otto.view').load(ev.buf) end,
})
vim.api.nvim_create_autocmd({ 'WinResized', 'WinScrolled' }, {
  group = group,
  callback = function()
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if buffers.get(vim.api.nvim_win_get_buf(win)) ~= nil then require('otto.ui.scroll').scrolled(win) end
    end
  end,
})
vim.api.nvim_create_autocmd('VimLeavePre', {
  group = group,
  callback = function()
    if #buffers.bufnrs() > 0 then require('otto.ui.history').save_drafts(buffers.bufnrs()) end
  end,
})

--- @type table<string, fun(arg?: string, cmd: vim.api.keyset.create_user_command.command_args)>
local subcommands = {
  send = function(_, cmd) require('otto').send(cmd.line1, cmd.line2) end,
  resume = function(id)
    if id == nil then return require('otto.ui.pick').sessions({ saved = true }) end
    local saved = vim.iter(require('otto.providers').saved()):find(function(session) return session.id == id end)
    if saved == nil then return require('otto.util').notify('no saved session ' .. id) end
    vim.cmd.edit(uri.format(saved.provider, saved.id))
  end,
  pick = function() require('otto.ui.pick').sessions() end,
}
for _, name in ipairs(uri.providers) do
  subcommands[name] = function(arg) require('otto').new(arg, name) end
end

-- :Otto pi [name], :Otto claude [name], :Otto codex [name], :Otto resume [id], :Otto pick, which :Otto defaults to, and
-- :Otto send for the current line or a range. In a session, the commands of the palette too, like :Otto compact
vim.api.nvim_create_user_command('Otto', function(cmd)
  local subcommand = subcommands[cmd.fargs[1] or 'pick']
  local session_view = buffers.current()
  -- loaded along with the session
  local commands = session_view and require('otto.ui.commands')
  if subcommand == nil and commands and commands.get(cmd.fargs[1]) then
    local keys = commands.run(session_view, cmd.fargs[1])
    if keys then vim.api.nvim_feedkeys(vim.keycode(keys), 'n', false) end
    return
  end
  if subcommand == nil then return require('otto.util').notify('unknown subcommand: ' .. cmd.fargs[1]) end
  local arg = table.concat(cmd.fargs, ' ', 2)
  subcommand(arg ~= '' and arg or nil, cmd)
end, {
  nargs = '*',
  range = true,
  complete = function(lead, line)
    local words = vim.split(line, '%s+')
    if #words <= 2 then
      local names = vim.tbl_keys(subcommands)
      local session_view = buffers.current()
      local commands = session_view and require('otto.ui.commands')
      for _, command in ipairs(commands and commands.available(session_view) or {}) do
        if subcommands[command.name] == nil then table.insert(names, command.name) end
      end
      table.sort(names)
      return vim.tbl_filter(function(name) return vim.startswith(name, lead) end, names)
    end
    if words[2] ~= 'resume' then return {} end
    local ids = vim.tbl_map(function(saved) return saved.id end, require('otto.providers').saved())
    return lead == '' and ids or vim.fn.matchfuzzy(ids, lead)
  end,
})
