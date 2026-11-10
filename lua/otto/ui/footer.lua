-- The end of the transcript: the tools that are running and what the agent is doing, for how long, and the prompts that
-- it hasn't read yet, above the separator above the input

local highlight = require('otto.render.highlight')
local input = require('otto.input')
local scroll = require('otto.ui.scroll')
local tools = require('otto.render.tools')
local util = require('otto.util')

local ns = vim.api.nvim_create_namespace('otto.footer')
local slow_tool = 3000 -- milliseconds before running tools show for how long they've run, since most finish sooner
local labels = { working = 'Working', thinking = 'Thinking', compacting = 'Compacting' }

--- @class otto.Footer
--- @field bufnr integer
--- @field session otto.Session With the tools that are running
--- @field layout otto.Layout Which spaces the footer like the next block
--- @field started table<string, integer> When the tools started, in milliseconds of the event loop
--- @field timer? uv.uv_timer_t Counting the time while the agent works
local Footer = {}
Footer.__index = Footer

local M = {}

--- @param bufnr integer
--- @param session otto.Session
--- @param layout otto.Layout
--- @return otto.Footer
function M.new(bufnr, session, layout)
  return setmetatable({ bufnr = bufnr, session = session, layout = layout, started = {} }, Footer)
end

--- Draws the footer again, after the transcript or the state changed
function Footer:draw()
  local bufnr = self.bufnr
  local state = self.session.state
  local row = input.row(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

  local lines = {}
  local started = {}
  for _, running in ipairs(state.status and self.session.running_calls or {}) do
    started[running.id] = self.started[running.id] or vim.uv.now()
    local line = { { '  ' } } -- nested in a group
    local call = tools.display_call(running.tool, running.args)
    for _, chunk in ipairs(tools.header(call.tool, call.args)) do
      if chunk.filetype ~= nil then
        vim.list_extend(line, highlight.chunks(chunk[1], chunk.filetype))
      else
        table.insert(line, { chunk[1], chunk[2] })
      end
    end
    local elapsed = vim.uv.now() - started[running.id]
    if elapsed >= slow_tool then
      table.insert(line, { '  ' .. util.format_duration(math.floor(elapsed / 1000)), 'OttoStatusTime' })
    end
    table.insert(lines, line)
  end
  self.started = started
  -- like the tools will be once they finish
  if #lines > 0 and self.layout:spaced('tool') then table.insert(lines, 1, {}) end
  if state.status ~= nil then
    local elapsed = util.format_duration(math.floor((vim.uv.now() - state.status_since) / 1000))
    -- the empty line before the separator spaces it below
    local status = { { labels[state.status] .. '...', 'OttoStatus' }, { ' ' .. elapsed, 'OttoStatusTime' } }
    vim.list_extend(lines, { {}, status })
  end
  if #state.queue > 0 then table.insert(lines, {}) end
  for _, queued in ipairs(state.queue) do
    for j, line in ipairs(vim.split(queued.text, '\n')) do
      local kind = j == 1 and queued.follow_up and '  follow-up' or ''
      table.insert(lines, { { line, 'OttoQueued' }, { kind, 'OttoQueued' } })
    end
  end
  if #lines > 0 then
    -- above the separator, or above the input before the first block renders
    if row == 0 and #lines[1] == 0 then table.remove(lines, 1) end
    local opts = { virt_lines = lines, virt_lines_above = true }
    vim.api.nvim_buf_set_extmark(bufnr, ns, math.max(row - 2, 0), 0, opts)
  end
  scroll.follow(bufnr)
end

--- Counts the time while the agent works, and draws the footer again
function Footer:update()
  local running = self.session.state.status ~= nil
  if running and self.timer == nil then
    self.timer = vim.uv.new_timer()
    self.timer:start(
      1000,
      1000,
      vim.schedule_wrap(function()
        if vim.api.nvim_buf_is_loaded(self.bufnr) then self:draw() end
      end)
    )
  elseif not running then
    self:stop_timer()
  end
  self:draw()
end

function Footer:stop_timer()
  if self.timer == nil then return end
  self.timer:close()
  self.timer = nil
end

--- Stops counting, and takes the footer out of the buffer
function Footer:close()
  self:stop_timer()
  if vim.api.nvim_buf_is_valid(self.bufnr) then vim.api.nvim_buf_clear_namespace(self.bufnr, ns, 0, -1) end
end

return M
