-- Unified diff hunks as `otto.DiffLine`s, which the providers whose agents report them share

local M = {}

--- The lines of a hunk, which start with their sign, numbered from where the hunk starts in each file
--- @param lines string[]
--- @param old integer
--- @param new integer
--- @return otto.DiffLine[]
function M.hunk(lines, old, new)
  local diff = {}
  for _, line in ipairs(lines) do
    -- without lines like "\ No newline at end of file"
    if not vim.startswith(line, '\\') then
      -- empty lines around the change can lose their space
      local sign = line == '' and ' ' or line:sub(1, 1)
      table.insert(diff, { sign = sign, lnum = sign == '-' and old or new, text = line:sub(2) })
      if sign ~= '+' then old = old + 1 end
      if sign ~= '-' then new = new + 1 end
    end
  end
  return diff
end

return M
