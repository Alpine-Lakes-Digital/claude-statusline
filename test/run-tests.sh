#!/usr/bin/env bash
# Verifies the status line against every sample payload, and asserts that the
# jq path and the python3 fallback produce byte-identical output.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../statusline.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# A copy with the jq branch forced off, to exercise the python3 fallback.
sed 's|if command -v jq >/dev/null 2>&1; then|if false; then|' "$script" > "$tmp/nojq.sh"
chmod +x "$tmp/nojq.sh"

# Countdown timers are wall-clock derived; mask them before comparing runs.
mask_clock() { sed 's/↻[^ ]*/↻X/g'; }

fail=0
for p in full no-rates null-ctx deep no-effort max-effort bare garbage empty; do
  payload=$("$here/payloads.sh" "$p")

  out=$(printf '%s' "$payload" | CLAUDE_ACCOUNT_EMAIL=user@example.com bash "$script"); rc=$?
  if (( rc != 0 )); then echo "FAIL $p: exit $rc (must always exit 0)"; fail=1; continue; fi

  alt=$(printf '%s' "$payload" | CLAUDE_ACCOUNT_EMAIL=user@example.com bash "$tmp/nojq.sh")
  # The reset countdowns come from the wall clock at render time, so the two
  # runs above can legitimately straddle a second boundary (2h0m vs 1h59m).
  # Mask them: they are a function of time, not of which parser ran.
  if [[ "$(mask_clock <<< "$out")" != "$(mask_clock <<< "$alt")" ]]; then
    echo "FAIL $p: jq and python3 output differ"; fail=1; continue
  fi

  echo "ok   $p"
done

# Assert real values, not just that the two parser paths agree. Agreement alone
# passed while both paths rendered every number 10x too high.
ESC=$(printf '\033')
strip_ansi() { sed "s/${ESC}\[[0-9;]*m//g"; }
rendered=$("$here/payloads.sh" full | CLAUDE_ACCOUNT_EMAIL=user@example.com bash "$script" | strip_ansi)

for want in '19%' '193.4k' '42%' '88%' '1.0M ctx' 'medium'; do
  if [[ "$rendered" != *"$want"* ]]; then
    echo "FAIL values: expected '$want' in rendered output"; fail=1
  fi
done
# Regression guard for the CR/int() append bug: the 10x forms must not appear.
for bad in '190%' '420%' '880%' '1.9M'; do
  if [[ "$rendered" == *"$bad"* ]]; then
    echo "FAIL values: found 10x artifact '$bad' (int() appending its fallback?)"; fail=1
  fi
done
(( fail == 0 )) && echo "ok   values"

echo
echo "--- rendered (payload: full) ---"
"$here/payloads.sh" full | CLAUDE_ACCOUNT_EMAIL=user@example.com bash "$script"
echo
exit $fail
