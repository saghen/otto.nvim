local M = {}

--- Error of what a closed agent never answers, which isn't notified since closing it was asked for
M.closed = 'agent closed'

--- @param message string
--- @param level? integer
function M.notify(message, level)
  if message == M.closed then return end
  vim.notify('otto: ' .. message, level or vim.log.levels.ERROR)
end

--- Runs `fn` as a task, notifying its error
--- @param fn async fun()
function M.run_task(fn)
  -- detached, since a task started inside another would report its error twice, and be closed when the other fails
  vim.async.run(fn):detach():on_complete(function(err)
    if err ~= nil then M.notify(tostring(err)) end
  end)
end

--- `vim.ui.select` inside a task
--- @async
--- @param items any[]
--- @param opts table
--- @return any?
function M.select(items, opts) return vim.async.await(3, vim.ui.select, items, opts) end

--- `vim.ui.input` inside a task
--- @async
--- @param opts table
--- @return string?
function M.input(opts) return vim.async.await(2, vim.ui.input, opts) end

--- Awaits a function that takes a callback of an error and data, raising the error
--- @async
--- @param fn fun(callback: fun(err?: string, data?: any))
--- @return any
function M.await(fn)
  local err, data = vim.async.await(1, fn)
  if err ~= nil then error(err, 0) end
  return data
end

--- What tasks wait for until it's set once, like the first response of an agent's process
--- @class otto.Ready
--- @field done boolean
--- @field err? string
--- @field value? any
--- @field waiting fun()[]
local Ready = {}
Ready.__index = Ready

--- @return otto.Ready
function M.ready() return setmetatable({ done = false, waiting = {} }, Ready) end

--- @param err? string
--- @param value? any
function Ready:set(err, value)
  if self.done then return end
  self.done, self.err, self.value = true, err, value
  for _, resume in ipairs(self.waiting) do
    resume()
  end
  self.waiting = {}
end

--- @async
--- @return any value Raising the error
function Ready:await()
  if not self.done then vim.async.await(1, function(resume) table.insert(self.waiting, resume) end) end
  if self.err ~= nil then error(self.err, 0) end
  return self.value
end

--- @alias otto.Chunks { [1]: string, [2]: string?, filetype?: string }[] Text and highlight group pairs, like virtual
--- text, or text that highlights as its filetype

--- @param chunks otto.Chunks
--- @return string
function M.join(chunks)
  return vim.iter(chunks):map(function(chunk) return chunk[1] end):join('')
end

--- @param levels string[] Of the model
--- @return string[] the usual ones when the model has none
function M.efforts(levels) return #levels > 0 and levels or { 'low', 'medium', 'high' } end

--- @param levels string[]
--- @param current? string
--- @return string the level after the current one
function M.next_effort(levels, current) return levels[(vim.fn.index(levels, current) + 1) % #levels + 1] end

--- @param text string
--- @return string without the whitespace at its end, unlike `vim.trim`, which would shift the lines of file contents
function M.trim_end(text) return text:match('^(.*%S)') or '' end

--- @param path string
--- @return string relative to the current folder, or the home folder
function M.short_path(path) return vim.fn.fnamemodify(path, ':~:.') end

--- @param seconds integer
--- @return string like "2m 10s"
function M.format_duration(seconds)
  if seconds < 60 then return seconds .. 's' end
  if seconds < 3600 then return ('%dm %ds'):format(math.floor(seconds / 60), seconds % 60) end
  return ('%dh %dm'):format(math.floor(seconds / 3600), math.floor(seconds % 3600 / 60))
end

local age_units = { { 'mo', 30 * 86400 }, { 'w', 7 * 86400 }, { 'd', 86400 }, { 'h', 3600 }, { 'm', 60 } }

--- @param seconds integer
--- @return string like "4d"
function M.format_age(seconds)
  for _, unit in ipairs(age_units) do
    if seconds >= unit[2] then return math.floor(seconds / unit[2]) .. unit[1] end
  end
  return 'now'
end

--- @param id string
--- @return boolean whether it's a UUID, like the ids of Claude Code's sessions and Codex's threads
function M.is_uuid(id) return id:match('^%x+%-%x+%-%x+%-%x+%-%x+$') ~= nil end

--- @return string random version 4 UUID
function M.uuid()
  local hex = vim.iter({ vim.uv.random(16):byte(1, 16) }):map(function(byte) return ('%02x'):format(byte) end):join('')
  local variant = ('%x'):format(8 + tonumber(hex:sub(17, 17), 16) % 4)
  return ('%s-%s-4%s-%s%s-%s'):format(
    hex:sub(1, 8),
    hex:sub(9, 12),
    hex:sub(14, 16),
    variant,
    hex:sub(18, 20),
    hex:sub(21)
  )
end

return M
