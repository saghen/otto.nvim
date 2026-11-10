-- ui/history.lua: the history of prompts, stepping through it in the input, its picker, and unsent prompts

local t = ...
local history = require('otto.ui.history')
local input = require('otto.input')

local cwd = vim.fn.getcwd()
local state = vim.fs.joinpath(vim.fn.stdpath('state'), 'otto')

--- Changes to a folder of its own, whose history starts empty
--- @return string
local function folder()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  vim.cmd.cd(dir)
  return vim.fn.getcwd()
end

--- @param entries otto.HistoryEntry[]
--- @return string[]
local function texts(entries)
  local list = {}
  -- without the draft, at 0 in a recall's
  for _, entry in ipairs(entries) do
    table.insert(list, entry.text)
  end
  return list
end

--- @param text string
local function append(text)
  local file = assert(io.open(vim.fs.joinpath(state, 'history.jsonl'), 'a'))
  file:write(text)
  file:close()
end

--- @return otto.View view Over a buffer with a transcript and a draft in the input
local function view() return { bufnr = t.scratch({ 'transcript', 'draft' }, 1) } end

--- @param bufnr integer
--- @return string what the input holds
local function typed(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, input.row(bufnr), -1, false)
  return table.concat(lines, '\n')
end

t.describe('add and list', function()
  local dir = folder()
  history.add('first', 'pi://a')
  history.add(' secret', 'pi://a')
  history.add('  \n', 'pi://a')
  history.add('second\n', 'pi://b')
  history.add('first', 'pi://c')
  local list = history.list(dir)
  t.check('newest first, without repeats or what starts with a space', texts(list), { 'first', 'second' })
  t.check('the newest of repeats', list[1].session, 'pi://c')
  t.check('of the folder', list[2].cwd, dir)

  -- another instance, which is writing its next line
  append(
    vim.json.encode({ text = 'elsewhere', cwd = '/other', at = 1, session = 'pi://d' }) .. '\nnot json\n{"text":"ha'
  )
  t.check('of the folder only', texts(history.list(dir)), { 'first', 'second' })
  t.check('of every folder, without broken lines', texts(history.list()), { 'elsewhere', 'first', 'second' })
  append('lf","cwd":"/other","at":2,"session":"pi://d"}\n')
  t.check('once the line is whole', history.list()[1].text, 'half')

  -- replaced, like by another instance
  local path = vim.fs.joinpath(state, 'history.jsonl')
  assert(vim.fn.writefile({ vim.json.encode({ text = 'only', cwd = dir, at = 1, session = 'pi://e' }) }, path) == 0)
  t.check('read again once replaced', texts(history.list()), { 'only' })
end)

t.describe('step', function()
  folder()
  for _, text in ipairs({ 'one', 'two', 'three' }) do
    history.add(text, 'pi://a')
  end
  local v = view()
  local bufnr = v.bufnr
  history.step(v, 1)
  t.check('newest', vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), { 'transcript', 'three' })
  t.check('cursor at its end', vim.api.nvim_win_get_cursor(0), { 2, 4 }) -- the last character in normal mode
  history.step(v, 1)
  input.set(bufnr, 'two\nedited')
  history.step(v, 1)
  t.check('older', typed(bufnr), 'one')
  history.step(v, 1)
  t.check('not past the oldest', v.recall.index, 3)
  history.step(v, -1)
  t.check('keeps what was edited', typed(bufnr), 'two\nedited')
  history.step(v, -5)
  t.check('back to the draft', typed(bufnr), 'draft')
  t.check('at the draft', v.recall.index, 0)
  history.step(v, 1)
  t.check('the entry, unedited', typed(bufnr), 'three')
  vim.cmd('silent normal! u')
  t.check('undoes to what the input held', typed(bufnr), 'draft')

  history.reset(v)
  t.check('reset', v.recall, nil)
end)

t.describe('insert', function()
  folder()
  for _, text in ipairs({ 'one', 'two', 'three' }) do
    history.add(text, 'pi://a')
  end
  local v = view()
  history.recall(v, { text = 'a prompt\nto edit' })
  t.check('into the input', typed(v.bufnr), 'a prompt\nto edit')
  t.check('before the history', texts(v.recall.entries), { 'a prompt\nto edit', 'three', 'two', 'one' })
  history.step(v, -1)
  t.check('the draft comes back', typed(v.bufnr), 'draft')

  history.reset(v)
  local entries = history.list(vim.fn.getcwd())
  history.recall(v, entries[2])
  t.check('of the history, where it is', v.recall.index, 2)
  history.step(v, 1)
  t.check('steps on from it', typed(v.bufnr), 'one')
end)

t.describe('pick', function()
  local dir = folder()
  history.add('one', 'pi://a')
  history.add('two\nlines', 'pi://a')
  local v = view()
  local asked = t.selecting(1, function() history.pick(v) end)
  t.check('prompt', asked and asked.prompt, 'History: ')
  t.check('items', asked and asked.labels, { 'two  +1 lines  now', 'one  now' })
  t.check('accepted into the input', typed(v.bufnr), 'two\nlines')
  t.check('where it is in the history', v.recall.index, 1)

  history.reset(v)
  input.set(v.bufnr, 'kept')
  t.selecting(nil, function() history.pick(v) end)
  t.check('cancelled', typed(v.bufnr), 'kept')

  asked = t.selecting(nil, function() history.pick(v, { all = true }) end)
  t.check(
    'of every folder, with theirs',
    asked and asked.labels[1],
    'two  +1 lines  ' .. vim.fn.fnamemodify(dir, ':~:.') .. '  now'
  )
end)

t.describe('preview', function()
  local pick = require('otto.ui.pick')
  local select = pick.select
  local picker
  pick.select = function(opts) picker = opts end
  local v = view()
  history.pick(v)
  pick.select = select
  picker.preview({ text = 'shown' })
  t.check('shows the prompt in the input', typed(v.bufnr), 'shown')
  vim.bo[v.bufnr].undolevels = 100
  vim.bo[v.bufnr].modifiable = false
  t.check('fails in a buffer that can not change', pcall(picker.preview, { text = 'x' }), false)
  t.check('with its undo back', vim.bo[v.bufnr].undolevels, 100)
  vim.bo[v.bufnr].modifiable = true
end)

t.describe('drafts', function()
  local path = vim.fs.joinpath(state, 'drafts.json')
  local day = 86400
  vim.fn.mkdir(state, 'p')
  local old = { text = 'old', at = os.time() - 31 * day }
  local recent = { text = 'recent', at = os.time() - day }
  assert(vim.fn.writefile({ vim.json.encode({ ['pi://old'] = old, ['pi://recent'] = recent }) }, path) == 0)

  local unsent = t.scratch({ 'transcript', 'unsent', 'prompt' }, 1)
  vim.api.nvim_buf_set_name(unsent, 'pi://unsent')
  local empty = t.scratch({ 'transcript', '  ' }, 1)
  vim.api.nvim_buf_set_name(empty, 'pi://recent')
  history.save_drafts({ unsent, empty })
  local saved = vim.json.decode(table.concat(vim.fn.readfile(path), '\n'))
  t.check('saved, without the old or the emptied', vim.tbl_keys(saved), { 'pi://unsent' })
  t.check('text', saved['pi://unsent'].text, 'unsent\nprompt')

  input.set(unsent, '')
  history.restore_draft(unsent)
  t.check('restored', typed(unsent), 'unsent\nprompt')
  t.check('forgotten once restored', vim.json.decode(table.concat(vim.fn.readfile(path), '\n')), vim.empty_dict())

  history.save_drafts({ unsent })
  input.set(unsent, 'typed')
  history.restore_draft(unsent)
  t.check('not over what the input has', typed(unsent), 'typed')
  t.check('but forgotten', vim.json.decode(table.concat(vim.fn.readfile(path), '\n')), vim.empty_dict())

  assert(vim.fn.writefile({ 'not json' }, path) == 0)
  history.save_drafts({ unsent })
  t.check(
    'over a broken file',
    vim.tbl_keys(vim.json.decode(table.concat(vim.fn.readfile(path), '\n'))),
    { 'pi://unsent' }
  )
end)

vim.cmd.cd(cwd)
