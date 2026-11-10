-- The prompts of a session: jumping to them, and rewinding the session to them, for agents that can. Rewinding forks
-- the session, and switches the buffer to the fork, so the session it left stays saved

local history = require('otto.ui.history')
local pick = require('otto.ui.pick')
local util = require('otto.util')

local M = {}

--- @class otto.PromptItem : otto.TranscriptPrompt
--- @field index integer Of the prompt in the session, from 1
--- @field id? string To fork from, when the agent can

--- The prompts of the transcript, with the ids that the agent forks from, which only match by their text
--- @async
--- @param view otto.View
--- @return otto.PromptItem[] newest first
function M.list(view)
  local prompts = view.transcript:prompts() --[[@as otto.PromptItem[] ]]
  local points = view.session.agent.fork_points and view.session.agent:fork_points() or {}
  local next_point = 1
  for i, prompt in ipairs(prompts) do
    prompt.index = i
    for j = next_point, #points do
      if vim.trim(points[j].text) == vim.trim(prompt.text) then
        prompt.id, next_point = points[j].id, j + 1
        break
      end
    end
  end
  return vim.fn.reverse(prompts)
end

--- Switches the buffer to a fork of the session from before the prompt, with the prompt in the input to edit
--- @async
--- @param view otto.View
--- @param prompt otto.PromptItem
function M.rewind(view, prompt)
  if prompt.id == nil then return util.notify("the agent can't rewind to this prompt", vim.log.levels.WARN) end
  local fork = view.session.agent:fork(prompt.id)
  if fork == nil then return end
  local forked = view:restart(fork.id)
  if forked ~= nil then history.recall(forked, { text = fork.text }) end
end

--- Picks a prompt of the session, which the transcript scrolls to
--- @param view otto.View
--- @param opts? { rewind?: boolean } Whether accepting rewinds to it, instead of jumping to it
function M.pick(view, opts)
  local rewind = opts ~= nil and opts.rewind == true
  util.run_task(function()
    local prompts = M.list(view)
    if #prompts == 0 then return util.notify('no prompts yet', vim.log.levels.WARN) end
    -- the current one, of the windows that show the session
    local win = vim.api.nvim_get_current_buf() == view.bufnr and vim.api.nvim_get_current_win()
      or vim.fn.bufwinid(view.bufnr)
    local saved = win ~= -1 and vim.api.nvim_win_call(win, vim.fn.winsaveview)

    --- @return boolean whether the window to show the prompts in is still there
    local function has_win() return win ~= -1 and vim.api.nvim_win_is_valid(win) end

    --- @param prompt otto.PromptItem?
    local function preview(prompt)
      if not has_win() then return end
      vim.api.nvim_win_call(win, function()
        if prompt == nil then return vim.fn.winrestview(saved) end
        vim.api.nvim_win_set_cursor(win, { prompt.row + 1, 0 })
        vim.cmd('normal! zt')
      end)
    end

    --- @param prompt otto.PromptItem
    local function format(prompt)
      local lines = vim.split(prompt.text, '\n')
      local chunks = { { lines[1] } }
      if #lines > 1 then table.insert(chunks, { ('  +%d lines'):format(#lines - 1), 'Comment' }) end
      return chunks, { { tostring(prompt.index), 'Comment' } }
    end

    --- @param prompt otto.PromptItem
    local function accept(prompt)
      if rewind then
        return util.run_task(function() M.rewind(view, prompt) end)
      end
      if has_win() then vim.api.nvim_win_set_cursor(win, { prompt.row + 1, 0 }) end
    end

    pick.select({
      prompt = rewind and 'Rewind to: ' or 'Prompt: ',
      items = prompts,
      format = format,
      text = function(prompt) return prompt.text end,
      preview = preview,
      on_accept = accept,
    })
  end)
end

return M
