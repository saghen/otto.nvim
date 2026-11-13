-- Otto's configuration, which `require('otto').setup()` merges into, or `set` with `{ bufnr }` for a session's
-- buffer, like in after/ftplugin/otto.lua. Providers read theirs when they start

--- @class (exact) otto.Config
--- @field default_provider otto.ProviderName Of `:Otto` and new sessions
--- @field keymaps table<string, otto.Keymap> | false Of the session's buffer, false for none
--- @field providers otto.ProvidersConfig
--- @field track boolean Whether agents run under otto-track, which sees what their commands change too, see
--- `track.lua`
--- @field on_host string[] Commands that agents under otto-track run on the host, outside its user namespace, where
--- others' files look owned by nobody and setuid does nothing. What they change isn't the agent's

--- @alias otto.ProviderName 'pi' | 'claude' | 'codex' Like `uri.providers`

--- Command, or command by mode, like { n = 'open', i = 'newline' }
--- @alias otto.Keymap string | false | table<string, string | false>

--- @class (exact) otto.ProvidersConfig
--- @field pi otto.ProviderConfig
--- @field claude otto.ClaudeConfig
--- @field codex otto.ProviderConfig

--- @class (exact) otto.ProviderConfig
--- @field cmd string[] Before otto's arguments, like { 'claude' } or a wrapper
--- @field args string[] After otto's arguments
--- @field env table<string, string>

--- @class (exact) otto.ClaudeConfig : otto.ProviderConfig
--- @field model string
--- @field effort string
--- @field permission_mode otto.ClaudePermissionMode

--- @class (exact) otto.ConfigPartial : otto.Config, {}
--- @field default_provider? otto.ProviderName
--- @field keymaps? table<string, otto.Keymap> | false
--- @field providers? otto.ProvidersConfigPartial
--- @field track? boolean
--- @field on_host? string[]

--- @class (exact) otto.ProviderConfigPartial : otto.ProviderConfig, {}
--- @field cmd? string[]
--- @field args? string[]
--- @field env? table<string, string>

--- @class (exact) otto.ClaudeConfigPartial : otto.ClaudeConfig, {}
--- @field cmd? string[]
--- @field args? string[]
--- @field env? table<string, string>
--- @field model? string
--- @field effort? string
--- @field permission_mode? otto.ClaudePermissionMode

--- @class (exact) otto.ProvidersConfigPartial : otto.ProvidersConfig, {}
--- @field pi? otto.ProviderConfigPartial
--- @field claude? otto.ClaudeConfigPartial
--- @field codex? otto.ProviderConfigPartial

local keymaps = {
  ['<CR>'] = { n = 'open', i = 'newline' },
  ['<C-s>'] = 'submit',
  ['<M-CR>'] = 'follow_up',
  ['<C-w>'] = 'delete_word',
  ['<C-c>'] = 'abort',
  [']]'] = 'next_prompt',
  ['[['] = 'previous_prompt',
  ['<M-p>'] = 'history_older',
  ['<M-n>'] = 'history_newer',
  ['<M-r>'] = 'history',
  ['<M-x>'] = 'commands',
  ['<C-p>'] = 'model',
  ['<S-Tab>'] = 'cycle_effort',
  ['<localleader>m'] = 'model',
  ['<localleader>e'] = 'effort',
  ['<localleader>c'] = 'compact',
  ['<localleader>n'] = 'clear',
  ['<localleader>s'] = 'resume',
  ['<localleader>r'] = 'rename',
  ['<localleader>R'] = 'rewind',
  ['<localleader>l'] = 'reload',
  ['<localleader>h'] = 'history',
  ['<localleader>H'] = 'history_all',
  ['<localleader>p'] = 'prompts',
  ['<localleader>q'] = 'edits',
  ['<localleader>d'] = 'changes',
}

--- Spells keys one way, like <C-S> for <c-s>, so that the user's replace the defaults. Leaders stay, since they may be
--- set after setup
--- @param lhs string
--- @return string
local function normalize_lhs(lhs)
  return (
    lhs:gsub('<[^<>]+>', function(key)
      local lower = key:lower()
      if lower == '<leader>' then return '<Leader>' end
      if lower == '<localleader>' then return '<LocalLeader>' end
      return vim.fn.keytrans(vim.keycode(key))
    end)
  )
end

--- @param maps table<string, otto.Keymap>
--- @return table<string, otto.Keymap>
local function normalize(maps)
  local normalized = {}
  for lhs, value in pairs(maps) do
    normalized[type(lhs) == 'string' and normalize_lhs(lhs) or lhs] = value
  end
  return normalized
end

--- @return blink.lib.ConfigSchema
local function schema()
  local types = require('blink.lib.config').types

  -- only the shape, since the commands load most of otto, and keymaps.lua checks them as it maps them
  local keymaps_type = types.validator('map(keycode, command | false | map(mode, command | false))', function(val)
    if type(val) ~= 'table' then return false end
    for lhs, value in pairs(val) do
      if not types.keycode.validator(lhs) then return false, ('[%s]: expected keycode'):format(tostring(lhs)) end
      local by_mode = type(value) == 'table' and value or { value }
      for mode, name in pairs(by_mode) do
        if name ~= false and type(name) ~= 'string' then
          local path = type(value) == 'table' and ('[%s].%s'):format(lhs, mode) or ('[%s]'):format(lhs)
          return false, ('%s: expected command or false, got %s'):format(path, vim.inspect(name))
        end
      end
    end
    return true
  end)

  --- @param cmd string
  --- @param extra? table
  local function provider(cmd, extra)
    return vim.tbl_extend('error', {
      cmd = { { cmd }, types.list('string') },
      args = { {}, types.list('string') },
      env = { {}, types.map('string', 'string') },
    }, extra or {})
  end

  return {
    default_provider = { 'pi', types.enum(require('otto.uri').providers) },
    keymaps = { normalize(keymaps), { types.enum({ false }), keymaps_type } },
    providers = {
      pi = provider('pi'),
      claude = provider('claude', {
        model = { 'claude-opus-5-5', 'string' },
        effort = { 'high', 'string' },
        -- asks only for what its classifier doesn't allow. Of otto.ClaudePermissionMode
        permission_mode = {
          'auto',
          types.enum({ 'default', 'manual', 'acceptEdits', 'plan', 'auto', 'dontAsk', 'bypassPermissions' }),
        },
      }),
      -- whose approval policy and sandbox come from Codex's config, which args can override, like
      -- { '-c', 'approval_policy="on-request"' }
      codex = provider('codex'),
    },
    track = { false, 'boolean' },
    on_host = { { 'ssh', 'sudo', 'sudoedit', 'su', 'doas', 'pkexec', 'podman' }, types.list('string') },
  }
end

-- created on first use, since blink.lib may be added to the runtimepath after otto loads
local cached --- @type blink.lib.Config?
local function instance()
  if cached ~= nil then return cached end
  if vim.async == nil then error('otto: requires a Neovim nightly with vim.async', 0) end
  local ok, lib = pcall(require, 'blink.lib.config')
  if not ok then error('otto: requires blink.lib, of its vim-async branch', 0) end
  cached = lib.new(schema(), { validate = false })
  return cached
end

--- The current buffer, which blink.lib only tracks on BufEnter, after a session's buffer loads and its ftplugin runs
--- @param bufnr? integer
--- @return integer?
local function to_bufnr(bufnr)
  if (bufnr == nil or bufnr == 0) and not vim.in_fast_event() then return vim.api.nvim_get_current_buf() end
  return bufnr
end

local M = {}

--- @param filter? blink.lib.config.Filter
--- @return otto.Config
function M.get(filter)
  return instance().get(vim.tbl_extend('force', filter or {}, { bufnr = to_bufnr(filter and filter.bufnr) }))
end

--- @param tbl otto.ConfigPartial
--- @param opts? blink.lib.config.SetOpts
function M.set(tbl, opts)
  if type(tbl.keymaps) == 'table' then tbl = vim.tbl_extend('force', tbl, { keymaps = normalize(tbl.keymaps) }) end
  if opts and opts.bufnr ~= nil then opts = vim.tbl_extend('force', opts, { bufnr = to_bufnr(opts.bufnr) }) end
  instance().set(tbl, opts)
  return M
end

return M
