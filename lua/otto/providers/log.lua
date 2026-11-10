-- The log of a session, which providers build from what happened, the same way from their session files and their
-- processes. A turn starts with what the agent does after the last one ended, and ends when the agent settles while it
-- runs, when a prompt follows its answer, or at the end of the session file. So every turn ends. What the transcript
-- doesn't show, like the session's name, goes to the state instead

local event = require('otto.event')

--- @class otto.Log
--- @field emit fun(event: otto.Event)
--- @field on_state fun(patch: otto.StatePatch)
--- @field in_turn boolean
--- @field started? integer When the turn started
--- @field worked boolean Whether the agent did anything in the turn
--- @field last_at? integer Of the last event of the turn, which ends it
--- @field answered boolean Whether the agent answered, or failed, since its last tool, so that a prompt ends the turn
--- @field aborted boolean Whether the turn ends aborted
local Log = {}
Log.__index = Log

local M = {}

--- @param emit fun(event: otto.Event)
--- @param on_state fun(patch: otto.StatePatch)
--- @return otto.Log
function M.new(emit, on_state)
  return setmetatable(
    { emit = emit, on_state = on_state, in_turn = false, worked = false, answered = false, aborted = false },
    Log
  )
end

--- @class otto.ToolResult : otto.ToolResultEvent Of `Log:tool_result`, which adds its type and time
--- @field type? 'tool_result'
--- @field at? integer

--- Adds an event of the turn, starting the turn when none is running
--- @param fields table Of an `otto.Event`, which this adds its time to
--- @param at? integer Now by default
function Log:push(fields, at)
  fields.at = at or event.now()
  if not self.in_turn then
    self.in_turn = true
    self.started = fields.at
    self.worked = false
    self.answered = false
    self.aborted = false
  end
  if fields.type ~= 'user' then self.worked = true end
  self.last_at = fields.at
  self.emit(fields)
end

--- Ends the turn, when one is running
--- @param aborted? boolean
--- @param at? integer Of the last event by default
function Log:end_turn(aborted, at)
  if not self.in_turn then return end
  self.in_turn = false
  self.emit({
    type = 'turn_end',
    aborted = aborted or self.aborted,
    started = self.started,
    worked = self.worked,
    at = at or self.last_at,
  })
end

--- Ends the turn aborted, and what the agent was doing and its queue, once its process is gone
function Log:reset()
  self:end_turn(true)
  self.on_state({ status = false, queue = {} })
end

--- The turn ends aborted, like when the user interrupts the agent
function Log:mark_aborted() self.aborted = true end

--- Something that the agent reads like a prompt, which ends the turn when the agent answered
function Log:interject()
  if self.answered or self.aborted then self:end_turn() end
end

--- @param text string
--- @param at? integer
function Log:user(text, at)
  self:interject()
  self:push({ type = 'user', text = text }, at)
  self.answered = false
end

--- @param text string
--- @param at? integer
--- @param commentary? boolean Whether it's about what the agent does next, rather than an answer
function Log:text(text, at, commentary)
  self:push({ type = 'text', text = text }, at)
  self.answered = not commentary
end

--- @param id string
--- @param tool string
--- @param args otto.ToolArgs | table Of otto's tools, or the agent's own
--- @param at? integer
function Log:tool_call(id, tool, args, at)
  self:push({ type = 'tool_call', id = id, tool = tool, args = args }, at)
  self.answered = false
end

--- @param result otto.ToolResult
--- @param at? integer
function Log:tool_result(result, at)
  result.type = 'tool_result'
  self:push(result, at)
  self.answered = false
end

--- @param message string
--- @param at? integer
function Log:error(message, at)
  self:push({ type = 'error', message = message }, at)
  self.answered = true
end

--- Compactions happen inside turns, or on their own
--- @param compaction { summary?: string, before?: integer, after?: integer }
--- @param at? integer
function Log:compaction(compaction, at)
  compaction.type = 'compaction'
  compaction.at = at or event.now()
  self.emit(compaction)
end

--- What the session runs with, which the history has too. For decoders, which only hold the log, while agents patch the
--- state themselves
--- @param patch otto.StatePatch
function Log:patch_state(patch) self.on_state(patch) end

return M
