# Architecture

Providers turn their agent into a log of events, the same whether it's read from a session file or streamed live. The
core keeps the session's state from that log, and the renderer draws the transcript from it, without knowing which
provider made it

```
provider ──log, state, requests──▶ session ──▶ view: transcript, footer, winbar, quickfix
    ▲                                    │
    └────────────── commands ────────────┘ from input: prompt buffer, keymaps, palette
```

## Three channels

Live has things that replay can't: what the agent is doing right now. Keeping them out of the log is what lets the log
be identical either way

- **Log**: what the transcript shows, identical live and replayed. Events don't change once they're emitted, since
  the session keeps them
- **State**: everything else, as patches of `otto.StatePatch` that the session merges. What the session runs with (its
  name, model, effort, context and cost), which comes from its history and its process, and live only, what the agent
  is doing and prompts it hasn't read yet. Nothing in the transcript depends on it
- **Requests**: what the agent waits for the user to answer, like permissions

Notifications skip all three, since they're only messages

## The log

See `event.lua` for the fields

```lua
{ type = 'user', text }
{ type = 'text', text }
{ type = 'tool_call', id, tool, args }
{ type = 'tool_result', id, ok, output?, exit_code?, diff? }
{ type = 'compaction', summary?, before?, after? }
{ type = 'error', message }
{ type = 'turn_end', aborted, started, worked }
```

- **Tools are normalized**: `read`, `edit`, `write`, `bash`, `grep`, `find`, `ls`, `web_search`, `fetch` and `agent`,
  with the args of `otto.ToolArgs`, and others keep the agent's name and args. Exit codes, diffs (as `otto.DiffLine`s, not text
  with line numbers in it), file contents of reads and search results are the provider's job
- **Prompts render once they're in the log**. Until then they show as queued in the footer
- **Every event has `at`**, from the provider's records, so that "Worked for" renders when replayed too. Codex's items
  have no times, so they take those of their turns, and pi's messages only say when they started, so they take when
  their entries were saved, or when they arrived. Events about the session don't move the end of a turn. Live and
  replayed times can differ by milliseconds, since the stream and the files can record them apart
- **Compaction summaries are optional**, since Codex keeps them to itself

## Subagents

A subagent is an `agent` tool, whose result is its answer when the turn waits for it. One in the background ends as a
second result of its tool, with its report, like a command in the background does with its output. So the transcript
only appends, and otto doesn't open subagents' sessions. What they change in the workspace is the agent's, see
Tracking

- **Claude Code** adds the ends to the conversation like prompts (`<task-notification>`), with reports as messages
  from peers before them. Its stream reports them as `task_notification`, which waits for the turn that reads it,
  where the file has it
- **Codex**'s history has when its subagents started and ended (`subAgentActivity`), but not their reports

## Turns

A turn starts with what the agent does after the last one ended, other than compacting, and ends when the agent settles
while it runs, when a prompt follows its answer, or at the end of the history. A prompt that follows a tool steers the
turn instead. So every turn ends, aborted when the agent was interrupted, and nothing past the provider handles an
unfinished one. Messages from other agents, and the ends of what runs in the background, end turns like prompts do.
`providers/log.lua` keeps these rules, and providers only say what happened. `turn_end` says when the
turn started and whether the agent did anything in it, so nothing past the provider keeps track of turns either

## Providers

No buffers and no `vim.ui`: a provider only translates. See `providers/init.lua` for `otto.Provider` and `otto.Agent`

- **One decoder for both**: each provider turns its records into the log in its `decode.lua`, which reads both its
  history and its process, beside `agent.lua` for its process and `files.lua` for its saved sessions. pi's session files and events hold the same
  messages, and Claude Code's session files and stream hold the same entries. This is what keeps the log identical
- **Replay is the agent's**, and reads the provider's files, without waiting for the process. Codex's session files
  hold items of another kind than its app-server, so its history comes from the app-server's `thread/turns/list`.
  Otto keeps no log of its own, which would make replay trivially identical, but would store sessions twice and could
  drift from the providers' files
- **Requests go through `on_request`**: permissions and pi's extension dialogs become
  `{ kind, ..., respond }`, which the session answers with `vim.ui`
- **Capabilities are optional methods**, like `fork` which only pi and Claude Code have, and `rewind` only shows when
  there is one
- **Saved sessions** come from each provider's `files` and `parse`, which `providers.saved` caches and titles
- **`providers/rpc.lua` runs the processes**, and matches their responses to requests, which each provider only
  frames. Their errors are named after the agent, like `codex: ...`. A process that exits with an error is notified
  once, rather than again by each request it never answered. One that can't start, like an agent that isn't
  installed, raises out of `open`, which the view notifies, leaving the buffer without a view
- **JSONL is read through `jsonl.lua`**, whose `decode` turns JSON's nulls into nil, for the processes, the session
  files and the logs that otto follows as they grow, its history and otto-track's
- **The providers are listed in `uri.lua`** too, so that `plugin/otto.lua` names their buffers without loading them

## Session and view

A session doesn't need a buffer, and a buffer only shows a session

- **`session.lua`** has the agent, the log so far (`events`, as the agent said it), and `otto.State` from the patches:
  what the session runs with, what the agent is doing, queued prompts and the agent's commands. What comes from the log
  is derived from it, like the tool calls that are running. It answers requests, and tells its listeners of each event
  and patch. It runs with the config of the buffer that opened it, or the global one, not the current buffer's
- **`view.lua`** shows a session in its buffer: it renders the log from the start when it attaches, then each event as
  it comes, and the footer and winbar from the state. Submitting and the state of the input (follow-ups, the
  history) are the view's, and so are the effects of the state on the editor: renaming the buffer when the agent
  creates the session's id, and reloading the files that changed on disk once it stops, like those the agent edited.
  The UI modules take views

## Tracking

With `track = true`, on Linux, agents run under `otto-track`, a Rust binary (`src/`) that puts a FUSE passthrough
over the workspace in a user and mount namespace of its own, so every change the agent makes there, through its tools or
its commands, passes through it. It records each in a store that every agent of the workspace shares: `log.jsonl`, a
line per change, and `blobs/<hash>`, the contents, along with changes from outside, so each change has the right before

- **`track.lua`** checks that the built binary speaks its protocol (`otto-track --protocol`, `PROTOCOL` in
  `src/main.rs`, bumped with the CLI or the log's format), wraps the agent's command, and follows the log, keeping each
  change of its agent (`changes`) with the running tool call of the session that made it (`TrackedAgent:call_of`), and
  what files held before and after
- **`ui/changes.lua`** shows them, as a unified diff or in the quickfix list with the agent's edits

## Renderer

Two halves, so that the rules of the transcript don't touch a buffer

- **`render/layout.lua`** is pure: events in, blocks out. A block has lines, highlights, sections that highlight as
  their language, targets, whether it folds, and the group it belongs to. Grouping tools under a summary, spacing by
  the last block, locations in tool output, and "Worked for" notes live here
- **`render/transcript.lua`** applies blocks by appending: extmarks, folds (with `render/folds.lua`), `undolevels`, the
  summaries of groups, and highlighting lazily, see `PLAN.md`. Transcripts keep all their lines: at 100,000 lines,
  typing, redrawing, scrolling, searching and folding take as long as at 10,000, and Neovim uses ~70MB
- **Memory goes to extmarks**, so targets cover ranges of lines, and work out the location of a line from its text
  when it's opened. Tools keep their calls and whole output, over their lines, for the actions on them
- **Folds are made whole and closed**: tools fold as they render, and groups once their turn ends, so groups stay
  open while the agent works, and folds never grow
- **`render/tools.lua`** has how tools look, their headers and sections, and the heuristics for output, like `cat`,
  `sed`, `rg` and JSON, which only look at the normalized tools. Layout only decides how their blocks group

## Layout

```
plugin/otto.lua     -- :Otto, the autocmds that load sessions, and highlights, which load the rest once used
ftplugin/otto.lua   -- a session's buffer: window options, its autocmds, and <Plug> maps
lua/otto/
  init.lua          -- the API, statuscolumn and winbar, without side effects
  config.lua        -- options, globally or of a session's buffer, through blink.lib
  event.lua         -- types of the log, the state and requests
  uri.lua           -- names of sessions and their buffers, like claude://<id>, and the providers' names
  util.lua
  jsonl.lua         -- decoding JSONL, reading files of it a line at a time, and what's appended to them
  providers/
    init.lua        -- types of providers and agents, registry and `saved`
    log.lua         -- the turns of the log
    rpc.lua         -- requests to agents' processes, over JSONL
    diff.lua        -- unified diff hunks, which agents report edits as
    pi/, claude/, codex/
      init.lua      -- the provider
      decode.lua    -- records as the log, the same from the files and the process
      agent.lua     -- the process, as an `otto.Agent`
      files.lua     -- saved sessions: listing and parsing them
  session.lua       -- an agent, its log and its state, without a buffer
  view.lua          -- shows a session in its buffer, and sends what's submitted
  buffers.lua       -- the views of open sessions, by buffer
  input.lua         -- the input below the transcript
  track.lua         -- runs agents under otto-track, follows its log, and attributes changes to tool calls
  render/
    layout.lua
    transcript.lua
    folds.lua
    tools.lua
    highlight.lua   -- treesitter highlights of the transcript and the input
  ui/
    footer.lua      -- running tools, what the agent is doing, and queued prompts
    scroll.lua      -- keeps windows on the same lines of the input
    winbar.lua
    commands.lua    -- otto's commands, which keymaps and the palette (<M-x>) run
    keymaps.lua     -- keys of the commands
    prompts.lua     -- the session's prompts: jumping and rewinding
    history.lua     -- of prompts, which <M-p> and <M-n> step through, its picker, and unsent prompts
    pick.lua        -- pickers in minibuffer.nvim, with notes, previews and actions, and of sessions
    changes.lua     -- what tracked agents changed, as a diff or in the quickfix list
tests/
  lua/
    run.lua         -- runs the specs: nvim --headless --clean -l tests/lua/run.lua [filter]
    helpers.lua
    providers/, render/, ui/, *_spec.lua
                    -- specs, like the modules they test
  common/           -- what otto-track's integration tests share
  process.rs, files.rs, host.rs, recording.rs, ignores.rs
                    -- otto-track over throwaway workspaces
  otto.rs           -- runs track.lua
  track.lua         -- otto's side of tracking, with a fake agent
src/                -- otto-track, see `Cargo.toml`
```

## Testing

`cargo test` runs otto-track's unit tests, and its integration tests in `tests/*.rs`, which run the wrapper over
throwaway workspaces with the tools agents use, and `tests/track.lua` (through `otto.rs`) in headless Neovim with a fake
agent, given blink.lib in `BLINK_LIB`. Without it, that test is skipped. `nvim --headless --clean -l tests/lua/run.lua
[filter]` runs the specs in `tests/lua/`, of the decoders, the saved sessions, the log, the layout, the tools, the
transcript, highlights, the buffer's input, folds, winbar, keymaps, footer, scrolling, history and prompts, the view over
a fake agent, and the helpers, with records shaped like each agent's. `replay_<agent>_spec.lua` checks that a session
replayed from its file gives the same events and blocks as live, for each agent, with the agent's own code over a fake
process, and `<agent>_agent_spec.lua` what replay doesn't reach, like permissions. `rpc_spec.lua` runs a real process.
Specs that need blink.lib are reported as skipped without it
