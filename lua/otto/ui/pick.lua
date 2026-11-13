-- Pickers, in minibuffer.nvim when it's set up, with notes aligned on the right and previews. Otherwise in
-- `vim.ui.select`, without them

local buffers = require('otto.buffers')
local providers = require('otto.providers')
local uri = require('otto.uri')
local util = require('otto.util')

--- @class otto.Picker
--- @field prompt string
--- @field items any[]
--- @field format fun(item: any): otto.Chunks, otto.Chunks? The item, and its notes on the right
--- @field text? fun(item: any): string What the query matches, the item as it's formatted by default
--- @field preview? fun(item: any?) Of the item under the cursor, nil when there's none or the picker is cancelled
--- @field fuzzy? boolean Whether the query matches fuzzily, best first, instead of by its words. With `text`, the
--- items whose formatted lines have its words come after
--- @field on_accept fun(item: any)

local M = {}

--- Truncates the chunks to the width, and pads them up to it
--- @param chunks otto.Chunks
--- @param width integer
--- @return otto.Chunks
local function fit(chunks, width)
  local fitted, used = {}, 0
  for _, chunk in ipairs(chunks) do
    local line = chunk[1]:gsub('\n.*', '')
    local chunk_width = vim.api.nvim_strwidth(line)
    if used + chunk_width > width then
      -- by the cells of each character, which wide ones take two of, and padded when one doesn't fit
      local part = ''
      for _, char in ipairs(vim.fn.split(line, '\\zs')) do
        local char_width = vim.api.nvim_strwidth(char)
        if used + char_width > width - 1 then break end
        part, used = part .. char, used + char_width
      end
      table.insert(fitted, { part .. '…', chunk[2] })
      table.insert(fitted, { (' '):rep(width - used - 1) })
      return fitted
    end
    table.insert(fitted, { line, chunk[2] })
    used = used + chunk_width
  end
  table.insert(fitted, { (' '):rep(width - used) })
  return fitted
end

--- Keeps the items that contain every word of the query, in any order and ignoring case unless the word has
--- capitals, like Doom Emacs's orderless. Words starting with `!` exclude the items that contain them
--- @param items any[]
--- @param texts table<any, string>
--- @param query string
--- @return any[]
local function filter(items, texts, query)
  local words = vim.split(query, '%s+', { trimempty = true })
  return vim.tbl_filter(function(item)
    for _, word in ipairs(words) do
      local exclude = word:sub(1, 1) == '!'
      if exclude then word = word:sub(2) end
      local item_text = word:find('%u') and texts[item] or texts[item]:lower()
      if word ~= '' and (item_text:find(word, 1, true) ~= nil) == exclude then return false end
    end
    return true
  end, items)
end

--- Keeps the items that match the query fuzzily, best first, then those whose lines have its words
--- @param items any[]
--- @param texts table<any, string>
--- @param lines? table<any, string> Of the items as they're formatted, when that's more than their texts
--- @param query string
--- @return any[]
local function fuzzy(items, texts, lines, query)
  if query == '' then return items end
  -- by index, since items come back from Vim as copies
  local entries = {}
  for index, item in ipairs(items) do
    entries[index] = { text = texts[item], index = index }
  end
  local matched, seen = {}, {}
  for _, entry in ipairs(vim.fn.matchfuzzy(entries, query, { key = 'text' })) do
    local item = items[entry.index]
    table.insert(matched, item)
    seen[item] = true
  end
  for _, item in ipairs(lines and filter(items, lines, query) or {}) do
    if not seen[item] then table.insert(matched, item) end
  end
  return matched
end

--- @param fn fun(...)
local function safely(fn, ...)
  -- since minibuffer.nvim drops their errors
  local ok, err = pcall(fn, ...)
  if not ok then util.notify(tostring(err)) end
end

--- @param picker otto.Picker
local function fallback(picker)
  local function format_item(item)
    local chunks, notes = picker.format(item)
    return util.join(chunks) .. (notes and '  ' .. util.join(notes) or '')
  end
  vim.ui.select(picker.items, { prompt = picker.prompt, format_item = format_item }, function(item)
    if item ~= nil then picker.on_accept(item) end
  end)
end

--- @param picker otto.Picker
function M.select(picker)
  local ok, minibuffer = pcall(require, 'minibuffer')
  -- which has no public way to tell, so a change there falls back rather than breaks
  local has_state, state = pcall(require, 'minibuffer.internal.state')
  if not ok or not has_state or not state.initialized then return fallback(picker) end

  local texts, lines = {}, {} --- @type table<any, string>, table<any, string>
  for _, item in ipairs(picker.items) do
    lines[item] = util.join((picker.format(item)))
    texts[item] = picker.text and picker.text(item) or lines[item]
  end
  local previewed --- @type any
  local function preview(item)
    if picker.preview == nil or item == previewed then return end
    previewed = item
    safely(picker.preview, item)
  end

  minibuffer.select({
    prompt = picker.prompt,
    max_height = 15,
    fetch_fn = function(_, callback) callback(picker.items) end,
    filter_fn = function(ctx)
      if not picker.fuzzy then return filter(ctx.items, texts, ctx.input) end
      return fuzzy(ctx.items, texts, picker.text and lines, ctx.input)
    end,
    format_fn = function(item)
      local chunks, notes = picker.format(item)
      notes = notes or {}
      -- less the margins of the window
      local width = vim.o.columns - 4 - vim.api.nvim_strwidth(util.join(notes))
      local line = vim.list_extend(fit(chunks, width), { { '  ' } })
      return vim.tbl_map(function(chunk) return { text = chunk[1], hl = chunk[2] } end, vim.list_extend(line, notes))
    end,
    on_change = function(_, item) preview(item) end,
    on_accept = function(selection) safely(picker.on_accept, selection[1].item) end,
    -- before accepting too, and when it's cancelled or closed for another picker
    on_close = function() preview(nil) end,
  })
end

--- Picks an open session, most recently used first but the visible ones and then the current one last, or with the
--- saved sessions of the current folder too, below the open ones
--- @param opts? { saved?: boolean }
function M.sessions(opts)
  local with_saved = opts ~= nil and opts.saved == true
  --- @class otto.SessionItem
  --- @field uri string
  --- @field provider string
  --- @field title string
  --- @field view? otto.View When it's open
  --- @field saved? otto.SavedSession When it's saved

  local current = vim.api.nvim_get_current_buf()
  local visible = {} --- @type table<integer, boolean>
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    visible[vim.api.nvim_win_get_buf(win)] = true
  end
  --- @param bufnr integer
  local function rank(bufnr)
    if with_saved then return 0 end
    return bufnr == current and 2 or visible[bufnr] and 1 or 0
  end

  local function items()
    local list, by_uri = {}, {} --- @type otto.SessionItem[], table<string, otto.SessionItem>
    local infos = vim.tbl_filter(
      function(buf) return buffers.get(buf.bufnr) ~= nil end,
      vim.fn.getbufinfo({ bufloaded = 1 })
    )
    table.sort(infos, function(a, b)
      local rank_a, rank_b = rank(a.bufnr), rank(b.bufnr)
      if rank_a ~= rank_b then return rank_a < rank_b end
      return a.lastused > b.lastused
    end)
    for _, buf in ipairs(infos) do
      local view = buffers.get(buf.bufnr)
      local session = view.session
      local item = { uri = buf.name, provider = session.provider.name, title = session.state.name, view = view }
      table.insert(list, item)
      by_uri[buf.name] = item
    end
    for _, saved in ipairs(with_saved and providers.saved() or {}) do
      local saved_uri = uri.format(saved.provider, saved.id)
      local item = by_uri[saved_uri]
      if item == nil then
        table.insert(list, { uri = saved_uri, provider = saved.provider, title = saved.title, saved = saved })
      else
        item.title, item.saved = item.title or saved.title, saved
      end
    end
    return list
  end

  --- @param item otto.SessionItem
  local function format(item)
    local id = uri.id(item.uri)
    -- like the ids of Claude Code and Codex, which only need their end to be told apart
    local short = util.is_uuid(id) and id:sub(-8) or id
    local chunks = { { providers.get(item.provider).icon, 'OttoWinbarIcon' }, { item.title or id } }
    local notes = {}
    local state = item.view and item.view.session.state
    if state and state.status then
      local elapsed = math.floor((vim.uv.now() - state.status_since) / 1000)
      table.insert(notes, { state.status .. ' ' .. util.format_duration(elapsed), 'OttoStatus' })
    elseif state and with_saved then
      table.insert(notes, { 'open', 'OttoStatus' })
    end
    if item.saved then
      local age = util.format_age(os.time() - item.saved.modified)
      table.insert(notes, { (' %3d msgs %4s'):format(item.saved.message_count, age) })
    end
    table.insert(notes, { '  ' .. short, 'Comment' })
    return chunks, notes
  end

  --- @param item otto.SessionItem
  local function open(item)
    if item.view then return vim.cmd.buffer(item.view.bufnr) end
    vim.cmd.edit(item.uri)
  end

  M.select({ prompt = 'Session: ', items = items(), format = format, on_accept = open })
end

return M
