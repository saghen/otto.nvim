-- The agents that otto runs, which only translate between their processes and files, and the log, the state and
-- requests, see `event.lua`. They don't touch buffers or ask the user anything

--- @class otto.Provider
--- @field name otto.ProviderName Of the buffers of its sessions, like claude://<id>
--- @field icon string With the space after it
--- @field new_id fun(name?: string): string Of a new session
--- @field open fun(id: string, opts: otto.AgentOpts): otto.Agent Starts the agent for the session
--- @field files fun(): string[] Of the saved sessions
--- @field parse fun(file: string, modified: integer): otto.ParsedSession? A saved session, nothing of a file that's
--- gone, and without its bad lines, like the last while it's written
--- @field names? fun(): table<string, string> Of sessions, when they're kept apart from their files

--- @class otto.AgentOpts
--- @field name? string Display name of a new session
--- @field config otto.ProviderConfig Of the session's buffer, which providers with more options narrow
--- @field on_log fun(event: otto.Event)
--- @field on_state fun(patch: otto.StatePatch)
--- @field on_request fun(request: otto.Request)

--- @alias otto.PromptMode 'steer' | 'follow_up' Whether a prompt sent while the agent works waits for its turn to end

--- @class otto.Agent A running agent. Its methods that are async run inside tasks, and raise their errors
--- @field replay async fun(self: otto.Agent) Adds the session's history to the log
--- @field prompt fun(self: otto.Agent, text: string, mode: otto.PromptMode) Follow-ups wait for the turn to end
--- @field abort fun(self: otto.Agent)
--- @field take_queue async fun(self: otto.Agent, newest_only?: boolean): string[] Prompts that the agent hasn't read
--- yet, or only the newest, which it drops. None for the newest of those that the agent can only take back all at
--- once, like Codex's that steer
--- @field compact async fun(self: otto.Agent, instructions?: string)
--- @field compact_instructions boolean Whether `compact` takes instructions
--- @field models async fun(self: otto.Agent): string[]
--- @field set_model async fun(self: otto.Agent, model: string)
--- @field cycle_effort async fun(self: otto.Agent)
--- @field rename async fun(self: otto.Agent, name: string) Claude Code's runs after the turn that's running
--- @field commands async fun(self: otto.Agent): otto.AgentCommand[]
--- @field fork_points? async fun(self: otto.Agent): { id: string, text: string }[] Prompts to fork from
--- @field fork? async fun(self: otto.Agent, id: string): { id: string, text: string }? The new session's id, and the
--- prompt to edit
--- @field remote_control? async fun(self: otto.Agent, enabled: boolean): string? Turns Remote Control on or off,
--- returning the session's link once it's on
--- @field close fun(self: otto.Agent)

--- @class otto.AgentCommand The agent's own, like pi's extensions, prompt templates and skills
--- @field name string
--- @field description? string
--- @field arg_hint? string

--- @class otto.ParsedSession What a provider reads of a saved session
--- @field provider otto.ProviderName
--- @field id string
--- @field name? string Display name
--- @field prompt? string The first one
--- @field message_count integer
--- @field modified integer Seconds since the epoch

--- @class otto.SavedSession : otto.ParsedSession
--- @field title string Display name, or the first prompt, or the id

local M = {}

--- @type table<otto.ProviderName, otto.Provider>
M.providers = {
  pi = require('otto.providers.pi'),
  claude = require('otto.providers.claude'),
  codex = require('otto.providers.codex'),
}

--- @param name otto.ProviderName | string
--- @return otto.Provider?
function M.get(name) return M.providers[name] end

--- @type table<string, { mtime: uv.fs_stat.result.time, cwd: string, saved?: otto.ParsedSession }> by file, while
--- unmodified, without the sessions of other folders
local cache = {}

--- @param provider otto.Provider
--- @param file string
--- @param cwd string
--- @return otto.ParsedSession?
local function parse_cached(provider, file, cwd)
  -- like a session that was deleted since it was listed
  local stat = vim.uv.fs_stat(file)
  if stat == nil then
    cache[file] = nil
    return
  end
  local mtime = stat.mtime
  local cached = cache[file]
  -- to the nanosecond, since sessions change more than once a second
  if cached == nil or cached.mtime.sec ~= mtime.sec or cached.mtime.nsec ~= mtime.nsec or cached.cwd ~= cwd then
    cached = { mtime = mtime, cwd = cwd, saved = provider.parse(file, mtime.sec) }
    cache[file] = cached
  end
  return cached.saved
end

--- The current folder's saved sessions, newest first
--- @return otto.SavedSession[]
function M.saved()
  local sessions = {}
  -- Codex's files are of every folder, and read only those of the current one
  local cwd = vim.fn.getcwd()
  for _, provider in pairs(M.providers) do
    local names = provider.names and provider.names() or {}
    for _, file in ipairs(provider.files()) do
      local parsed = parse_cached(provider, file, cwd)
      if parsed ~= nil then
        -- apart from the cached one, whose name may change
        local saved = vim.tbl_extend('force', {}, parsed) --[[@as otto.SavedSession]]
        saved.name = names[saved.id] or saved.name
        saved.title = saved.name or (saved.prompt and vim.trim(saved.prompt):gsub('%s+', ' ')) or saved.id
        table.insert(sessions, saved)
      end
    end
  end
  table.sort(sessions, function(a, b) return a.modified > b.modified end)
  return sessions
end

return M
