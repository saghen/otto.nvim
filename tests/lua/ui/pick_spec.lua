-- Pickers, in a fake minibuffer.nvim that keeps what it's given, and in `vim.ui.select` without it

local t = ...
local pick = require('otto.ui.pick')

--- @return table? opts What the picker gave minibuffer.nvim
local function minibuffer(fn)
  local given
  package.loaded['minibuffer'] = { select = function(opts) given = opts end }
  package.loaded['minibuffer.internal.state'] = { initialized = true }
  local ok, err = pcall(fn)
  package.loaded['minibuffer'] = nil
  package.loaded['minibuffer.internal.state'] = nil
  assert(ok, err)
  return given
end

--- @param items string[]
--- @param extra? table
--- @return otto.Picker
local function picker(items, extra)
  return vim.tbl_extend('force', {
    prompt = 'Pick: ',
    items = items,
    format = function(item) return { { item } }, { { 'note' } } end,
    on_accept = function() end,
  }, extra or {})
end

t.describe('filter', function()
  local items = { 'Fix the bug', 'add tests', 'fix docs' }
  local opts = minibuffer(function() pick.select(picker(items)) end)
  local function filter(input) return opts.filter_fn({ items = items, input = input }) end
  t.check('every word, in any order', filter('the fix'), { 'Fix the bug' })
  t.check('ignoring case', filter('fix'), { 'Fix the bug', 'fix docs' })
  t.check('unless it has capitals', filter('Fix'), { 'Fix the bug' })
  t.check('excluding words with !', filter('fix !docs'), { 'Fix the bug' })
  t.check('everything without a query', filter('  '), items)

  local by_text = minibuffer(function()
    pick.select(picker(items, { text = function(item) return item:upper() end }))
  end)
  t.check('of the text when given', by_text.filter_fn({ items = items, input = 'ADD' }), { 'add tests' })

  local fuzzy = minibuffer(function() pick.select(picker({ 'lua/otto/init.lua', 'README.md' }, { fuzzy = true })) end)
  t.check('fuzzily', fuzzy.filter_fn({ items = { 'lua/otto/init.lua', 'README.md' }, input = 'oinit' }), {
    'lua/otto/init.lua',
  })
  t.check('fuzzily without a query', #fuzzy.filter_fn({ items = { 'a', 'b' }, input = '' }), 2)
end)

t.describe('format', function()
  local columns = vim.o.columns
  vim.o.columns = 24
  local opts = minibuffer(function() pick.select(picker({})) end)
  local function text(item)
    return table.concat(vim.tbl_map(function(chunk) return chunk.text end, opts.format_fn(item)))
  end
  -- 24 less 4 for the margins and 4 for the note, then two spaces before it
  t.check('padded to the notes', text('short'), 'short' .. (' '):rep(11) .. '  note')
  t.check('truncated', text('a much longer item than fits'), 'a much longer i…  note')
  t.check('to its first line', text('first\nsecond'), 'first' .. (' '):rep(11) .. '  note')
  t.check('by cells', text('漢字漢字漢字漢字漢字'), '漢字漢字漢字漢… ' .. '  note')
  vim.o.columns = columns
end)

t.describe('callbacks', function()
  local previewed, accepted = {}, {}
  local opts = minibuffer(function()
    pick.select(picker({ 'a', 'b' }, {
      preview = function(item) table.insert(previewed, item or 'none') end,
      on_accept = function(item)
        if item == 'bad' then error('broken', 0) end
        table.insert(accepted, item)
      end,
    }))
  end)
  opts.on_change(nil, 'a')
  opts.on_change(nil, 'a')
  opts.on_change(nil, 'b')
  opts.on_close()
  t.check('previews each once, and none once closed', previewed, { 'a', 'b', 'none' })
  opts.on_accept({ { item = 'a' } })
  t.check('accepts', accepted, { 'a' })
  t.check('reports errors', t.notified(function() opts.on_accept({ { item = 'bad' } }) end), { 'otto: broken' })
  local fetched
  opts.fetch_fn(nil, function(items) fetched = items end)
  t.check('fetches the items', fetched, { 'a', 'b' })
end)

t.describe('fallback', function()
  local accepted
  local function select(choice)
    return t.selecting(choice, function()
      pick.select(picker({ 'a', 'b' }, { on_accept = function(item) accepted = item end }))
    end)
  end
  local asked = select(2)
  t.check('in vim.ui.select', { asked.prompt, asked.labels }, { 'Pick: ', { 'a  note', 'b  note' } })
  t.check('accepts', accepted, 'b')
  accepted = nil
  select(nil)
  t.check('not when cancelled', accepted, nil)
  package.loaded['minibuffer'] = { select = function() error('not set up') end }
  package.loaded['minibuffer.internal.state'] = { initialized = false }
  t.check('until minibuffer.nvim is set up', select(1).labels, { 'a  note', 'b  note' })
  package.loaded['minibuffer'] = nil
  package.loaded['minibuffer.internal.state'] = nil
end)

t.describe('files', function()
  local cwd = vim.fn.getcwd()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir .. '/sub', 'p')
  vim.fn.writefile({}, dir .. '/b.lua')
  vim.fn.writefile({}, dir .. '/sub/a.lua')
  vim.fn.system({ 'git', 'init', '-q', dir })
  vim.fn.chdir(dir)
  local opts
  t.run(function()
    opts = minibuffer(function()
      pick.files(function() end)
    end)
  end)
  vim.fn.chdir(cwd)
  vim.fn.delete(dir, 'rf')
  t.check('of the folder, sorted', opts.fetch_fn and (function()
    local items
    opts.fetch_fn(nil, function(list) items = list end)
    return items
  end)(), { 'b.lua', 'sub/a.lua' })
  local chunks = opts.format_fn('sub/a.lua')
  t.check('the folder dimmed', { chunks[1].text, chunks[1].hl, chunks[2].text }, { 'sub/', 'Comment', 'a.lua' })
end)
