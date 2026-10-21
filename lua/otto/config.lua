local M = {}

local defaults = { picker = 'minibuffer', pi = { command = 'pi', args = {} } }
M.options = vim.deepcopy(defaults)

--- Replaces configuration; omitted options use their defaults.
--- @param opts? table
function M.setup(opts)
  if opts == nil then opts = {} end
  assert(type(opts) == 'table', 'otto: options must be a table')
  assert(opts.pi == nil or type(opts.pi) == 'table', 'otto: pi must be a table')
  local options = vim.tbl_deep_extend('force', vim.deepcopy(defaults), opts)
  assert(options.picker == 'minibuffer' or options.picker == 'vim_ui', 'otto: picker must be minibuffer or vim_ui')
  local command = options.pi.command
  assert(
    type(command) == 'string' and command ~= '' and not command:find('\0'),
    'otto: pi.command must be a non-empty string'
  )
  local args = options.pi.args
  assert(type(args) == 'table' and vim.islist(args), 'otto: pi.args must be a list')
  for _, arg in ipairs(args) do
    assert(type(arg) == 'string' and not arg:find('\0'), 'otto: pi.args must contain strings without NUL bytes')
  end
  for _, key in ipairs({ 'agent_dir', 'session_dir' }) do
    local path = options.pi[key]
    assert(path == nil or (type(path) == 'string' and path ~= '' and not path:find('\0')), 'otto: invalid pi.' .. key)
  end
  M.options = options
end

local function env(name)
  local value = vim.env[name]
  return value ~= '' and value or nil
end

--- Expands home and environment variables, but not glob characters.
local function expand(path) return vim.fs.normalize(vim.fn.fnamemodify(vim.fs.normalize(path), ':p')) end

function M.agent_dir() return expand(M.options.pi.agent_dir or env('PI_CODING_AGENT_DIR') or '~/.pi/agent') end

function M.session_root()
  return expand(M.options.pi.session_dir or env('PI_CODING_AGENT_SESSION_DIR') or (M.agent_dir() .. '/sessions'))
end

function M.session_dir()
  local folder = vim.fn.getcwd():sub(2):gsub('[/\\:]', '-')
  return vim.fs.joinpath(M.session_root(), '--' .. folder .. '--')
end

--- Pi's --session-dir is a project directory, not the storage root.
function M.session_override() return M.options.pi.session_dir ~= nil or env('PI_CODING_AGENT_SESSION_DIR') ~= nil end

return M
