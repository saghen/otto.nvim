-- The input of a session's buffer, the lines from the prompt buffer's ':' mark to the end, below the transcript

local M = {}

--- @param bufnr integer Of a session
--- @return integer row of the first line of the input, 0-indexed
function M.row(bufnr) return vim.api.nvim_buf_get_mark(bufnr, ':')[1] - 1 end

--- Replaces what the input holds
--- @param bufnr integer
--- @param text string
function M.set(bufnr, text) vim.api.nvim_buf_set_lines(bufnr, M.row(bufnr), -1, false, vim.split(text, '\n')) end

return M
