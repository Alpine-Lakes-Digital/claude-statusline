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

fail=0
for p in full no-rates null-ctx deep no-effort max-effort bare garbage empty; do
  payload=$("$here/payloads.sh" "$p")

  out=$(printf '%s' "$payload" | CLAUDE_ACCOUNT_EMAIL=user@example.com bash "$script"); rc=$?
  if (( rc != 0 )); then echo "FAIL $p: exit $rc (must always exit 0)"; fail=1; continue; fi

  alt=$(printf '%s' "$payload" | CLAUDE_ACCOUNT_EMAIL=user@example.com bash "$tmp/nojq.sh")
  if [[ "$out" != "$alt" ]]; then echo "FAIL $p: jq and python3 output differ"; fail=1; continue; fi

  echo "ok   $p"
done

echo
echo "--- rendered (payload: full) ---"
"$here/payloads.sh" full | CLAUDE_ACCOUNT_EMAIL=user@example.com bash "$script"
echo
exit $fail
