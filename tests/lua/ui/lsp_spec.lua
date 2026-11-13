-- lsp.lua: completions of the input, over a scratch buffer and a fake view

local t = ...

if not pcall(require, 'blink.lib.lsp') then return t.skip('the server needs blink.lib, in BLINK_LIB') end

local buffers = require('otto.buffers')
local lsp = require('otto.ui.lsp')

local bufnr = t.scratch({ 'transcript', '' }, 1)
local view = {
  bufnr = bufnr,
  session = {
    provider = { name = 'fake' },
    agent = {},
    state = { commands = { { name = 'review', description = 'Review', arg_hint = '<pr>' }, { name = 'model' } } },
  },
}
buffers.set(bufnr, view)
lsp.attach(view)

--- @param line string Of the input, with the cursor at its end
--- @return lsp.CompletionList?
local function complete(line)
  vim.api.nvim_buf_set_lines(bufnr, 1, -1, false, { line })
  local results = vim.lsp.buf_request_sync(bufnr, 'textDocument/completion', {
    textDocument = { uri = vim.uri_from_bufnr(bufnr) },
    position = { line = 1, character = #line },
  }, 1000)
  local _, response = next(results or {})
  return response and response.result
end

--- @param list lsp.CompletionList?
local function edits(list)
  return vim.tbl_map(function(item) return item.textEdit.newText end, list and list.items or {})
end

t.describe('commands', function()
  local list = complete('/re')
  t.check("the agent's, without otto's", edits(list), { 'review' })
  t.check('replacing after the /', list.items[1].textEdit.range, {
    start = { line = 1, character = 1 },
    ['end'] = { line = 1, character = 3 },
  })
  t.check('complete', list.isIncomplete, false)
  t.check('only at the start of the input', edits(complete('text /re')), {})
end)

t.describe('paths', function()
  local cwd = vim.fn.getcwd()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir .. '/sub', 'p')
  vim.fn.writefile({}, dir .. '/b.lua')
  vim.fn.writefile({}, dir .. '/.hidden')
  vim.fn.writefile({}, dir .. '/sub/a.lua')
  vim.fn.chdir(dir)

  local list = complete('see @b')
  t.check('of the folder, whatever the name', edits(list), { 'b.lua', 'sub/' })
  t.check('incomplete, to ask again as the folder changes', list.isIncomplete, true)
  t.check('labelled by name', complete('@sub/').items[1].label, 'a.lua')
  t.check('with the folder', edits(complete('@sub/x')), { 'sub/a.lua' })
  t.check('hidden after a dot', edits(complete('@.')), { '.hidden' })
  t.check('only at the start of a word', edits(complete('a@b')), {})

  vim.fn.chdir(cwd)
  vim.fn.delete(dir, 'rf')
end)
