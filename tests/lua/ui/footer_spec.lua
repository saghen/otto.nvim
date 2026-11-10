-- ui/footer.lua: what the agent is doing and its queued prompts, as virtual lines above the separator

local t = ...
local footer = require('otto.ui.footer')
local highlight = require('otto.render.highlight')
local layout = require('otto.render.layout')

local ns = vim.api.nvim_create_namespace('otto.footer')

--- @param state? table Over an agent that's idle
--- @return table session Like `otto.Session`, with what the footer reads
local function session(state)
  return { state = vim.tbl_extend('force', { queue = {} }, state or {}), running_calls = {} }
end

--- @param bufnr integer
--- @return { row: integer, lines: table[] }? Of the footer's extmark
local function drawn(bufnr)
  local mark = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })[1]
  return mark and { row = mark[2], lines = mark[4].virt_lines }
end

t.describe('before the transcript', function()
  local bufnr = t.scratch({ '' }, 0)
  local s = session()
  local f = footer.new(bufnr, s, layout.new())
  f:draw()
  t.check('idle draws nothing', drawn(bufnr), nil)

  s.state.status, s.state.status_since = 'working', vim.uv.now() - 5500
  f:draw()
  local mark = drawn(bufnr)
  t.check('above the input, without the line that spaces it', mark and mark.row, 0)
  t.check('status and time', mark and mark.lines, {
    { { 'Working...', 'OttoStatus' }, { ' 5s', 'OttoStatusTime' } },
  })

  s.state.status = 'compacting'
  f:draw()
  t.check('label', drawn(bufnr).lines[1][1][1], 'Compacting...')
end)

t.describe('below the transcript', function()
  local bufnr = t.scratch({ '' }, 0)
  t.render(bufnr, { { type = 'text', text = 'Looking.', at = 0 } })
  local l = layout.new()
  l:add({ type = 'text', text = 'Looking.', at = 0 })
  local s = session({ status = 'thinking', status_since = vim.uv.now() })
  local f = footer.new(bufnr, s, l)

  s.running_calls = {
    { id = 'a', tool = 'read', args = { path = 'a.lua' } },
    { id = 'b', tool = 'bash', args = { command = 'make' } },
  }
  f.started.b = vim.uv.now() - 4000
  f:draw()
  local mark = drawn(bufnr)
  t.check('above the separator', mark and mark.row, 1)
  local lines = mark and mark.lines or {}
  t.check(
    'running tools, right after the text',
    lines[1],
    { { '  ' }, { 'read', 'OttoToolName' }, { ' a.lua', 'OttoToolArg' } }
  )
  t.check('commands highlight as bash', vim.list_slice(lines[2], 3, #lines[2] - 1), highlight.chunks(' make', 'bash'))
  t.check('slow tools show how long they ran', lines[2][#lines[2]], { '  4s', 'OttoStatusTime' })
  t.check('then the status', vim.list_slice(lines, 3), {
    {},
    { { 'Thinking...', 'OttoStatus' }, { ' 0s', 'OttoStatusTime' } },
  })
  local ids = vim.tbl_keys(f.started)
  table.sort(ids)
  t.check('remembers when they started', ids, { 'a', 'b' })

  l:add({ type = 'user', text = 'hi', at = 0 })
  s.running_calls = { { id = 'b', tool = 'bash', args = { command = 'make' } } }
  f:draw()
  t.check('spaced like tools after a prompt', drawn(bufnr).lines[1], {})
  t.check('forgets finished tools', vim.tbl_keys(f.started), { 'b' })

  s.state.status = nil
  s.state.queue = { { text = 'next\nlines' }, { text = 'later', follow_up = true } }
  f:draw()
  t.check('running tools only while it works, and queued prompts', drawn(bufnr).lines, {
    {},
    { { 'next', 'OttoQueued' }, { '', 'OttoQueued' } },
    { { 'lines', 'OttoQueued' }, { '', 'OttoQueued' } },
    { { 'later', 'OttoQueued' }, { '  follow-up', 'OttoQueued' } },
  })
end)

t.describe('update', function()
  local bufnr = t.scratch({ '' }, 0)
  local s = session({ status = 'working', status_since = vim.uv.now() })
  local f = footer.new(bufnr, s, layout.new())
  f:update()
  t.check('counts while it works', f.timer ~= nil, true)
  local timer = f.timer
  f:update()
  t.check('with one timer', f.timer, timer)
  s.state.status = nil
  f:update()
  t.check('stops once it settles', f.timer, nil)
  t.check('closed', timer:is_closing(), true)
  t.check('and draws', drawn(bufnr), nil)

  s.state.status = 'working'
  s.state.queue = { { text = 'later', follow_up = true } }
  f:update()
  f:close()
  t.check('closing stops counting', f.timer, nil)
  t.check('and takes it out', drawn(bufnr), nil)
end)
