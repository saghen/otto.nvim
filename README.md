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
vim.keymap.set('n', '<leader>ap', '<cmd>Otto pi<cr>', { desc = 'New Pi session' })
vim.keymap.set('n', '<leader>aP', ':Otto pi ', { desc = 'New named Pi session' })
vim.keymap.set('n', '<leader>ac', '<cmd>Otto claude<cr>', { desc = 'New Claude session' })
vim.keymap.set('n', '<leader>aC', ':Otto claude ', { desc = 'New named Claude session' })
vim.keymap.set('n', '<leader>ax', '<cmd>Otto codex<cr>', { desc = 'New Codex session' })
vim.keymap.set('n', '<leader>aX', ':Otto codex ', { desc = 'New named Codex session' })
vim.keymap.set('n', '<leader>ar', '<cmd>Otto resume<cr>', { desc = 'Resume session' })
vim.keymap.set({ 'n', 'x' }, '<leader>as', ':Otto send<cr>', { desc = 'Send to agent' })
```

Pickers use [minibuffer.nvim](https://github.com/saghen/minibuffer.nvim) when it's set up, and `vim.ui.select` otherwise.

| Key | Action |
| --- | --- |
| `<C-s>`, `<CR>` (normal) | Submit, steering while the agent works |
| `<M-CR>` | Submit as a follow-up |
| `<C-c>` | Take back queued prompts, or abort |
| `<M-p>`, `<M-n>` | Older and newer prompts of this folder, keeping your draft |
| `<M-r>` | Pick from the history (`<M-s>` all folders, `<M-d>` delete) |
| `<M-x>` | Commands |
| `\p` | Jump to a prompt (`<M-r>` rewind, `<M-f>` fork, `<M-e>` edit) |
| `\r`, `\f` | Rewind to, or fork from, the prompt under the cursor |
| `\e` | Edit the prompt under the cursor |
| `\y`, `\o` | Yank, or open in a split, the prompt, tool output or code block under the cursor |
| `\t` | Run the command under the cursor in a terminal |
| `\k` | Stop the subagent or command under the cursor |
| `\q` | Edits of the session to quickfix |

## Configuration

This fork uses upstream's provider settings. Replace the old top-level `pi.command`,
`pi.args`, `pi.agent_dir`, and `pi.session_dir` with `providers.pi.cmd`,
`providers.pi.args`, and `providers.pi.env`, as shown below. Setup now merges settings.

```lua
require('otto').setup({
  picker = 'vim_ui', -- 'auto' uses minibuffer when set up; 'minibuffer' requires it
  providers = {
    pi = {
      cmd = { '/opt/Pi Tools/bin/pi', '--model', 'provider/model' },
      args = {},
      env = {
        PI_CODING_AGENT_DIR = '/path/to/agent',
        PI_CODING_AGENT_SESSION_DIR = '/path/to/sessions',
      },
    },
  },
})
```

Pi session storage uses `PI_CODING_AGENT_SESSION_DIR`, then
`<PI_CODING_AGENT_DIR>/sessions`, then `~/.pi/agent/sessions`. Configured environment
values take precedence over inherited values. Empty values count as unset. Paths
expand home and environment variables, but not glob characters. Otto keeps Pi's
encoded project subdirectories and passes a session-root override through
`--session-dir`. Main sessions and one-shot helper calls use the same settings.
Commands run directly without a shell; each `cmd` and `args` entry stays one argument.

Otto works without `setup()`. These are the defaults, which `setup()` merges into. See `lua/otto/config.lua` for every keymap.

```lua
require('otto').setup({
  default_provider = 'pi',
  ask = { provider = 'pi' }, -- one-shot prompts, like naming sessions
  cleanup_delay = 10000, -- ms before an empty, hidden session's buffer is deleted
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

Unlike my other projects, this project has been AI assisted, use at your own risk!
