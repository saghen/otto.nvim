-- JSONL: of agents' saved sessions, which otto reads a line at a time, of their processes' messages, and of the logs
-- that otto follows as they're appended to, its history and otto-track's

local M = {}

--- @param line string
--- @return any value With JSON's nulls as nil rather than `vim.NIL`, which is truthy
function M.decode(line) return vim.json.decode(line, { luanil = { object = true, array = true } }) end

--- Calls `read` with each line left in the file, until it returns false, and closes it
--- @param handle file*
--- @param read fun(line: string): boolean?
--- @param on_error? fun(err: string) Of a bad line, like the last while it's written, which doesn't lose the lines
--- after it. Skipped by default
function M.each_line(handle, read, on_error)
  for line in handle:lines() do
    local ok, result = pcall(read, line)
    if not ok and on_error then on_error(tostring(result)) end
    if ok and result == false then break end
  end
  handle:close()
end

--- The whole lines appended to the file since `offset`, or since its start once it's shorter, like when it was replaced
--- @param path string
--- @param offset integer Bytes read so far
--- @return string[] lines
--- @return integer offset After the last whole line, since another process may be writing the next
--- @return boolean restarted Whether it read from the start
function M.read_appended(path, offset)
  local fd = vim.uv.fs_open(path, 'r', 438)
  if fd == nil then return {}, offset, false end
  local size = vim.uv.fs_fstat(fd).size
  local restarted = size < offset
  if restarted then offset = 0 end
  local data = size > offset and vim.uv.fs_read(fd, size - offset, offset) or ''
  vim.uv.fs_close(fd)
  local last = data:match('.*()\n')
  if last == nil then return {}, offset, restarted end
  return vim.split(data:sub(1, last - 1), '\n'), offset + last, restarted
end

return M
