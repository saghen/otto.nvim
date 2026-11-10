-- Pure helpers: util, uri and event

local t = ...
local event = require('otto.event')
local uri = require('otto.uri')
local util = require('otto.util')

t.describe('format_duration', function()
  t.check('seconds', util.format_duration(0), '0s')
  t.check('under a minute', util.format_duration(59), '59s')
  t.check('a minute', util.format_duration(60), '1m 0s')
  t.check('minutes', util.format_duration(130), '2m 10s')
  t.check('under an hour', util.format_duration(3599), '59m 59s')
  t.check('an hour', util.format_duration(3600), '1h 0m')
  t.check('hours drop seconds', util.format_duration(2 * 3600 + 5 * 60 + 59), '2h 5m')
end)

t.describe('format_age', function()
  t.check('now', util.format_age(59), 'now')
  t.check('minutes', util.format_age(60), '1m')
  t.check('hours', util.format_age(2 * 3600 + 59), '2h')
  t.check('days', util.format_age(6 * 86400), '6d')
  t.check('weeks', util.format_age(7 * 86400), '1w')
  t.check('months', util.format_age(61 * 86400), '2mo')
end)

t.describe('trim_end', function()
  t.check('trailing whitespace', util.trim_end('  a\n b \n\n'), '  a\n b')
  t.check('keeps leading', util.trim_end('\n\tx'), '\n\tx')
  t.check('empty', util.trim_end(''), '')
  t.check('only whitespace', util.trim_end(' \n\t'), '')
end)

t.describe('uuid', function()
  local pattern = '^' .. ('%x'):rep(8) .. '%-' .. ('%x'):rep(4) .. '%-4' .. ('%x'):rep(3) .. '%-[89ab]'
  pattern = pattern .. ('%x'):rep(3) .. '%-' .. ('%x'):rep(12) .. '$'
  for i = 1, 20 do
    t.match('version 4 ' .. i, util.uuid(), pattern)
  end
  t.check('random', util.uuid() ~= util.uuid(), true)
end)

t.describe('uri', function()
  t.check('format', uri.format('claude', 'abc'), 'claude://abc')
  t.check('parse', { uri.parse('codex://019a-b') }, { 'codex', '019a-b' })
  t.check('parse other', { uri.parse('/tmp/file') }, {})
  t.check('id', uri.id('pi://x://y'), 'x://y')
  t.check('unique free', uri.unique('pi', 'free'), 'pi://free')
  local first = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(first, 'pi://taken')
  t.check('unique taken', uri.unique('pi', 'taken'), 'pi://taken_2')
  local second = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(second, 'pi://taken_2')
  t.check('unique taken twice', uri.unique('pi', 'taken'), 'pi://taken_3')
  vim.api.nvim_buf_delete(first, { force = true })
  vim.api.nvim_buf_delete(second, { force = true })
end)

t.describe('event', function()
  t.check('queue', event.queue({ 'a' }, { 'b', 'c' }), {
    { text = 'a', follow_up = false },
    { text = 'b', follow_up = true },
    { text = 'c', follow_up = true },
  })
  t.check('queue empty', event.queue(), {})
  t.check('parse_iso', event.parse_iso('2026-10-21T17:15:04.312Z'), 1792602904312)
  t.check('parse_iso epoch', event.parse_iso('1970-01-01T00:00:00Z'), 0)
  t.check('parse_iso short ms', event.parse_iso('1970-01-01T00:00:01.5Z'), 1500)
  t.check('parse_iso leap day', event.parse_iso('2024-02-29T00:00:00.000Z'), 1709164800000)
  t.check('parse_iso nil', event.parse_iso(nil), nil)
  t.check('parse_iso offset', event.parse_iso('2026-10-21T17:15:04+02:00'), nil)
  t.check('text_of string', event.text_of('hi'), 'hi')
  local parts = { { type = 'text', text = 'a' }, { type = 'image' }, { type = 'text', text = 'b' } }
  t.check('text_of parts', event.text_of(parts), 'a\nb')
  t.check('text_of nil', event.text_of(nil), '')
  local now = event.now()
  t.check('now in ms', math.abs(now - os.time() * 1000) < 2000, true)
end)
