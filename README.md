<h2 align="center">Otto (otto.nvim)</h2>

<p align="center">
  <strong>Experimental</strong> neovim-native agent interface
</p>

**otto.nvim** is an agent interface for neovim, rendering natively in a prompt buffer (`:h prompt-buffer`), not a TUI! Currently, only Pi, Codex and Claude Code are supported via RPC.

```lua
vim.pack.add({
  "https://github.com/saghen/otto.nvim",
  "https://github.com/saghen/blink.lib",
  -- Optional when picker = 'vim_ui'
  "https://github.com/simifalaye/minibuffer.nvim"
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

## Configuration

Setup is optional. Without it, Otto uses minibuffer and runs `pi --mode rpc`.
Call setup before the first picker or agent launch. Each call replaces the configuration;
omitted options use their defaults. Claude and Codex do not use these Pi settings.

```lua
require('otto').setup({
  picker = 'vim_ui', -- default: 'minibuffer'
  pi = {
    command = '/path/to/pi', -- default: 'pi'
    args = {}, -- optional fixed arguments
    agent_dir = '/path/to/agent',
    -- Optional session-storage root:
    -- session_dir = '/path/to/sessions',
  },
})
```

### Picker

`picker = 'vim_ui'` uses your registered `vim.ui.select`.
It works without minibuffer. Both open-session and saved-session
pickers use this setting. The native UI backend uses plain-text labels; it does not
preserve minibuffer's highlighted columns. Minibuffer remains the default and loads
only when its picker is used.

### Pi directories

Otto resolves the session-storage root in this order:

1. `pi.session_dir`.
2. `PI_CODING_AGENT_SESSION_DIR` in Neovim's environment.
3. `<resolved agent directory>/sessions`.

The agent directory is `pi.agent_dir`, then `PI_CODING_AGENT_DIR` in Neovim's
environment, then `~/.pi/agent`. Empty environment values count as unset. Paths
expand `~` and environment variables. Spaces and glob characters are read literally.

Otto keeps Pi's encoded project subdirectories under the session-storage root.
For a session-root override, Otto passes the project directory through Pi's
`--session-dir` option. This also works with Pi versions that do not read the
session-directory environment variable. An explicit `pi.agent_dir` is passed to
the child as `PI_CODING_AGENT_DIR`. Other environment values remain inherited.

### Pi command

`pi.command` is a non-empty executable name or path. Put fixed arguments in
`pi.args`, which defaults to an empty list. Otto executes the command directly,
without a shell, and adds the fixed arguments, `--mode rpc`, and its session arguments.
It does not split the command string. Paths with spaces remain one argument.
Main sessions and helper calls use the same command, arguments, and directory settings.

```lua
-- Absolute executable path:
require('otto').setup({ pi = { command = '/opt/Pi Tools/bin/pi' } })

-- Pi with fixed arguments:
require('otto').setup({ pi = { command = 'pi', args = { '--model', 'provider/model' } } })
```

## Tests

The tests use headless Neovim and Lua assertions. No test dependencies are needed.
They use temporary session files and process stubs; they do not start agents or
make provider requests.

```sh
nvim --headless -u NONE -l tests/config.lua
stylua --check lua plugin tests
```

Unlike my other projects, this project has been AI assisted, use at your own risk!
