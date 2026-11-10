-- What an agent changed: its edits, and what else its calls changed when it's tracked, in the quickfix list, or as a
-- diff in a scratch buffer, where <CR> opens the file at the line under the cursor

local tools = require('otto.render.tools')
local track = require('otto.track')
local util = require('otto.util')

local M = {}

--- @class otto.ChangedFile : otto.NetChange What a call's changes did to a file, for the quickfix list
--- @field filename string Absolute
--- @field call? string
--- @field lnum integer The first changed line
--- @field added integer Lines
--- @field removed integer

--- What each call's changes did to their files, in the order they first changed, but not to files that are gone again
--- once all of them are done, unless they moved, like what Claude Code's sandbox makes for each command and removes
--- @param tracked otto.TrackedAgent
--- @param changes otto.Change[]
--- @return otto.ChangedFile[]
function M.changed_files(tracked, changes)
  local kept = {}
  for _, net in ipairs(track.net(changes)) do
    kept[net.path] = true
  end
  for i = #changes, 1, -1 do
    if changes[i].from and kept[changes[i].path] then kept[changes[i].from] = true end
  end
  local by_call, calls = {}, {}
  for _, change in ipairs(changes) do
    local key = change.call or ''
    if by_call[key] == nil then
      by_call[key] = {}
      table.insert(calls, key)
    end
    table.insert(by_call[key], change)
  end
  local files = {}
  for _, call in ipairs(calls) do
    for _, net in ipairs(vim.tbl_filter(function(net) return kept[net.path] end, track.net(by_call[call]))) do
      local before, after = tracked:contents(net)
      local hunks = vim.text.diff(before, after, { result_type = 'indices' }) --[[@as integer[][] ]]
      local file = vim.tbl_extend('error', net, {
        filename = vim.fs.joinpath(tracked.cwd, net.path),
        call = call ~= '' and call or nil,
        lnum = 1,
        added = 0,
        removed = 0,
      })
      for _, hunk in ipairs(hunks) do
        file.removed = file.removed + hunk[2]
        file.added = file.added + hunk[4]
      end
      if hunks[1] then file.lnum = math.max(hunks[1][3], 1) end
      table.insert(files, file)
    end
  end
  table.sort(files, function(a, b) return a.at < b.at end)
  return files
end

--- What the changes did, as a unified diff of each file
--- @param tracked otto.TrackedAgent
--- @param changes otto.Change[]
--- @return string[]
function M.diff(tracked, changes)
  local lines = {}
  for _, net in ipairs(track.net(changes)) do
    local before, after = tracked:contents(net)
    table.insert(lines, net.before and '--- a/' .. (net.from or net.path) or '--- /dev/null')
    table.insert(lines, net.after and '+++ b/' .. net.path or '+++ /dev/null')
    if before:find('%z') or after:find('%z') then
      table.insert(lines, 'Binary files differ')
    else
      local diff = vim.text.diff(before, after) --[[@as string]]
      vim.list_extend(lines, vim.split(diff, '\n', { trimempty = true }))
    end
  end
  return lines
end

--- @param file otto.ChangedFile
--- @param call? otto.ToolCall That made it
--- @return vim.quickfix.entry
local function changed_file_entry(file, call)
  local header = call and tools.header(call.tool, call.args) or { { file.cmd or '?' } }
  local text = util.join(header)
  if file.after == nil then
    text = text .. '  removed'
  else
    text = text .. ('  +%d -%d'):format(file.added, file.removed)
    if file.from then text = text .. '  from ' .. file.from end
  end
  return { filename = file.filename, lnum = file.lnum, text = text }
end

--- Files that the agent edited, at the first changed line, for the quickfix list, and what else its calls changed,
--- like commands, when it's tracked
--- @param events otto.Event[] The log
--- @param changed? otto.ChangedFile[]
--- @return vim.quickfix.entry[]
function M.quickfix_edits(events, changed)
  local by_call, others = {}, {}
  for _, file in ipairs(changed or {}) do
    local id = file.call
    if id then
      by_call[id] = by_call[id] or {}
      table.insert(by_call[id], file)
    else
      table.insert(others, file)
    end
  end

  local calls = {} --- @type table<string, otto.ToolCall>
  local edits = {} --- @type vim.quickfix.entry[]
  for _, event in ipairs(events) do
    if event.type == 'tool_call' then calls[event.id] = tools.display_call(event.tool, event.args) end
    local call = event.type == 'tool_result' and calls[event.id] or nil
    -- which results without a call don't have
    if call and event.diff ~= nil and call.args.path ~= nil then
      local _, first_changed = tools.format_diff(event.diff)
      local text = util.join(tools.diff_header(call, event.diff))
      -- a string, which `display_call` checked
      local path = call.args.path --[[@as string]]
      table.insert(edits, { filename = path, lnum = first_changed or 1, text = text })
    elseif call then
      for _, file in ipairs(by_call[event.id] or {}) do
        table.insert(edits, changed_file_entry(file, call))
      end
    end
    if call then by_call[event.id] = nil end
  end
  -- of calls still running, or of none
  for _, files in pairs(by_call) do
    vim.list_extend(others, files)
  end
  table.sort(others, function(a, b) return a.at < b.at end)
  for _, file in ipairs(others) do
    table.insert(edits, changed_file_entry(file, calls[file.call]))
  end
  return edits
end

--- Puts the session's edits in the quickfix list, and opens it
--- @param session otto.Session
function M.to_quickfix(session)
  local changed = session.tracked and M.changed_files(session.tracked, session.tracked.changes)
  local items = M.quickfix_edits(session.events, changed)
  vim.fn.setqflist({}, ' ', { title = session.state.id .. ' edits', items = items })
  vim.cmd.copen()
end

--- The file and line of the diff's line, in the new file
--- @param bufnr integer
--- @param diff_lnum integer Of the diff's line
--- @return string? path
--- @return integer? lnum
local function location(bufnr, diff_lnum)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, diff_lnum, false)
  -- the header of the next file, rather than a removed line that starts like one
  local next_line = vim.api.nvim_buf_get_lines(bufnr, diff_lnum, diff_lnum + 1, false)[1] or ''
  local next_path = lines[#lines]:match('^%-%-%- ') and next_line:match('^%+%+%+ b/(.*)$')
  if next_path then return next_path, 1 end
  local lnum, offset
  for i = #lines, 1, -1 do
    local line = lines[i]
    if lnum == nil and line:match('^@@') then
      lnum = tonumber(line:match('^@@ %-%d+,?%d* %+(%d+)')) or 1
      offset = 0
      for j = i + 1, #lines - 1 do
        if not vim.startswith(lines[j], '-') then offset = offset + 1 end
      end
    end
    local path = line:match('^%+%+%+ b/(.*)$')
    if path then return path, lnum and math.max(lnum + offset, 1) end
    if line:match('^%+%+%+ ') then return end
  end
end

--- @param session otto.Session
--- @param changes otto.Change[]
--- @param title string
function M.open(session, changes, title)
  local lines = M.diff(session.tracked, changes)
  if #lines == 0 then return util.notify('nothing changed', vim.log.levels.INFO) end
  vim.cmd.new()
  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].buftype = 'nofile'
  vim.bo[bufnr].bufhidden = 'wipe'
  vim.bo[bufnr].swapfile = false
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].filetype = 'diff'
  -- unless another shows the same changes, which keeps the name
  pcall(vim.api.nvim_buf_set_name, bufnr, ('otto-changes://%s'):format(title))
  vim.keymap.set('n', '<CR>', function()
    local path, lnum = location(bufnr, vim.fn.line('.'))
    if path == nil then return end
    vim.cmd.edit(vim.fn.fnameescape(vim.fs.joinpath(session.tracked.cwd, path)))
    if lnum then vim.api.nvim_win_set_cursor(0, { math.min(lnum, vim.api.nvim_buf_line_count(0)), 0 }) end
  end, { buffer = bufnr, desc = 'Open the file at the line' })
end

--- What the call under the cursor changed, or else the session
--- @param view otto.View
function M.open_at_cursor(view)
  local session = view.session
  local call = view.transcript:call_at(vim.fn.line('.') - 1)
  if call and call.id then
    local changes = vim.tbl_filter(function(change) return change.call == call.id end, session.tracked.changes)
    return M.open(session, changes, call.id)
  end
  M.open(session, session.tracked.changes, session.state.id)
end

return M
