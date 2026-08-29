#!/usr/bin/env bash
# Install the status line into a Claude Code config directory.
#
#   ./install.sh              # installs to ~/.claude
#   CLAUDE_DIR=/path ./install.sh
#
# Copies statusline.sh into place and merges a `statusLine` block into
# settings.json, backing up the original first. Idempotent.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dir="${CLAUDE_DIR:-$HOME/.claude}"
settings="$dir/settings.json"

command -v jq >/dev/null 2>&1 || { echo "install: jq is required to merge settings.json" >&2; exit 1; }

mkdir -p "$dir"
install -m 0755 "$here/statusline.sh" "$dir/statusline.sh"
echo "installed $dir/statusline.sh"

[[ -f $settings ]] || echo '{}' > "$settings"
jq -e . "$settings" >/dev/null 2>&1 || { echo "install: $settings is not valid JSON; fix it first" >&2; exit 1; }

backup="$settings.bak-$(date +%Y%m%d%H%M%S)"
cp "$settings" "$backup"

tmp="$settings.tmp.$$"
jq '. + {statusLine: {type: "command", command: "~/.claude/statusline.sh", padding: 0}}' "$settings" > "$tmp"
jq -e . "$tmp" >/dev/null
mv "$tmp" "$settings"

echo "updated $settings (backup: $backup)"
echo "Status line appears on the next assistant message; restart Claude Code if it does not."
