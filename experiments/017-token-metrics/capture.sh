#!/bin/sh
# capture.sh -- snapshot token usage from the session transcript into data/.
#
# Read-only. Writes one TSV row per TRANSCRIPT ROW, not per API call: the
# collapse to calls happens in derive.py, where the rule is written down and
# can be argued with. A capture that silently deduplicates hides the 1.91x.
#
# The transcript lives outside the repo and is not committed (30MB, and it is
# the session's own text). data/usage.tsv is the committed evidence.
set -eu
proj="${1:-$HOME/.claude/projects/-home-jwalsh-ghq-github-com-aygp-dr-slipway}"
out="$(dirname "$0")/data/usage.tsv"
jq -rc 'select(.message.usage != null) |
  [ .message.id, .timestamp, (.message.model // "-"), (.isSidechain // false),
    (.message.usage.input_tokens // 0),
    (.message.usage.cache_creation_input_tokens // 0),
    (.message.usage.cache_read_input_tokens // 0),
    (.message.usage.output_tokens // 0),
    (.message.usage.output_tokens_details.thinking_tokens // 0)
  ] | @tsv' "$proj"/*.jsonl > "$out"
printf 'captured %s rows, %s distinct calls -> %s\n' \
  "$(wc -l < "$out" | tr -d ' ')" \
  "$(cut -f1 "$out" | sort -u | wc -l | tr -d ' ')" "$out"
