#!/usr/bin/env bash
# Post a spike report to its GitHub issue (issue number is read from the report header).
# Usage: scripts/post-results.sh spike-results/<ts>/s05_pod.txt
set -euo pipefail
f="$1"
issue=$(head -1 "$f" | sed -n 's/.*issue #\([0-9]*\).*/\1/p')
[ -n "$issue" ] || { echo "no issue number in $f"; exit 1; }
body=$(printf 'Spike run %s\n\n```\n%s\n```\n' "$(basename "$(dirname "$f")")" "$(cat "$f")")
gh issue comment "$issue" --body "$body"
