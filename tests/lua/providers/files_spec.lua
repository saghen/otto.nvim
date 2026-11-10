-- Saved sessions, as each agent's files have them, in a fake home and folder

local t = ...

local home = vim.fn.tempname()
local cwd = home .. '/project'
vim.fn.mkdir(cwd, 'p')
local old_home, old_cwd = vim.env.HOME, vim.fn.getcwd()
vim.env.HOME = home
vim.fn.chdir(cwd)

--- @param path string
--- @param lines (table | string)[] Records, or raw lines like a bad one
local function write(path, lines)
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  local raw = vim.tbl_map(function(line) return type(line) == 'string' and line or vim.json.encode(line) end, lines)
  assert(vim.fn.writefile(raw, path) == 0)
end

--- @param files { list: fun(): string[], parse: fun(file: string, modified: integer): otto.ParsedSession? }
--- @return otto.ParsedSession[] parsed, by id
local function parse_all(files)
  local saved = {}
  for _, file in ipairs(files.list()) do
    local session = files.parse(file, 42)
    if session then saved[session.id] = session end
  end
  return saved
end

local ok, err = pcall(function()
  t.describe('jsonl', function()
    local jsonl = require('otto.jsonl')
    local path = home .. '/lines.jsonl'
    write(path, { 'a', 'bad', 'b' })
    local read = {}
    jsonl.each_line(assert(io.open(path)), function(line)
      if line == 'bad' then error('bad line') end
      table.insert(read, line)
    end)
    t.check('skips lines that fail', read, { 'a', 'b' })

    local errors, until_stop = {}, {}
    jsonl.each_line(assert(io.open(path)), function(line)
      if line == 'bad' then error('bad line', 0) end
      table.insert(until_stop, line)
      return line ~= 'b'
    end, function(e) table.insert(errors, e) end)
    t.check('reports lines that fail', errors, { 'bad line' })
    t.check('stops when told', until_stop, { 'a', 'b' })
    t.check('decodes null as nil', jsonl.decode('{"name":null,"list":[null]}'), { list = {} })

    local log = home .. '/appended.jsonl'
    --- @param text string
    --- @param mode string
    local function put(text, mode)
      local file = assert(io.open(log, mode))
      file:write(text)
      file:close()
    end
    put('a\nb\npar', 'w')
    local lines, offset, restarted = jsonl.read_appended(log, 0)
    t.check('whole lines appended', { lines, offset, restarted }, { { 'a', 'b' }, 4, false })
    put('tial\n', 'a')
    t.check('then the rest', { jsonl.read_appended(log, offset) }, { { 'partial' }, 12, false })
    put('new\n', 'w')
    t.check('from the start once it shrank', { jsonl.read_appended(log, 12) }, { { 'new' }, 4, true })
    t.check('nothing of a file that is gone', { jsonl.read_appended(home .. '/none', 3) }, { {}, 3, false })
  end)

  t.describe('claude', function()
    local files = require('otto.providers.claude.files')
    write(files.session_file('s1'), {
      { type = 'user', message = { content = '<local-command-caveat>x</local-command-caveat>' } },
      { type = 'user', message = { content = 'first prompt' } },
      '{"type":"assistant", bad',
      { type = 'assistant', message = { content = {} } },
      { type = 'user', message = { content = { { type = 'tool_result' } } } },
      { type = 'ai-title', aiTitle = 'ai' },
      { type = 'custom-title', customTitle = 'custom' },
    })
    write(files.session_file('s2'), { { type = 'ai-title', aiTitle = 'ai only' } })
    write(files.session_file('s3'), {
      { type = 'user', message = { content = 'untitled' } },
      '{"type":"custom-title","customTitle":null}',
    })
    local saved = parse_all(files)
    t.check('session', saved.s1, {
      provider = 'claude',
      id = 's1',
      name = 'custom',
      prompt = 'first prompt',
      -- with the cut off line, which counts before it's decoded
      message_count = 5,
      modified = 42,
    })
    t.check('ai title without a custom one', saved.s2.name, 'ai only')
    t.check('a null title is none', saved.s3.name, nil)
  end)

  t.describe('pi', function()
    local files = require('otto.providers.pi.files')
    t.check('no file of an unknown session', files.session_file('x'), nil)
    local pi_folder = ('%s/.pi/agent/sessions/--%s--'):format(home, (cwd:sub(2):gsub('[/\\:]', '-')))
    write(pi_folder .. '/2026_auth_fix.jsonl', {
      { type = 'session_info', name = 'named' },
      { type = 'message', message = { role = 'user', content = { { type = 'image' } } } },
      { type = 'message', message = { role = 'user', content = 'prompt' } },
      'not json "type":"message"',
      { type = 'message', message = { role = 'assistant', content = {} } },
    })
    write(pi_folder .. '/2026_fix.jsonl', { '{"type":"session_info","name":null}' })
    t.check('file of the id, not of a suffix', files.session_file('fix'), pi_folder .. '/2026_fix.jsonl')
    local saved = parse_all(files)
    t.check('session', saved.auth_fix, {
      provider = 'pi',
      id = 'auth_fix',
      name = 'named',
      prompt = 'prompt',
      message_count = 4,
      modified = 42,
    })
    t.check('a null name is none', saved.fix.name, nil)
  end)

  t.describe('codex', function()
    local files = require('otto.providers.codex.files')
    local sessions = home .. '/.codex/sessions/2026/01/01'
    write(sessions .. '/rollout-a.jsonl', {
      { payload = { id = 'a', cwd = cwd, source = 'cli' } },
      {
        type = 'event_msg',
        payload = { type = 'item_completed', item = { type = 'UserMessage', content = { { text = 'hi' } } } },
      },
      'not json',
      { type = 'event_msg', payload = { type = 'item_completed', item = { type = 'AgentMessage' } } },
    })
    write(sessions .. '/rollout-old.jsonl', {
      { payload = { id = 'old', cwd = cwd, source = 'cli' } },
      { payload = { type = 'user_message', message = 'old prompt' } },
      { payload = { type = 'agent_message', message = 'answer' } },
    })
    write(sessions .. '/rollout-other.jsonl', { { payload = { id = 'other', cwd = '/elsewhere', source = 'cli' } } })
    -- subagents, like the reviewer, have a source that isn't a string
    write(sessions .. '/rollout-sub.jsonl', { { payload = { id = 'sub', cwd = cwd, source = { subagent = 'x' } } } })
    write(home .. '/.codex/session_index.jsonl', {
      { id = 'a', thread_name = 'named' },
      'bad',
      { thread_name = 'no id' },
      '{"id":"old","thread_name":null}',
    })
    local saved = parse_all(files)
    local ids = vim.tbl_keys(saved)
    table.sort(ids)
    t.check('of this folder, not subagents', ids, { 'a', 'old' })
    t.check('counts items', saved.a.message_count, 2)
    t.check('first prompt', saved.a.prompt, 'hi')
    t.check('of older versions', saved.old, {
      provider = 'codex',
      id = 'old',
      prompt = 'old prompt',
      message_count = 2,
      modified = 42,
    })
    t.check('names', files.names(), { a = 'named' })
  end)

  t.describe('saved', function()
    local saved = require('otto.providers').saved()
    local titles = {}
    for _, session in ipairs(saved) do
      titles[session.id] = session.title
    end
    t.check('titles', { titles.s1, titles.s3, titles.fix, titles.old }, { 'custom', 'untitled', 'fix', 'old prompt' })
  end)
end)

vim.env.HOME = old_home
vim.fn.chdir(old_cwd)
vim.fn.delete(home, 'rf')
if not ok then error(err, 0) end
