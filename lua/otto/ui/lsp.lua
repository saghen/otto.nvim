-- Completes the agent's /commands at the start of the input and @paths at the start of words, through an in-process
-- language server that blink.cmp, or any other LSP client, asks

local M = {}

local server --- @type fun(dispatchers: vim.lsp.rpc.Dispatchers, config: vim.lsp.ClientConfig): vim.lsp.rpc.Client

--- @param view otto.View
--- @param range lsp.Range Of the token after its trigger character
--- @return lsp.CompletionItem[]
local function commands(view, range)
  local items = {}
  for _, command in ipairs(require('otto.ui.commands').agent_commands(view)) do
    table.insert(items, {
      label = command.name,
      kind = vim.lsp.protocol.CompletionItemKind.Function,
      detail = command.arg_hint,
      documentation = command.description,
      textEdit = { range = range, newText = command.name },
    })
  end
  return items
end

--- The entries of the path's folder, one folder at a time like cmdline completion
--- @param path string Typed after the @
--- @param range lsp.Range Of the path
--- @return lsp.CompletionItem[]
local function paths(path, range)
  local dir = path:match('^(.*/)') or ''
  -- hidden ones once the name starts with a dot, like getcompletion
  local pattern = dir .. (vim.startswith(path:sub(#dir + 1), '.') and '.' or '')
  local kinds = vim.lsp.protocol.CompletionItemKind
  local items = {}
  for _, match in ipairs(vim.fn.getcompletion(pattern, 'file')) do
    local name = match:match('([^/]*/?)$')
    -- which typing them gets to anyway
    if name ~= './' and name ~= '../' then
      table.insert(items, {
        label = name,
        kind = vim.endswith(name, '/') and kinds.Folder or kinds.File,
        textEdit = { range = range, newText = match },
      })
    end
  end
  return items
end

--- @param params lsp.CompletionParams
--- @return lsp.CompletionList?
local function complete(params)
  local util = require('blink.lib.lsp').util
  local view = require('otto.buffers').get(util.bufnr(params.textDocument))
  if view == nil then return end

  local row, col = util.position(params.position)
  local before = vim.api.nvim_buf_get_lines(view.bufnr, row, row + 1, false)[1]:sub(1, col)
  local token = before:match('%S*$')

  -- the token after its trigger character, which may contain `:` or `/`
  local range = util.range(view.bufnr, row, col - #token + 1, row, col)

  -- the agent's own commands, since otto's are in the palette. Like submitting, which trims the input
  if vim.startswith(token, '/') and vim.trim(before) == token and row == require('otto.input').row(view.bufnr) then
    return { isIncomplete = false, items = commands(view, range) }
  end
  -- asked again on every key, since the folder and hidden files change with the token, like after deleting a /
  if vim.startswith(token, '@') then return { isIncomplete = true, items = paths(token:sub(2), range) } end
  return { isIncomplete = false, items = {} }
end

vim.lsp.config('otto', {
  -- created lazily, since blink.lib may be added to the runtimepath after otto loads
  cmd = function(dispatchers, config)
    server = server
      or require('blink.lib.lsp').server({
        name = 'otto',
        capabilities = { completionProvider = { triggerCharacters = { '/', '@' } } },
        handlers = { ['textDocument/completion'] = complete },
      })
    return server(dispatchers, config)
  end,
})

--- Attaches to the session's buffer
--- @param view otto.View
function M.attach(view)
  -- blink.cmp skips prompt buffers otherwise
  vim.b[view.bufnr].completion = true
  vim.lsp.start(vim.lsp.config.otto, { bufnr = view.bufnr })
end

return M
