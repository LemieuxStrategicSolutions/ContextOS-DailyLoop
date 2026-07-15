#!/usr/bin/env bash
#
# daily-loop installer — set the loop up in a private context repo.
#
# Idempotent and non-interactive: safe to re-run, safe to call from another installer.
# It never schedules anything and never touches git — scheduling is a deliberate act you
# perform after the preflight passes and after you've registered the job in your
# automation registry.
#
# Usage:
#   bin/install.sh --repo <path> --sync-root <path> [options]
#
# Required:
#   --repo <path>          your private context repo (gets daily-loop/ + daily/)
#   --sync-root <path>     the synced folder your phone can write into (gets Inbox/, Prompts/)
#
# Common options:
#   --owner <name>         how engine prompts refer to you           (default: the user)
#   --tz <IANA>            daily rollover timezone                   (default: UTC)
#   --allowed-host <name>  only run on this host (`hostname -s`)     (default: this host)
#   --memory-mcp <name>    memory connector, headless display name   ("" = none)
#   --calendar-mcp <name>  calendar connector, headless display name ("" = none)
#   --force                overwrite an existing daily-loop.conf
#   --no-samples           skip copying the example captures
#   --skip-preflight       don't run the test suite (use when the caller already did --
#                          also stops the module's own tests recursing into this script)
#   --dry-run              print what would happen, change nothing
#
set -euo pipefail

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

REPO=""
SYNC_ROOT=""
OWNER="the user"
TZ_NAME="UTC"
ALLOWED_HOST="$(hostname -s 2>/dev/null || echo "")"
MEMORY_MCP="mcp__claude_ai_Memory"
CALENDAR_MCP="mcp__claude_ai_Google_Calendar"
FORCE=0
SAMPLES=1
DRY=0
PREFLIGHT=1

die()  { printf 'install: %s\n' "$1" >&2; exit 1; }
say()  { printf '  --   %s\n' "$1"; }
step() { printf '\n%s\n' "$1"; }

# run <description> <cmd...> — do the thing, or in a dry run describe it. Never print a
# success line for work that didn't happen: an installer that says "created" during
# --dry-run is lying to you, and you'd only find out later.
run() {
  local what="$1"; shift
  if [[ "$DRY" == "1" ]]; then printf '  [dry] %s\n' "$what"; return 0; fi
  "$@"
  printf '  ok   %s\n' "$what"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)          REPO="${2:-}"; shift 2 ;;
    --sync-root)     SYNC_ROOT="${2:-}"; shift 2 ;;
    --owner)         OWNER="${2:-}"; shift 2 ;;
    --tz)            TZ_NAME="${2:-}"; shift 2 ;;
    --allowed-host)  ALLOWED_HOST="${2:-}"; shift 2 ;;
    --memory-mcp)    MEMORY_MCP="${2:-}"; shift 2 ;;
    --calendar-mcp)  CALENDAR_MCP="${2:-}"; shift 2 ;;
    --force)         FORCE=1; shift ;;
    --no-samples)    SAMPLES=0; shift ;;
    --skip-preflight) PREFLIGHT=0; shift ;;
    --dry-run)       DRY=1; shift ;;
    -h|--help)       sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)               die "unknown option: $1 (try --help)" ;;
  esac
done

[[ -n "$REPO" ]]      || die "--repo is required (try --help)"
[[ -n "$SYNC_ROOT" ]] || die "--sync-root is required (try --help)"
[[ -d "$REPO" ]]      || die "--repo is not a directory: $REPO"
[[ -d "$SYNC_ROOT" ]] || die "--sync-root is not a directory: $SYNC_ROOT"

REPO="$(cd "$REPO" && pwd)"
SYNC_ROOT="$(cd "$SYNC_ROOT" && pwd)"
CONF="$REPO/daily-loop/daily-loop.conf"

[[ "$DRY" == "1" ]] && printf '\n(dry run — nothing will be changed)\n'

step "1. Directories"
for d in "$REPO/daily-loop/bin" "$REPO/daily" "$SYNC_ROOT/Inbox/processed" "$SYNC_ROOT/Prompts"; do
  if [[ -d "$d" ]]; then say "$d (exists)"; else run "create $d" mkdir -p "$d"; fi
done

step "2. Processor and helpers → $REPO/daily-loop/bin/"
for f in daily-inbox-processor.sh daily-inbox-fallback.sh ledger.py strip_daily_header.py; do
  run "install $f" cp "$MODULE_DIR/bin/$f" "$REPO/daily-loop/bin/$f"
done
run "mark the runners executable" chmod +x \
  "$REPO/daily-loop/bin/daily-inbox-processor.sh" "$REPO/daily-loop/bin/daily-inbox-fallback.sh"

step "3. Prompts → $SYNC_ROOT/Prompts/"
for f in "$MODULE_DIR"/prompts/*.md; do
  base="$(basename "$f")"
  [[ "$base" == "README.md" ]] && continue
  if [[ -f "$SYNC_ROOT/Prompts/$base" ]]; then
    say "$base (yours, kept)"     # never clobber a prompt the user has tuned
  else
    run "install $base" cp "$f" "$SYNC_ROOT/Prompts/$base"
  fi
done

step "4. Config → $CONF"
if [[ -f "$CONF" && "$FORCE" != "1" ]]; then
  say "$CONF (exists, kept — use --force to overwrite)"
else
  if [[ "$DRY" == "1" ]]; then
    printf '  [dry] write %s\n' "$CONF"
  else
    cat > "$CONF" <<CONF_EOF
# Daily Loop configuration — written by install.sh on $(date +%Y-%m-%d).
# Precedence: real environment > this file > built-in default.
# Full annotated reference: daily-loop.conf.example in the module.

: "\${DAILY_LOOP_ALLOWED_HOST:=$ALLOWED_HOST}"
: "\${DAILY_LOOP_TZ:=$TZ_NAME}"
: "\${DAILY_LOOP_OWNER:=$OWNER}"

: "\${DAILY_LOOP_REPO:=$REPO}"
: "\${DAILY_LOOP_SYNC_ROOT:=$SYNC_ROOT}"

# Connector display names as a HEADLESS call sees them (mcp__claude_ai_<Name>) — NOT the
# mcp__<uuid> form a desktop session shows. An empty value means "I don't have this one".
DAILY_LOOP_MEMORY_MCP="\${DAILY_LOOP_MEMORY_MCP-$MEMORY_MCP}"
DAILY_LOOP_CALENDAR_MCP="\${DAILY_LOOP_CALENDAR_MCP-$CALENDAR_MCP}"

# Your connector's tool verbs, if they differ from these defaults.
# : "\${DAILY_LOOP_MEMORY_CAPTURE_TOOL:=capture_thought}"
# : "\${DAILY_LOOP_MEMORY_SEARCH_TOOL:=search_thoughts}"
# : "\${DAILY_LOOP_MEMORY_LIST_TOOL:=list_thoughts}"
# : "\${DAILY_LOOP_CALENDAR_LIST_TOOL:=list_events}"
CONF_EOF
    printf '  ok   write %s\n' "$CONF"
  fi
  [[ -z "$MEMORY_MCP"   ]] && say "note: no memory connector — the sync step will have no memory tools."
  [[ -z "$CALENDAR_MCP" ]] && say "note: no calendar connector — the skeleton will have no schedule."
fi

if [[ "$SAMPLES" == "1" ]]; then
  step "5. Sample captures → $SYNC_ROOT/Inbox/"
  for f in "$MODULE_DIR"/examples/inbox/*.md; do
    [[ -e "$f" ]] || continue
    run "copy $(basename "$f")" cp "$f" "$SYNC_ROOT/Inbox/$(basename "$f")"
  done
fi

step "6. Preflight"
if [[ "$PREFLIGHT" != "1" ]]; then
  say "skipped (--skip-preflight)"
elif [[ "$DRY" == "1" ]]; then
  printf '  [dry] run the module test suite and a stubbed dry run\n' 
else
  if bash "$MODULE_DIR/tests/run-tests.sh" >/dev/null 2>&1; then
    printf '  ok   module test suite passed\n'
  else
    die "module test suite FAILED — not a working install; run: bash $MODULE_DIR/tests/run-tests.sh"
  fi
  if DAILY_LOOP_CONFIG="$CONF" DAILY_LOOP_DRY_RUN=1 DAILY_LOOP_ENGINE_STUB=1 \
     DAILY_LOOP_SYNC_DISABLED=1 DAILY_LOOP_SKELETON_DISABLED=1 DAILY_LOOP_HEALTH_DISABLED=1 \
     DAILY_LOOP_ALLOWED_HOST="$(hostname -s)" \
     bash "$REPO/daily-loop/bin/daily-inbox-processor.sh" >/dev/null 2>&1; then
    printf '  ok   stubbed dry run against your paths passed\n'
  else
    die "stubbed dry run FAILED — check the paths in $CONF"
  fi
fi

cat <<NEXT

Installed. Nothing is scheduled and nothing was committed — both are deliberate.

Next, in order:
  1. Verify your connectors resolve in a HEADLESS call (this is GOTCHAS #2, and it is the
     single most common silent failure — a name that works interactively can match nothing
     unattended):
       DAILY_LOOP_DRY_RUN=1 bash $REPO/daily-loop/bin/daily-inbox-processor.sh
  2. Read what it produced:
       $REPO/daily/\$(date +%F).md
  3. Register the job in your automation registry BEFORE it first runs. No silent automations.
  4. Schedule it every ~15 min as your AI agent's own scheduled task. On macOS do NOT use
     launchd if any path is cloud-synced — children hang forever on synced reads (GOTCHAS #1).
  5. Point your phone at $SYNC_ROOT/Inbox/ — any tool that drops a text file named
     YYYY-MM-DD-HHMM-<label>.md will do. The filename's date decides the note's day.
NEXT
