#!/bin/bash
# daily-inbox-fallback.sh — fallback runner for a SECOND machine.
#
# The always-on host stays the PRIMARY runner (*/15 cadence). This script runs on a
# second machine (e.g. a laptop) on a slower schedule and only steps in when the primary
# has clearly missed its window: it runs the real processor only if the OLDEST pending
# Inbox capture has been waiting longer than THRESH_MIN minutes (>= 2 missed primary
# cycles). Otherwise it exits without touching anything, so the two machines never
# contend for the same files in normal operation.
#
# When it does step in, it first drops a `#prompt: nudge` notice capture so the day's
# note itself records that the fallback fired and the primary host needs a look.
set -euo pipefail

# Set these for your instance (or export the env vars).
SYNC_ROOT="${DAILY_LOOP_SYNC_ROOT:-$HOME/CloudDrive/AI}"      # the synced folder
REPO="${DAILY_LOOP_REPO:-$SYNC_ROOT/your-context-repo}"        # your private context repo clone
INBOX="${DAILY_LOOP_INBOX:-$SYNC_ROOT/Inbox}"
THRESH_MIN="${DAILY_LOOP_FALLBACK_THRESH_MIN:-40}"
PRIMARY_HOST="${DAILY_LOOP_ALLOWED_HOST:-}"                    # the always-on host's short hostname

if [[ -n "$PRIMARY_HOST" && "$(hostname -s)" == "$PRIMARY_HOST" ]]; then
  echo "fallback: refusing to run on the primary host (it has the primary task)"; exit 0
fi

pending=()
while IFS= read -r -d '' f; do
  base="$(basename "$f")"
  [[ "$base" == "README.md" ]] && continue
  pending+=("$f")
done < <(find "$INBOX" -maxdepth 1 -type f \( -name '*.md' -o -name '*.txt' \) -print0)

if [[ ${#pending[@]} -eq 0 ]]; then
  echo "fallback: inbox empty — nothing to do"; exit 0
fi

now=$(date +%s); oldest=$now
for f in "${pending[@]}"; do
  m=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f")   # macOS / Linux
  (( m < oldest )) && oldest=$m
done
age_min=$(( (now - oldest) / 60 ))

if (( age_min < THRESH_MIN )); then
  echo "fallback: ${#pending[@]} capture(s) pending, oldest ${age_min}m (<${THRESH_MIN}m) — leaving them for the primary host"
  exit 0
fi

echo "fallback: primary host missed its window (oldest capture waited ${age_min}m; ${#pending[@]} pending) — running processor on $(hostname -s)"

notice="$INBOX/$(date +%Y-%m-%d-%H%M)-fallback-notice.md"
if ! ls "$INBOX"/*-fallback-notice.md >/dev/null 2>&1; then
  printf '#prompt: nudge\n- [ ] ⚠️ Daily Loop ran on the **fallback machine** — the primary host missed its window (oldest capture waited %sm). Check the primary host.\n' "$age_min" > "$notice"
fi

# The fallback must NOT set DAILY_LOOP_ALLOWED_HOST when exec'ing the processor,
# or the processor's own single-host guard would refuse to run here.
DAILY_LOOP_ALLOWED_HOST="" exec /bin/bash "$REPO/daily-loop/bin/daily-inbox-processor.sh"
