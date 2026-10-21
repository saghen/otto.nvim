-- Session picker, with highlighted columns when using minibuffer

--- @class otto.PickOpts
--- @field prompt string
--- @field text fun(item: any): string Matched against the input
--- @field format fun(item: any): minibuffer.util.HighlightLine

--- Fits text into a column, truncating it or padding it on the right
--- @param text string
--- @param width integer
--- @return string
local function column(text, width)
  if vim.api.nvim_strwidth(text) > width then text = vim.fn.strcharpart(text, 0, width - 3) .. '...' end
  return text .. (' '):rep(width - vim.api.nvim_strwidth(text))
end

--- @param items any[]
--- @param opts otto.PickOpts
--- @param on_choice fun(item?: any)
local function pick(items, opts, on_choice)
  if require('otto.config').options.picker == 'vim_ui' then
    return vim.ui.select(items, { prompt = opts.prompt, format_item = opts.text }, on_choice)
  end
  require('minibuffer').select({
    prompt = opts.prompt,
    max_height = 10,
    fetch_fn = function(_, callback) callback(items) end,
    filter_fn = function(ctx)
      if ctx.input == '' then return ctx.items end
      return vim.fn.matchfuzzy(ctx.items, ctx.input, { text_cb = opts.text })
    end,
    format_fn = opts.format,
    -- the last column is cut off
    footer_fn = function(ctx) return { { ('%d/%d '):format(ctx.current_index, #ctx.items), 'Comment' } } end,
    on_accept = function(selection) on_choice(selection[1].item) end,
    on_cancel = function() on_choice(nil) end,
  })
end

return { pick = pick, column = column }
