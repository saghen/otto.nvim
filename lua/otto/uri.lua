-- Names of sessions, which name their buffers too: <provider>://<id>

local M = {}

--- @type otto.ProviderName[] Of otto.ProviderName, without loading the providers, which load most of otto
M.providers = { 'pi', 'claude', 'codex' }

--- @param provider string
--- @param id string
--- @return string
function M.format(provider, id) return provider .. '://' .. id end

--- @param uri string
--- @return string? provider
--- @return string? id
function M.parse(uri) return uri:match('^(%a+)://(.+)$') end

--- @param uri string
--- @return string? id
function M.id(uri) return select(2, M.parse(uri)) end

--- Of a new session, which no buffer has yet, like a session of the same name, or of the same second, that isn't
--- saved yet
--- @param provider string
--- @param id string
--- @return string
function M.unique(provider, id)
  local uri, count = M.format(provider, id), 1
  while vim.fn.bufexists(uri) == 1 do
    count = count + 1
    uri = M.format(provider, ('%s_%d'):format(id, count))
  end
  return uri
end

return M
