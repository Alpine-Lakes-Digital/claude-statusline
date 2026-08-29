#!/usr/bin/env bash
# ~/.claude/statusline.sh — three-line Claude Code status line.
#
#   line 1  working directory (abbreviated) + git branch, dirty marker
#   line 2  account email · model id · context window size
#   line 3  context usage bar · 5-hour limit · 7-day limit, each with reset timer
#
# Env overrides:
#   CLAUDE_STATUSLINE_BAR=0          hide the bars, show percentages only
#   CLAUDE_STATUSLINE_BAR_WIDTH=N    bar width in characters (default 10)
#   CLAUDE_ACCOUNT_EMAIL=...         skip the `claude auth status` lookup
#
# Reads session JSON on stdin. Every field is optional: rate_limits appears only
# for Pro/Max accounts and only after the first API response, and context_window
# is null early in a session and again after /compact.

set -uo pipefail

input=$(cat)

# ---------- JSON access ----------
# One extraction pass, not one subprocess per field: this script runs on every
# assistant message. Emits the fields below as newline-separated values, in order.
if command -v jq >/dev/null 2>&1; then
  RAW=$(printf '%s' "$input" | jq -r '
    def g(p): (p // "") | if type == "object" or type == "array" then "" else tostring end;
    [ g(.workspace.current_dir), g(.cwd), g(.model.id), g(.model.display_name),
      g(.context_window.used_percentage), g(.context_window.total_input_tokens),
      g(.context_window.total_output_tokens), g(.context_window.context_window_size),
      g(.rate_limits.five_hour.used_percentage), g(.rate_limits.five_hour.resets_at),
      g(.rate_limits.seven_day.used_percentage), g(.rate_limits.seven_day.resets_at)
    ] | .[]' 2>/dev/null)
elif command -v python3 >/dev/null 2>&1; then
  # Correct path-aware fallback. Leaf names in this schema are NOT unique
  # (used_percentage and resets_at each appear three times), so any grep-based
  # extractor would silently report the wrong window.
  RAW=$(printf '%s' "$input" | python3 -c '
import json, sys
try: d = json.load(sys.stdin)
except Exception: d = {}
def g(*path):
    c = d
    for k in path:
        if not isinstance(c, dict): return ""
        c = c.get(k)
        if c is None: return ""
    return "" if isinstance(c, (dict, list)) else str(c)
for p in [("workspace","current_dir"),("cwd",),("model","id"),("model","display_name"),
          ("context_window","used_percentage"),("context_window","total_input_tokens"),
          ("context_window","total_output_tokens"),("context_window","context_window_size"),
          ("rate_limits","five_hour","used_percentage"),("rate_limits","five_hour","resets_at"),
          ("rate_limits","seven_day","used_percentage"),("rate_limits","seven_day","resets_at")]:
    print(g(*p))
' 2>/dev/null)
else
  printf 'statusline: needs jq or python3 on PATH\n'
  exit 0
fi

# mapfile, not `read -a`: newline is IFS whitespace, so read would collapse
# consecutive blank fields and shift every later index.
mapfile -t F <<< "$RAW"
f() { printf '%s' "${F[$1]:-}"; }

# ---------- colors ----------
E=$'\033'
RST="${E}[0m"; DIM="${E}[2m"; BOLD="${E}[1m"
CYAN="${E}[38;2;90;180;220m"
MAUVE="${E}[38;2;170;140;220m"
GREY="${E}[38;2;130;130;140m"

# Green -> yellow -> red across 0..100.
grad() {
  local p=$1 r g
  (( p < 0 )) && p=0; (( p > 100 )) && p=100
  if (( p <= 50 )); then r=$(( 60 + (180 * p) / 50 )); g=200
  else r=235; g=$(( 200 - (165 * (p - 50)) / 50 )); fi
  printf '%s[38;2;%d;%d;60m' "$E" "$r" "$g"
}

BARW="${CLAUDE_STATUSLINE_BAR_WIDTH:-10}"
bar() {
  local p=$1 filled i out=""
  [[ "${CLAUDE_STATUSLINE_BAR:-1}" == "0" ]] && return
  (( p < 0 )) && p=0; (( p > 100 )) && p=100
  filled=$(( (p * BARW + 50) / 100 ))
  for (( i = 0; i < BARW; i++ )); do
    if (( i < filled )); then out+="█"; else out+="░"; fi
  done
  printf '%s ' "$out"
}

# ---------- formatting helpers ----------
int() { printf '%.0f' "${1:-0}" 2>/dev/null || printf '0'; }

fmt_tok() {
  local n=${1:-0}
  if   (( n >= 1000000 )); then printf '%d.%dM' $(( n / 1000000 )) $(( (n % 1000000) / 100000 ))
  elif (( n >= 1000 ));    then printf '%d.%dk' $(( n / 1000 ))    $(( (n % 1000) / 100 ))
  else printf '%d' "$n"; fi
}

rel() {  # seconds-until, from a unix epoch timestamp
  local t=${1:-0} now d h m
  now=$(date +%s); d=$(( t - now ))
  (( d <= 0 )) && { printf 'now'; return; }
  h=$(( d / 3600 )); m=$(( (d % 3600) / 60 ))
  if   (( h >= 24 )); then printf '%dd%dh' $(( h / 24 )) $(( h % 24 ))
  elif (( h > 0 ));   then printf '%dh%dm' "$h" "$m"
  else printf '%dm' "$m"; fi
}

short_dir() {
  local d=${1:-} rest
  [[ -z $d ]] && { printf '?'; return; }
  if [[ $d == "$HOME" ]]; then printf '~'; return; fi
  [[ $d == "$HOME"/* ]] && d="~/${d#"$HOME"/}"
  # Keep the last three segments; elide the rest.
  rest=${d#/}; rest=${rest#\~/}
  if (( $(tr -cd '/' <<< "$rest" | wc -c) >= 3 )); then
    printf '…/%s' "$(rev <<< "$rest" | cut -d/ -f1-3 | rev)"
  else
    printf '%s' "$d"
  fi
}

# ---------- gather ----------
DIR=$(f 0);  [[ -z $DIR ]] && DIR=$(f 1)
MODEL=$(f 2); [[ -z $MODEL ]] && MODEL=$(f 3)

CW_PCT=$(f 4); CW_IN=$(f 5); CW_OUT=$(f 6); CW_SIZE=$(f 7)
R5_PCT=$(f 8); R5_AT=$(f 9)
R7_PCT=$(f 10); R7_AT=$(f 11)

# ---------- account email (cached; refreshed in the background) ----------
EMAIL="${CLAUDE_ACCOUNT_EMAIL:-}"
CACHE="$HOME/.claude/.statusline-email"
if [[ -z $EMAIL ]]; then
  [[ -s $CACHE ]] && EMAIL=$(< "$CACHE")
  age=$(( $(date +%s) - $(stat -c %Y "$CACHE" 2>/dev/null || echo 0) ))
  if (( age > 86400 )) && command -v claude >/dev/null 2>&1; then
    # Never block the status line on this: refresh detached, use the stale value now.
    ( timeout 10 claude auth status 2>/dev/null \
        | sed -n 's/.*"email"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p' > "$CACHE.tmp" \
      && [[ -s "$CACHE.tmp" ]] && mv "$CACHE.tmp" "$CACHE" || rm -f "$CACHE.tmp" ) \
      >/dev/null 2>&1 &
    disown 2>/dev/null || true
  fi
fi

# ---------- line 1: directory + branch ----------
L1="${CYAN}${BOLD}$(short_dir "$DIR")${RST}"
if [[ -n $DIR ]] && BR=$(git -C "$DIR" rev-parse --abbrev-ref HEAD 2>/dev/null); then
  DIRTY=""
  git -C "$DIR" diff --quiet --ignore-submodules HEAD 2>/dev/null || DIRTY="*"
  L1+=" ${GREY}on${RST} ${MAUVE}${BR}${DIRTY}${RST}"
fi

# ---------- line 2: account · model · window size ----------
L2_PARTS=()
[[ -n $EMAIL ]] && L2_PARTS+=("${GREY}${EMAIL}${RST}")
[[ -n $MODEL ]] && L2_PARTS+=("${MAUVE}${MODEL}${RST}")
if [[ -n $CW_SIZE ]]; then
  L2_PARTS+=("${GREY}$(fmt_tok "$(int "$CW_SIZE")") ctx${RST}")
fi
L2=""
for p in "${L2_PARTS[@]}"; do [[ -n $L2 ]] && L2+="${DIM} · ${RST}"; L2+="$p"; done

# ---------- line 3: context + rate limits ----------
L3_PARTS=()
if [[ -n $CW_PCT ]]; then
  p=$(int "$CW_PCT"); c=$(grad "$p")
  seg="${c}$(bar "$p")${p}%${RST}"
  if [[ -n $CW_IN || -n $CW_OUT ]]; then
    tot=$(( $(int "${CW_IN:-0}") + $(int "${CW_OUT:-0}") ))
    seg+=" ${DIM}$(fmt_tok "$tot")${RST}"
  fi
  L3_PARTS+=("${GREY}ctx${RST} $seg")
fi
if [[ -n $R5_PCT ]]; then
  p=$(int "$R5_PCT"); c=$(grad "$p")
  seg="${c}$(bar "$p")${p}%${RST}"
  [[ -n $R5_AT ]] && seg+=" ${DIM}↻$(rel "$(int "$R5_AT")")${RST}"
  L3_PARTS+=("${GREY}5h${RST} $seg")
fi
if [[ -n $R7_PCT ]]; then
  p=$(int "$R7_PCT"); c=$(grad "$p")
  seg="${c}$(bar "$p")${p}%${RST}"
  [[ -n $R7_AT ]] && seg+=" ${DIM}↻$(rel "$(int "$R7_AT")")${RST}"
  L3_PARTS+=("${GREY}7d${RST} $seg")
fi
L3=""
for p in "${L3_PARTS[@]}"; do [[ -n $L3 ]] && L3+="${DIM}  │  ${RST}"; L3+="$p"; done

# ---------- emit ----------
printf '%s\n' "$L1"
[[ -n $L2 ]] && printf '%s\n' "$L2"
[[ -n $L3 ]] && printf '%s\n' "$L3"
exit 0
