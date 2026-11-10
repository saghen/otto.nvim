-- ui/prompts.lua: the session's prompts, which the picker jumps to, and rewinding to them

local t = ...
local prompts = require('otto.ui.prompts')
local input = require('otto.input')

--- @param agent table
--- @return otto.View view Of a transcript with three prompts, two of them the same
local function view(agent)
  local bufnr = t.scratch({ '' }, 0)
  local transcript = t.render(bufnr, {
    { type = 'user', text = 'same', at = 0 },
    { type = 'text', text = 'ok', at = 0 },
    { type = 'user', text = 'two\nlines', at = 0 },
    { type = 'user', text = 'same', at = 0 },
  })
  return { bufnr = bufnr, transcript = transcript, session = { agent = agent } }
end

--- @param items otto.PromptItem[]
--- @return table[] what matters of them
local function shown(items)
  return vim.tbl_map(function(item) return { item.index, item.row, item.id } end, items)
end

t.describe('list', function()
  t.check('newest first, without ids', shown(prompts.list(view({}))), { { 3, 7, nil }, { 2, 4, nil }, { 1, 0, nil } })
  local points = { { id = 'p1', text = 'same' }, { id = 'p2', text = 'two\nlines ' }, { id = 'p3', text = 'same' } }
  local agent = { fork_points = function() return points end }
  t.check('ids by text, in order', shown(prompts.list(view(agent))), { { 3, 7, 'p3' }, { 2, 4, 'p2' }, { 1, 0, 'p1' } })
  table.remove(points, 2)
  t.check(
    'only of the points left',
    shown(prompts.list(view(agent))),
    { { 3, 7, 'p3' }, { 2, 4, nil }, { 1, 0, 'p1' } }
  )
end)

t.describe('rewind', function()
  local forked = {}
  local agent = {
    fork = function(_, id)
      table.insert(forked, id)
      return id == 'p1' and { id = 'fork', text = 'same' } or nil
    end,
  }
  local v = view(agent)
  local restarted
  local new_view = { bufnr = t.scratch({ '' }, 0) }
  function v.restart(_, id)
    restarted = id
    return new_view
  end

  local warned = t.notified(function() prompts.rewind(v, { index = 1, row = 0, text = 'same' }) end)
  t.check('without an id', { #warned, forked }, { 1, {} })
  prompts.rewind(v, { index = 1, row = 0, text = 'same', id = 'p2' })
  t.check('when the fork fails', { forked, restarted }, { { 'p2' }, nil })
  prompts.rewind(v, { index = 1, row = 0, text = 'same', id = 'p1' })
  t.check('switches to the fork', restarted, 'fork')
  t.check(
    'with the prompt in its input',
    vim.api.nvim_buf_get_lines(new_view.bufnr, input.row(new_view.bufnr), -1, false),
    { 'same' }
  )
end)

t.describe('pick', function()
  local v = view({})
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(v.bufnr), 0 })
  local asked = t.selecting(2, function() prompts.pick(v) end)
  t.check('prompt', asked and asked.prompt, 'Prompt: ')
  t.check('items', asked and asked.labels, { 'same  3', 'two  +1 lines  2', 'same  1' })
  t.check('jumps to it', vim.api.nvim_win_get_cursor(win), { 5, 0 })

  local rewound
  v.session.agent.fork = function(_, id) rewound = id end
  v.session.agent.fork_points = function() return { { id = 'p1', text = 'same' } } end
  -- the oldest, which is the only one with an id
  asked = t.selecting(3, function() prompts.pick(v, { rewind = true }) end)
  t.check('rewind prompt', asked and asked.prompt, 'Rewind to: ')
  -- in a task of its own, which starts once the picker's ends
  vim.wait(100, function() return rewound ~= nil end)
  t.check('rewinds to it', rewound, 'p1')

  local empty = { bufnr = t.scratch({ '' }, 0), session = { agent = {} } }
  empty.transcript = t.render(empty.bufnr, {})
  local warned
  asked = t.selecting(1, function()
    warned = t.notified(function() prompts.pick(empty) end)
  end)
  t.check('no prompts', { asked, warned }, { nil, { 'otto: no prompts yet' } })
end)
