<h2 align="center">Otto (otto.nvim)</h2>

<p align="center">
  <strong>Experimental</strong> neovim-native agent interface
</p>

**otto.nvim** is an agent interface for neovim, rendering natively in a prompt buffer (`:h prompt-buffer`), not a TUI! Currently, only Pi (specialized to my configuration), Codex and Claude Code are supported via RPC.

```lua
vim.pack.add({
  "https://github.com/saghen/otto.nvim",
  { source = "https://github.com/saghen/blink.lib", branch = "vim-async" },
})

vim.keymap.set('n', '<leader>af', '<cmd>Otto<cr>', { desc = 'Find session' })
vim.keymap.set('n', '<leader>ar', '<cmd>Otto resume<cr>', { desc = 'Resume session' })
vim.keymap.set({ 'n', 'x' }, '<leader>as', ':Otto send<cr>', { desc = 'Send to agent' })

vim.keymap.set('n', '<leader>ap', '<cmd>Otto pi<cr>', { desc = 'New Pi session' })
vim.keymap.set('n', '<leader>aP', ':Otto pi ', { desc = 'New named Pi session' })
vim.keymap.set('n', '<leader>ac', '<cmd>Otto claude<cr>', { desc = 'New Claude session' })
vim.keymap.set('n', '<leader>aC', ':Otto claude ', { desc = 'New named Claude session' })
vim.keymap.set('n', '<leader>ax', '<cmd>Otto codex<cr>', { desc = 'New Codex session' })
vim.keymap.set('n', '<leader>aX', ':Otto codex ', { desc = 'New named Codex session' })
```

Pickers use [minibuffer.nvim](https://github.com/saghen/minibuffer.nvim) when it's set up, and `vim.ui.select` otherwise. For below, I'm assuming your `<localleader>` is `\` (default). See `:h maplocalleader`.

| Key | Action |
| --- | --- |
| `<C-s>`, `<CR>` (normal) | Submit |
| `<M-CR>` | Submit as follow-up |
| `<C-c>` | Stop |
| `<M-p>` | Older prompt history or edit queued history |
| `<M-n>` | Newer prompt history |
| `<M-r>` | Prompt history picker |
| `<M-x>` | Commands |
| `\p` | Jump to a prompt |
| `\q` | Edits of the session to quickfix |

## Configuration

Otto works without `setup()`. These are the defaults, which `setup()` merges into. See `lua/otto/config.lua` for every keymap.

```lua
require('otto').setup({
  default_provider = 'pi',
  -- command, command by mode, or false to disable. `keymaps = false` disables them all
  keymaps = {
    ['<CR>'] = { n = 'open', i = 'newline' },
    ['<C-s>'] = 'submit',
    -- ...
  },
  providers = {
    -- `cmd` comes before otto's arguments and `args` after, so `cmd` can be a wrapper like { 'bwrap', ..., 'pi' }
    pi = { cmd = { 'pi' }, args = {}, env = {} },
    claude = {
      cmd = { 'claude' },
      args = {},
      env = {},
      model = 'claude-opus-5-5',
      effort = 'high',
      permission_mode = 'auto',
    },
    codex = { cmd = { 'codex' }, args = {}, env = {} },
  },
})
```

Every command has a `<Plug>(otto-<command>)` mapping, which you can map yourself in `after/ftplugin/otto.lua`. Otto doesn't map over the buffer's own mappings:

```lua
vim.keymap.set('i', '<C-j>', '<Plug>(otto-submit)', { buffer = true })
-- or configure only this session, before its agent starts
require('otto.config').set({ providers = { claude = { model = 'claude-sonnet-5-5' } } }, { bufnr = 0 })
```

## Agent events

Otto runs `User` autocmds for what an agent logs, its state and its requests, the same way for every agent:

```lua
vim.api.nvim_create_autocmd('User', {
  pattern = 'OttoAgentSettled',
  callback = function(args)
    local turn = args.data.event
    if turn and turn.worked and not turn.aborted then vim.notify(args.data.provider .. ' finished') end
    -- the session may have no buffer, or a hidden one: use vim.fn.bufnr(args.data.uri), not args.buf
  end,
})
```

| User event | When it runs | Data |
| --- | --- | --- |
| `OttoPrompt` | The agent read a prompt | `event` with `text` |
| `OttoText` | The agent answered | `event` with `text` |
| `OttoToolCall` | A tool started, or one in the background finished, with `<id>:end` | `event` with `id`, `tool` and `args` |
| `OttoToolResult` | A tool finished | `event` with the `id` of its call, `ok`, `output`, and `exit_code` of commands or `diff` of edits |
| `OttoError` | The agent failed | `event` with `message` |
| `OttoCompaction` | The context was compacted | `event` with `summary`, `before` and `after` when the agent reports them |
| `OttoTurnEnd` | A turn ended, when the agent settles or a prompt follows its answer | `event` with `aborted`, `started` and `worked` |
| `OttoState` | The state changed, like the status, queue, name, model or cost | `patch`, see `otto.StatePatch` |
| `OttoAgentStart` | The agent started working, or compacting | |
| `OttoAgentSettled` | The agent stopped working, or its session closed while it worked | `event` of the last `OttoTurnEnd`, if any |
| `OttoRequest` | The agent waits for the user to answer, like a permission | `request` with `kind`, `prompt`, `items` and `default` |
| `OttoSessionStart` | A new or resumed session replayed its history, also after a restart, before its other events | |
| `OttoSessionClose` | The session closed, though not when Neovim exits | |

Every callback receives `args.data = { uri, provider, id, ... }`, where `uri` is the session's buffer name, like
`claude://<id>`, and `event` is a copy of the log event, see `otto.Event` in `lua/otto/event.lua`. The saved history
doesn't run any of them, and closed sessions run nothing. `OttoAgentStart` and `OttoAgentSettled` always come in pairs.

Callbacks run soon after the event, in order, rather than while the agent handles it, so they may prompt the agent or
close the session. Set `nested = true` on autocmds that edit or delete buffers, so that their own autocmds run.

Unlike my other projects, this project has been AI assisted, use at your own risk!
