# claude-statusline

A three-line status line for the [Claude Code](https://code.claude.com) CLI.

```
~/Work/Genesis1 on master*
owen@example.com · claude-opus-5[1m] · 1.0M ctx
ctx ██░░░░░░░░ 19% 193.4k  │  5h ████░░░░░░ 42% ↻2h0m  │  7d █████████░ 88% ↻3d3h
```

1. Working directory (abbreviated, `~`-relative) and git branch, with `*` when the tree is dirty.
2. Account email · model id · context window size.
3. Context usage, 5-hour limit, and 7-day limit — each a colour-graded bar (green → yellow → red)
   with a countdown to the window's reset.

## Install

```sh
git clone <this repo> && cd claude-statusline
./install.sh
```

That copies `statusline.sh` to `~/.claude/` and merges a `statusLine` block into
`~/.claude/settings.json`, backing the original up first. Set `CLAUDE_DIR` to install
elsewhere. `./uninstall.sh` reverses both.

To wire it up by hand instead, add to `~/.claude/settings.json`:

```json
"statusLine": {
  "type": "command",
  "command": "~/.claude/statusline.sh",
  "padding": 0
}
```

The script is re-read from disk on every render, so edits take effect on the next assistant
message. Only settings changes need a restart.

## Requirements

`bash` 4+, and **either `jq` or `python3`** for JSON parsing (most systems have both). `git` is
optional — the branch segment is simply omitted without it. Colours need a truecolor terminal.

## Configuration

| Variable | Effect |
| --- | --- |
| `CLAUDE_STATUSLINE_BAR=0` | Hide the bars; show percentages only |
| `CLAUDE_STATUSLINE_BAR_WIDTH=N` | Bar width in characters (default `10`) |
| `CLAUDE_ACCOUNT_EMAIL=…` | Use this email and skip the `claude auth status` lookup |

## Notes on the data

Claude Code sends session JSON on stdin. Two fields are conditional, and the script degrades
segment by segment rather than rendering zeros:

- **`rate_limits`** exists only for Claude.ai Pro and Max accounts, and only after the first API
  response in a session. Each window (`five_hour`, `seven_day`) can be absent independently, and
  Claude Code drops a window once its `resets_at` passes.
- **`context_window`** is `null` before the first API call and again after `/compact`, until the
  next response repopulates it.

Two implementation choices worth knowing if you fork this:

- **One parsing pass, not one per field.** The status line runs on every assistant message, so
  all twelve fields are extracted in a single `jq` (or `python3`) call. A render costs ~100ms.
- **The fallback is path-aware.** Leaf names in this schema are not unique — `used_percentage`
  and `resets_at` each appear three times, under `five_hour`, `seven_day`, and `spend_limit`. A
  grep-style extractor matching on leaf name alone will report the wrong window's numbers. The
  test suite asserts the `jq` and `python3` paths produce byte-identical output.
- **The email lookup never blocks.** It is cached for 24h and refreshed detached in the
  background, so a slow `claude auth status` can't stall a render.

## Tests

```sh
./test/run-tests.sh
```

Runs seven payload shapes (full, missing rate limits, null context, deep path, empty object,
malformed input, empty input), asserting the script always exits 0 and that both parser paths
agree.

## Credits

Inspired by [Andrew Connell's status line article](https://www.andrewconnell.com/articles/claude-code-cli-statusline/).
Written against the [official status line schema](https://code.claude.com/docs/en/statusline).

MIT licensed.
