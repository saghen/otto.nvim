-- History of prompts, of every session and folder, which <M-p> and <M-n> step through for the current folder. What the
-- input held when it was left is kept, the draft included, until the next submit. Unsent prompts are saved when
-- their buffer unloads, and come back when the session opens again

local input = require('otto.input')
local jsonl = require('otto.jsonl')
local pick = require('otto.ui.pick')
local scroll = require('otto.ui.scroll')
local util = require('otto.util')

--- As of now, like `track.store_dir`, rather than when this loaded
--- @param name string
--- @return string
local function state_path(name) return vim.fs.joinpath(vim.fn.stdpath('state'), 'otto', name) end
local draft_days = 30 -- before a draft is dropped, like those of sessions that were never saved

--- @class otto.HistoryEntry
--- @field text string
--- @field cwd string
--- @field at integer Seconds since the epoch
--- @field session string Like pi://<id>

--- @class otto.Recall Where a session is in the history
--- @field entries otto.HistoryEntry[] Newest first, from when it started, with the draft at 0
--- @field index integer
--- @field edits table<otto.HistoryEntry, string> What the input held when it left an entry

local M = {}

--- @type otto.HistoryEntry[] Oldest first, which stay the same tables, since edits are keyed by them
local entries = {}
local offset = 0 -- bytes of the file read so far

local warned = false

--- Warns once of the history or the drafts that can't be saved
--- @param err? string
local function warn(err)
  if not warned then util.notify('history: ' .. tostring(err), vim.log.levels.WARN) end
  warned = true
end

--- Reads what other instances and sessions added since the last read
local function read_appended()
  local lines, restarted
  lines, offset, restarted = jsonl.read_appended(state_path('history.jsonl'), offset)
  -- like when it was replaced
  if restarted then entries = {} end
  for _, line in ipairs(lines) do
    local ok, entry = pcall(jsonl.decode, line)
    if ok and type(entry) == 'table' and type(entry.text) == 'string' then table.insert(entries, entry) end
  end
end

--- @param text string As submitted
--- @param session string Like pi://<id>
function M.add(text, session)
  -- a leading space keeps it out, like in shells
  if text:match('^%s') or vim.trim(text) == '' then return end
  vim.fn.mkdir(vim.fs.dirname(state_path('history.jsonl')), 'p')
  local file, err = io.open(state_path('history.jsonl'), 'a')
  if file == nil then return warn(err) end
  -- read back by `read_appended`, like those of other instances
  file:write(
    vim.json.encode({ text = vim.trim(text), cwd = vim.fn.getcwd(), at = os.time(), session = session }) .. '\n'
  )
  file:close()
end

--- @param cwd? string Of every folder when nil
--- @return otto.HistoryEntry[] newest first, without repeats
function M.list(cwd)
  read_appended()
  local list, seen = {}, {}
  for i = #entries, 1, -1 do
    local entry = entries[i]
    if (cwd == nil or entry.cwd == cwd) and not seen[entry.text] then
      seen[entry.text] = true
      table.insert(list, entry)
    end
  end
  return list
end

--- @param bufnr integer
--- @param text string
local function set_input(bufnr, text)
  vim.bo[bufnr].undolevels = vim.bo[bufnr].undolevels -- its own undo step, so that `u` brings back what was there
  input.set(bufnr, text)
  if vim.api.nvim_get_current_buf() ~= bufnr then return end
  vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(bufnr), #text:match('[^\n]*$') })
  scroll.follow(bufnr)
end

--- Keeps what the input holds, when it changed from the entry it shows
--- @param view otto.View
local function leave(view)
  local recall = view.recall
  local entry = recall.entries[recall.index]
  local text = vim.fn.prompt_getinput(view.bufnr)
  recall.edits[entry] = text ~= entry.text and text or nil
end

--- @param view otto.View
--- @return otto.Recall of the view, with the newest entries unless it's stepping through them
local function recall_of(view)
  local recall = view.recall or { index = 0, edits = {}, entries = {} }
  -- the newest entries, unless it's stepping through them
  if recall.index == 0 then
    local draft = recall.entries[0] or { text = '' }
    recall.entries = M.list(vim.fn.getcwd())
    recall.entries[0] = draft
  end
  view.recall = recall
  return recall
end

--- Steps through the history of the current folder, older for a positive count
--- @param view otto.View
--- @param count integer
function M.step(view, count)
  local recall = recall_of(view)
  local index = math.max(math.min(recall.index + count, #recall.entries), 0)
  if index == recall.index then return end
  leave(view)
  recall.index = index
  local entry = recall.entries[index]
  set_input(view.bufnr, recall.edits[entry] or entry.text)
end

--- Puts text into the input, keeping what it held like stepping does, so that <M-n> brings it back
--- @param view otto.View
--- @param entry otto.HistoryEntry | { text: string } Of the history, or of somewhere else, like a prompt to edit
function M.recall(view, entry)
  local recall = recall_of(view)
  leave(view)
  recall.index = 0
  for i, other in ipairs(recall.entries) do
    if other == entry then recall.index = i end
  end
  -- of another folder, or not of the history
  if recall.index == 0 then
    table.insert(recall.entries, 1, entry)
    recall.index = 1
  end
  recall.edits[entry] = nil
  set_input(view.bufnr, entry.text)
end

--- Writes the file whole, renamed into place so that another instance never reads half of it
--- @param file_path string
--- @param data string
local function write(file_path, data)
  vim.fn.mkdir(vim.fs.dirname(file_path), 'p')
  local temp = file_path .. '.' .. vim.uv.os_getpid()
  local file, err = io.open(temp, 'w')
  if file == nil then return warn(err) end
  file:write(data)
  file:close()
  local ok, rename_err = vim.uv.fs_rename(temp, file_path)
  if not ok then
    vim.uv.fs_unlink(temp)
    warn(rename_err)
  end
end

--- Picks a prompt from the history into the input, which shows the one under the cursor
--- @param view otto.View
--- @param opts? { all?: boolean } Of every folder
function M.pick(view, opts)
  local all = opts ~= nil and opts.all == true
  local bufnr = view.bufnr
  local original = vim.fn.prompt_getinput(bufnr)
  --- @param text string
  local function show(text)
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    -- outside of the undo history, which only keeps the prompt that's picked, even when it fails
    local undolevels = vim.bo[bufnr].undolevels
    vim.bo[bufnr].undolevels = -1
    local ok, err = pcall(input.set, bufnr, text)
    vim.bo[bufnr].undolevels = undolevels
    if not ok then error(err, 0) end
  end

  --- @param entry otto.HistoryEntry
  local function format(entry)
    local lines = vim.split(entry.text, '\n')
    local chunks = { { lines[1] } }
    if #lines > 1 then table.insert(chunks, { ('  +%d lines'):format(#lines - 1), 'Comment' }) end
    local notes = { { util.format_age(os.time() - entry.at), 'Comment' } }
    if all then table.insert(notes, 1, { util.short_path(entry.cwd) .. '  ', 'OttoPath' }) end
    return chunks, notes
  end

  pick.select({
    prompt = 'History: ',
    items = M.list(not all and vim.fn.getcwd() or nil),
    format = format,
    text = function(entry) return entry.text end,
    preview = function(entry) show(entry and entry.text or original) end,
    on_accept = function(entry)
      if not vim.api.nvim_buf_is_valid(bufnr) then return end
      show(original)
      M.recall(view, entry)
    end,
  })
end

--- @return table<string, { text: string, at: integer }> by buffer name
local function read_drafts()
  local file = io.open(state_path('drafts.json'), 'r')
  if file == nil then return {} end
  local ok, drafts = pcall(vim.json.decode, file:read('*a'))
  file:close()
  return ok and type(drafts) == 'table' and drafts or {}
end

--- Saves the unsent prompts of the sessions' buffers, or forgets them when they're empty
--- @param bufnrs integer[]
function M.save_drafts(bufnrs)
  local drafts = read_drafts()
  for name, draft in pairs(drafts) do
    if os.time() - draft.at > draft_days * 86400 then drafts[name] = nil end
  end
  for _, bufnr in ipairs(bufnrs) do
    local text = vim.fn.prompt_getinput(bufnr)
    drafts[vim.api.nvim_buf_get_name(bufnr)] = vim.trim(text) ~= '' and { text = text, at = os.time() } or nil
  end
  write(state_path('drafts.json'), vim.json.encode(drafts))
end

--- Puts back the unsent prompt of the session's buffer, unless the input has text already, like after a restart
--- @param bufnr integer
function M.restore_draft(bufnr)
  local drafts = read_drafts()
  local name = vim.api.nvim_buf_get_name(bufnr)
  if drafts[name] == nil then return end
  if vim.fn.prompt_getinput(bufnr) == '' then set_input(bufnr, drafts[name].text) end
  -- back in the input, which saves it again when its buffer unloads, unless it's sent
  drafts[name] = nil
  write(state_path('drafts.json'), vim.json.encode(drafts))
end

--- Forgets where the session was in the history, and what the input held, once it submits
--- @param view otto.View
function M.reset(view) view.recall = nil end

return M
