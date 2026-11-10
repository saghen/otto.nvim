# Highlighting the transcript ourselves

Neovim's treesitter highlighter assumes the whole buffer can change at any time. Otto's transcript only changes by
appending, and a block never changes once it renders, so the work it does on every change is wasted:

- each keystroke in the prompt edits and reparses the markdown tree of the whole transcript (~5ms per key, and a
  13-19ms reparse in the background on 5000 lines), since tree-sitter-markdown puts everything between headings in one
  flat `section`
- markdown's combined injection of HTML made every reparse scan the whole buffer for injections (worked around with
  an injection query of our own)
- tool output needs fences to highlight as its language, which take 2 lines per tool and break when the output has
  fences of its own (worked around with four backticks)

## Design

- **Blocks highlight once**, when they're appended: their text is parsed on its own with
  `vim.treesitter.get_string_parser(text, lang)`, which handles injections (like code blocks in markdown), and the
  captures of each tree become extmarks with `@capture.lang` groups. The language comes from the block:
  - prompts, text and compaction summaries: markdown
  - commands: bash
  - output of reads and writes: the language of the file, of fetched pages: markdown, other output: none
  - diffs: none yet, besides the highlights of added and removed lines
- **The prompt highlights as markdown whenever it changes**. It's a few lines, so parsing it again takes microseconds
- **No treesitter for the buffer**, so no `vim.treesitter.start`, no reparse on changes and no injection query
- **No fences** for tool output, which is indented below the header instead

What's lost: plugins that ask for the buffer's tree (`vim.treesitter.get_node`, treesitter text objects,
`:InspectTree`), spell checking in the transcript, and the parts of Neovim's highlighter that Otto doesn't need
(conceal, URLs)

## Steps

These measure what was then. The transcript has since stopped removing old turns, so it keeps all its lines, see
ARCHITECTURE.md

1. **Highlight each block once, with extmarks** - done
   - `highlight.lua` highlights lines as a language, and the prompt
   - the transcript highlights its blocks, without fences, and the buffer has no treesitter
   - on a resumed session of 5000 lines: typing went from ~8ms to ~1ms per key, and the `/` menu from 13-24ms to
     2-5ms. Loading takes ~1.2s, of which highlighting is ~450ms, partly for turns that the line limit then removes
2. **Highlight lazily** - done: blocks highlight once they're first drawn, from a decoration provider's `on_line`, so
   folded output never parses until it opens, and turns that the line limit removes never parse. On a resumed session
   of 24.6k lines, rendering went from ~760ms to ~120ms, and its extmarks from ~42k to ~70 until it scrolls
3. **Extras**
   - diffs highlighted as the file's language, with the added and removed lines on top, like delta - done: the lines
     before and after the change parse apart, and line numbers are dimmed
   - output highlighted by what produced it - done: reads as the file's language (Claude Code's without its line
     numbers), `cat`/`head`/`tail`/`sed`/`nl`/`bat` of a file as its language, `git diff`/`git show`/`diff` as diff,
     JSON as json, and locations like `path:12:` from grep tools, `rg`, `grep` and `git grep`
   - locations from grep could go to the quickfix list like `gq` does for edits
   - prompt: `/commands` highlighted, unknown ones as errors, and `@paths` when they exist
   - raise or drop the line limits, which mostly protect treesitter - done: 25000 lines, trimming within a turn past
     40000
