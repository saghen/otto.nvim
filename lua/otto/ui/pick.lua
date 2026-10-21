-- Pickers, in minibuffer.nvim when it's set up, with notes aligned on the right, previews and actions on their keys.
-- Otherwise in `vim.ui.select`, without them

local util = require('otto.util')

--- @class otto.Picker
--- @field prompt string
--- @field items fun(): any[] Called again when an action refreshes the picker
--- @field format fun(item: any): otto.Chunks, otto.Chunks? The item, and its notes on the right
--- @field preview? fun(item: any?) Of the item under the cursor, nil when there's none or the picker is cancelled
--- @field actions? otto.PickerAction[]
--- @field on_accept fun(item: any)
--- @field on_cancel? fun()

--- @class otto.PickerAction
--- @field key string In insert mode, like "<M-d>"
--- @field desc? string | fun(): string For the footer, which skips it without one
--- @field run fun(item: any?, picker: otto.PickerControl)

--- @class otto.PickerControl
--- @field close fun(fn?: fun()) Calls `fn` once it's closed, after the preview is cancelled
--- @field refresh fun() Gets the items again
--- @field move fun(delta: integer)

local M = {}

local units = { { 'mo', 30 * 86400 }, { 'w', 7 * 86400 }, { 'd', 86400 }, { 'h', 3600 }, { 'm', 60 } }

--- @param seconds integer
--- @return string like "4d"
function M.age(seconds)
  for _, unit in ipairs(units) do
    if seconds >= unit[2] then return math.floor(seconds / unit[2]) .. unit[1] end
  end
  return 'now'
end

--- @param chunks otto.Chunks
--- @return string
local function text(chunks)
  return table.concat(vim.tbl_map(function(chunk) return chunk[1] end, chunks))
end

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
      local part = vim.fn.strcharpart(line, 0, math.max(width - used - 1, 0))
      table.insert(fitted, { part .. '…', chunk[2] })
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
    return text(chunks) .. (notes and '  ' .. text(notes) or '')
  end
  vim.ui.select(picker.items(), { prompt = picker.prompt, format_item = format_item }, function(item)
    if item ~= nil then return picker.on_accept(item) end
    if picker.on_cancel then picker.on_cancel() end
  end)
end

--- @param picker otto.Picker
function M.select(picker)
  local backend = require('otto.config').picker
  if backend == 'vim_ui' then return fallback(picker) end
  local ok, minibuffer = pcall(require, 'minibuffer')
  if not ok or not require('minibuffer.internal.state').initialized then
    assert(backend ~= 'minibuffer', 'otto: minibuffer is not set up')
    return fallback(picker)
  end

  local items, texts --- @type any[]?, table<any, string>
  local previewed --- @type any
  local function preview(item)
    if picker.preview == nil or item == previewed then return end
    previewed = item
    safely(picker.preview, item)
  end

  minibuffer.select({
    prompt = picker.prompt,
    max_height = 15,
    fetch_fn = function(_, callback)
      if items == nil then
        items, texts = picker.items(), {}
        for _, item in ipairs(items) do
          texts[item] = text((picker.format(item)))
        end
      end
      callback(items)
    end,
    filter_fn = function(ctx) return filter(ctx.items, texts, ctx.input) end,
    format_fn = function(item)
      local chunks, notes = picker.format(item)
      notes = notes or {}
      -- less the margins of the window
      local width = vim.o.columns - 4 - vim.api.nvim_strwidth(text(notes))
      local line = vim.list_extend(fit(chunks, width), { { '  ' } })
      return vim.tbl_map(function(chunk) return { text = chunk[1], hl = chunk[2] } end, vim.list_extend(line, notes))
    end,
    footer_fn = function(ctx)
      local footer = { { (' %d '):format(#ctx.items), 'Normal' } }
      for _, action in ipairs(picker.actions or {}) do
        local desc = type(action.desc) == 'function' and action.desc() or action.desc
        if desc then table.insert(footer, { (' %s %s '):format(action.key:gsub('[<>]', ''), desc), 'Comment' }) end
      end
      return footer
    end,
    on_change = function(_, item) preview(item) end,
    on_accept = function(selection) safely(picker.on_accept, selection[1].item) end,
    on_cancel = function()
      preview(nil)
      if picker.on_cancel then safely(picker.on_cancel) end
    end,
    on_start = function(session, keyset)
      --- @type otto.PickerControl
      local control = {
        close = function(fn)
          session:close(function()
            preview(nil)
            if fn then safely(fn) end
          end)
        end,
        refresh = function()
          items = nil
          session:refresh_results()
        end,
        move = function(delta) session:move(delta) end,
      }
      for _, action in ipairs(picker.actions or {}) do
        keyset('i', action.key, function() safely(action.run, session:get_selected(), control) end)
      end
    end,
  })
end

--- Picks an open or saved session of the current folder, open ones first, most recently used first
function M.sessions()
  local providers = require('otto.providers')
  local sessions = require('otto.session').sessions

  --- @class otto.SessionItem
  --- @field uri string
  --- @field provider string
  --- @field title string
  --- @field session? otto.Session When it's open
  --- @field info? otto.SessionInfo When it's saved
  --- @field child? boolean Whether it's a subagent's, below its parent

  local function items()
    local list, by_uri = {}, {} --- @type otto.SessionItem[], table<string, otto.SessionItem>
    local infos = vim.fn.getbufinfo({ bufloaded = 1 })
    table.sort(infos, function(a, b) return a.lastused > b.lastused end)
    for _, buf in ipairs(infos) do
      local session = sessions[buf.bufnr]
      -- subagents' sessions go below their parent's
      if session ~= nil and session.state.parent == nil then
        local item = { uri = buf.name, provider = session.provider.name, title = session.state.name, session = session }
        table.insert(list, item)
        by_uri[buf.name] = item
      end
    end
    for i = #list, 1, -1 do
      local parent = list[i].uri
      for _, buf in ipairs(infos) do
        local child = sessions[buf.bufnr]
        if child and child.state.parent == parent then
          local item = { uri = buf.name, provider = child.provider.name, title = child.state.name, session = child }
          item.child = true
          table.insert(list, i + 1, item)
        end
      end
    end
    for _, info in ipairs(providers.list()) do
      local uri = info.provider .. '://' .. info.id
      local item = by_uri[uri]
      if item == nil then
        table.insert(list, { uri = uri, provider = info.provider, title = info.title, info = info })
      else
        item.title, item.info = item.title or info.title, info
      end
    end
    return list
  end

  --- @param item otto.SessionItem
  local function format(item)
    local id = item.uri:match('://(.+)')
    -- the ids of Claude Code and Codex are UUIDs, which only need their end to be told apart
    local short = item.provider == 'pi' and id or id:sub(-8)
    local chunks = { { providers.get(item.provider).icon, 'OttoWinbarIcon' }, { item.title or id } }
    if item.child then chunks = { { '    ' }, { item.title or id } } end
    local notes = {}
    local state = item.session and item.session.state
    local subagents = state and #vim.tbl_filter(function(other) return other.kind == 'subagent' end, state.background)
    if subagents and subagents > 0 then
      table.insert(notes, { ('%d subagent%s  '):format(subagents, subagents == 1 and '' or 's'), 'OttoStatus' })
    end
    if state and state.working then
      local elapsed = math.floor((vim.uv.now() - state.since) / 1000)
      table.insert(notes, { state.working .. ' ' .. require('otto.render.tools').duration(elapsed), 'OttoStatus' })
    elseif state then
      table.insert(notes, { 'open', 'OttoStatus' })
    end
    if item.info then
      table.insert(notes, { (' %3d msgs %4s'):format(item.info.messages, M.age(os.time() - item.info.modified)) })
    end
    table.insert(notes, { '  ' .. short, 'Comment' })
    return chunks, notes
  end

  --- @param item otto.SessionItem
  local function open(item)
    if item.session then return vim.cmd.buffer(item.session.bufnr) end
    vim.cmd.edit(item.uri)
  end

  M.select({
    prompt = 'Session: ',
    items = items,
    format = format,
    on_accept = open,
    actions = {
      {
        key = '<M-v>',
        desc = 'vsplit',
        run = function(item, picker)
          if item == nil then return end
          picker.close(function()
            vim.cmd.vsplit()
            open(item)
          end)
        end,
      },
      {
        key = '<M-y>',
        desc = 'yank id',
        run = function(item, picker)
          if item == nil then return end
          picker.close(function() vim.fn.setreg(vim.v.register, item.uri:match('://(.+)')) end)
        end,
      },
    },
  })
end

return M
