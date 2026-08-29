#!/usr/bin/env bash
# Remove the statusLine block from settings.json and delete the script.
set -euo pipefail
dir="${CLAUDE_DIR:-$HOME/.claude}"
settings="$dir/settings.json"

if [[ -f $settings ]] && command -v jq >/dev/null 2>&1; then
  cp "$settings" "$settings.bak-$(date +%Y%m%d%H%M%S)"
  tmp="$settings.tmp.$$"
  jq 'del(.statusLine)' "$settings" > "$tmp" && jq -e . "$tmp" >/dev/null && mv "$tmp" "$settings"
  echo "removed statusLine from $settings"
fi
rm -f "$dir/statusline.sh" "$dir/.statusline-email"
echo "removed $dir/statusline.sh and its email cache"
