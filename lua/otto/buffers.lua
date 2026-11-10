-- The views of open sessions, by buffer. Only `view.lua` changes them, and they're apart from it so that the ui modules
-- it loads can find them too

local M = {}

--- @type table<integer, otto.View>
local views = {}

--- @param bufnr integer
--- @return otto.View?
function M.get(bufnr) return views[bufnr] end

--- @return otto.View?
function M.current() return views[vim.api.nvim_get_current_buf()] end

--- @param bufnr integer
--- @param view otto.View?
function M.set(bufnr, view) views[bufnr] = view end

--- @return integer[]
function M.bufnrs() return vim.tbl_keys(views) end

--- @return otto.View[] Most recently used first
function M.recent()
  local infos = vim.tbl_filter(function(info) return views[info.bufnr] ~= nil end, vim.fn.getbufinfo({ bufloaded = 1 }))
  table.sort(infos, function(a, b) return a.lastused > b.lastused end)
  return vim.tbl_map(function(info) return views[info.bufnr] end, infos)
end

return M
