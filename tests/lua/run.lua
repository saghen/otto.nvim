-- Runs the specs in tests/lua/**/*_spec.lua, or those whose names contain the filter:
--   nvim --headless --clean -l tests/lua/run.lua [filter]

local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.abspath(debug.getinfo(1, 'S').source:sub(2)))))
if vim.env.BLINK_LIB and vim.env.BLINK_LIB ~= '' then vim.opt.runtimepath:prepend(vim.env.BLINK_LIB) end
vim.opt.runtimepath:prepend(root)
-- the history and drafts of prompts, apart from the user's
vim.env.XDG_STATE_HOME = vim.fn.tempname()

local filter = _G.arg[1]
local helpers = dofile(root .. '/tests/lua/helpers.lua')

local specs = vim.fn.glob(root .. '/tests/lua/**/*_spec.lua', false, true)
table.sort(specs)
local ran = 0
for _, path in ipairs(specs) do
  local name = vim.fs.basename(path):gsub('%.lua$', '')
  if filter == nil or name:find(filter, 1, true) then
    ran = ran + 1
    helpers.spec = name
    local ok, err = xpcall(function() assert(loadfile(path))(helpers) end, debug.traceback)
    if not ok then helpers.fail('error', err) end
  end
end

for _, skipped in ipairs(helpers.skipped) do
  io.stdout:write('SKIP ' .. skipped .. '\n')
end
for _, failure in ipairs(helpers.failures) do
  io.stdout:write('FAIL ' .. failure .. '\n')
end
local summary = '%d specs, %d checks, %d failed, %d skipped\n'
io.stdout:write(summary:format(ran, helpers.checks, #helpers.failures, #helpers.skipped))
os.exit(#helpers.failures == 0 and ran > 0 and 0 or 1)
