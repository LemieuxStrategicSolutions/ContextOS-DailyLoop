#!/usr/bin/env bash
#
# Daily Loop processor tests — idempotency, recovery, routing, and the guards.
#
# Pure bash, no framework, no network, no agent, no git. Every test runs the real
# processor against a throwaway sandbox with DRY_RUN=1 (no git) and either the built-in
# ENGINE_STUB or a fake agent binary, so the plumbing under test is the real thing.
#
# The properties that matter most here are the ones an unattended loop lives or dies on:
#   - a capture is NEVER lost when the engine fails
#   - reprocessing NEVER duplicates an entry
#   - a crashed run's lock self-heals instead of wedging the loop forever
#
# Usage: bash tests/run-tests.sh
#
set -uo pipefail

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROC="$MODULE_DIR/bin/daily-inbox-processor.sh"

PASS=0
FAIL=0
CURRENT=""

ok()   { printf '  \033[32mok\033[0m    %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n     %s\n' "$1" "${2:-}"; FAIL=$((FAIL + 1)); }
test_case() { CURRENT="$1"; printf '\n%s\n' "$CURRENT"; }

assert_file()      { [[ -f "$1" ]] && ok "$2" || bad "$2" "expected file to exist: $1"; }
assert_no_file()   { [[ ! -f "$1" ]] && ok "$2" || bad "$2" "expected file to NOT exist: $1"; }
assert_grep()      { grep -qF "$2" "$1" 2>/dev/null && ok "$3" || bad "$3" "expected '$2' in $1"; }
assert_no_grep()   { ! grep -qF "$2" "$1" 2>/dev/null && ok "$3" || bad "$3" "did NOT expect '$2' in $1"; }
assert_count()     { # <file> <needle> <expected> <label>
  local n; n="$(grep -cF "$2" "$1" 2>/dev/null || echo 0)"
  [[ "$n" -eq "$3" ]] && ok "$4" || bad "$4" "expected $3 occurrence(s) of '$2' in $1, found $n"
}

new_sandbox() {
  local s; s="$(mktemp -d 2>/dev/null || mktemp -d -t dailyloop)"
  mkdir -p "$s/sync/Inbox" "$s/sync/Prompts" "$s/repo/daily" "$s/repo/trackers" "$s/repo/daily-loop"
  printf '# Tasks\n\n- [ ] something open\n' > "$s/repo/trackers/TASKS.md"
  printf 'Pass the text through unchanged.\n'  > "$s/sync/Prompts/nudge.md"
  printf 'Summarize the meeting.\n'            > "$s/sync/Prompts/meeting-notes-with-action-items.md"
  printf '%s' "$s"
}

# Run the real processor against a sandbox. Extra env assignments are passed through.
run_proc() {
  local s="$1"; shift
  env \
    DAILY_LOOP_REPO="$s/repo" \
    DAILY_LOOP_SYNC_ROOT="$s/sync" \
    DAILY_LOOP_INBOX="$s/sync/Inbox" \
    DAILY_LOOP_PROMPTS="$s/sync/Prompts" \
    DAILY_LOOP_DAILY="$s/repo/daily" \
    DAILY_LOOP_TASKS="$s/repo/trackers/TASKS.md" \
    DAILY_LOOP_LEDGER="$s/repo/daily-loop/processed.json" \
    DAILY_LOOP_LOG="$s/repo/daily-loop/processor-log.md" \
    DAILY_LOOP_PROCESSED="$s/sync/Inbox/processed" \
    DAILY_LOOP_LOCK="$s/repo/daily-loop/.processor.lock" \
    DAILY_LOOP_HEALTH_LOG="$s/repo/daily-loop/host-health.log" \
    DAILY_LOOP_DRY_RUN=1 \
    DAILY_LOOP_SKELETON_DISABLED=1 \
    DAILY_LOOP_SYNC_DISABLED=1 \
    DAILY_LOOP_HEALTH_DISABLED=1 \
    DAILY_LOOP_TZ=UTC \
    "$@" \
    bash "$PROC" >/dev/null 2>&1
}

# A fake agent binary. `fake_agent <dir> <mode>` where mode is fail | empty | echo.
fake_agent() {
  local path="$1/fake-agent" mode="$2"
  case "$mode" in
    fail)  printf '#!/usr/bin/env bash\nexit 1\n' > "$path" ;;
    empty) printf '#!/usr/bin/env bash\ncat >/dev/null\nexit 0\n' > "$path" ;;
    echo)  printf '#!/usr/bin/env bash\ncat >/dev/null\nprintf "**Summary**\\n- from the fake agent\\n"\n' > "$path" ;;
  esac
  chmod +x "$path"
  printf '%s' "$path"
}

LEDGER_REL="repo/daily-loop/processed.json"
LOG_REL="repo/daily-loop/processor-log.md"

# ---------------------------------------------------------------------------

test_case "happy path: a capture becomes a daily entry, is archived, and is ledgered"
S="$(new_sandbox)"
printf 'picked up milk and thought about the roadmap\n' > "$S/sync/Inbox/2030-01-05-0900-memo.md"
run_proc "$S" DAILY_LOOP_ENGINE_STUB=1
assert_file    "$S/repo/daily/2030-01-05.md"                     "daily note created for the capture's date"
assert_grep    "$S/repo/daily/2030-01-05.md" "Daily capture"     "entry carries the default heading"
assert_grep    "$S/repo/daily/2030-01-05.md" "Inbox/2030-01-05-0900-memo.md" "entry cites its source file"
assert_file    "$S/sync/Inbox/processed/2030-01-05-0900-memo.md" "source archived to processed/"
assert_no_file "$S/sync/Inbox/2030-01-05-0900-memo.md"           "source no longer in the inbox"
assert_grep    "$S/$LEDGER_REL" "2030-01-05-0900-memo.md"        "capture recorded in the ledger"

test_case "idempotency: the ledger stops a re-dropped capture from double-posting"
S="$(new_sandbox)"
printf 'one capture\n' > "$S/sync/Inbox/2030-01-05-0900-memo.md"
run_proc "$S" DAILY_LOOP_ENGINE_STUB=1
cp "$S/sync/Inbox/processed/2030-01-05-0900-memo.md" "$S/sync/Inbox/"   # simulate a re-sync/restore
run_proc "$S" DAILY_LOOP_ENGINE_STUB=1
assert_count "$S/repo/daily/2030-01-05.md" "Inbox/2030-01-05-0900-memo.md" 1 "daily note still has exactly one entry"
assert_file  "$S/sync/Inbox/2030-01-05-0900-memo.md" "the re-dropped file is left alone, not reprocessed"

test_case "idempotency: a second tick with nothing new changes nothing"
S="$(new_sandbox)"
printf 'one capture\n' > "$S/sync/Inbox/2030-01-05-0900-memo.md"
run_proc "$S" DAILY_LOOP_ENGINE_STUB=1
BEFORE="$(shasum "$S/repo/daily/2030-01-05.md" | cut -d' ' -f1)"
run_proc "$S" DAILY_LOOP_ENGINE_STUB=1
AFTER="$(shasum "$S/repo/daily/2030-01-05.md" | cut -d' ' -f1)"
[[ "$BEFORE" == "$AFTER" ]] && ok "daily note is byte-identical after an empty tick" \
                            || bad "daily note is byte-identical after an empty tick" "hash changed"

test_case "a capture is never lost: engine failure leaves the source in the inbox"
S="$(new_sandbox)"; AGENT="$(fake_agent "$S" fail)"
printf 'important capture\n' > "$S/sync/Inbox/2030-01-05-0900-memo.md"
run_proc "$S" DAILY_LOOP_CLAUDE="$AGENT" DAILY_LOOP_ENGINE_TIMEOUT=15
assert_file    "$S/sync/Inbox/2030-01-05-0900-memo.md"           "source still in the inbox for retry"
assert_no_file "$S/sync/Inbox/processed/2030-01-05-0900-memo.md" "source NOT archived"
assert_no_file "$S/repo/daily/2030-01-05.md"                     "no daily entry written"
assert_no_grep "$S/$LEDGER_REL" "2030-01-05-0900-memo.md"        "not ledgered"
assert_grep    "$S/$LOG_REL" "left for retry"                    "failure logged as retryable"

test_case "a capture is never lost: empty engine output is treated as failure"
S="$(new_sandbox)"; AGENT="$(fake_agent "$S" empty)"
printf 'important capture\n' > "$S/sync/Inbox/2030-01-05-0900-memo.md"
run_proc "$S" DAILY_LOOP_CLAUDE="$AGENT" DAILY_LOOP_ENGINE_TIMEOUT=15
assert_file    "$S/sync/Inbox/2030-01-05-0900-memo.md"           "source still in the inbox for retry"
assert_no_grep "$S/$LEDGER_REL" "2030-01-05-0900-memo.md"        "not ledgered"

test_case "recovery: a capture stranded by a failed tick is processed on the next one"
S="$(new_sandbox)"; AGENT="$(fake_agent "$S" fail)"
printf 'important capture\n' > "$S/sync/Inbox/2030-01-05-0900-memo.md"
run_proc "$S" DAILY_LOOP_CLAUDE="$AGENT" DAILY_LOOP_ENGINE_TIMEOUT=15
assert_file "$S/sync/Inbox/2030-01-05-0900-memo.md" "still stranded after the failing tick"
run_proc "$S" DAILY_LOOP_ENGINE_STUB=1                                  # engine recovers
assert_file    "$S/repo/daily/2030-01-05.md"                     "processed on the recovery tick"
assert_file    "$S/sync/Inbox/processed/2030-01-05-0900-memo.md" "archived on the recovery tick"
assert_grep    "$S/$LEDGER_REL" "2030-01-05-0900-memo.md"        "ledgered on the recovery tick"

test_case "lock: a live lock makes the tick a no-op"
S="$(new_sandbox)"
mkdir -p "$S/repo/daily-loop/.processor.lock"
printf 'capture\n' > "$S/sync/Inbox/2030-01-05-0900-memo.md"
run_proc "$S" DAILY_LOOP_ENGINE_STUB=1
assert_file    "$S/sync/Inbox/2030-01-05-0900-memo.md" "capture untouched while another run holds the lock"
assert_no_file "$S/repo/daily/2030-01-05.md"           "no daily entry written"

test_case "recovery: a stale lock from a crashed run self-heals instead of wedging forever"
S="$(new_sandbox)"
mkdir -p "$S/repo/daily-loop/.processor.lock"
printf 'capture\n' > "$S/sync/Inbox/2030-01-05-0900-memo.md"
sleep 1
run_proc "$S" DAILY_LOOP_ENGINE_STUB=1 DAILY_LOOP_LOCK_STALE_SECS=0
assert_file "$S/repo/daily/2030-01-05.md" "processed after clearing the stale lock"
assert_grep "$S/$LOG_REL" "cleared a stale lock" "stale-lock clearance is logged, not silent"

test_case "the lock is released on exit so the next tick can run"
S="$(new_sandbox)"
printf 'capture\n' > "$S/sync/Inbox/2030-01-05-0900-memo.md"
run_proc "$S" DAILY_LOOP_ENGINE_STUB=1
assert_no_file "$S/repo/daily-loop/.processor.lock/." "lock directory removed after the run"

test_case "routing: an explicit #prompt selects that prompt"
S="$(new_sandbox)"
printf '#prompt: nudge\nremember the thing\n' > "$S/sync/Inbox/2030-01-05-0900-note.md"
run_proc "$S" DAILY_LOOP_ENGINE_STUB=1
assert_grep "$S/repo/daily/2030-01-05.md" "— Nudge" "entry is headed with the routed prompt name"
assert_grep "$S/$LEDGER_REL" "nudge"                "ledger records the prompt used"

test_case "routing: an unknown #prompt falls back to default handling and says so"
S="$(new_sandbox)"
printf '#prompt: does-not-exist\nsome text\n' > "$S/sync/Inbox/2030-01-05-0900-note.md"
run_proc "$S" DAILY_LOOP_ENGINE_STUB=1
assert_grep "$S/repo/daily/2030-01-05.md" "Daily capture"        "fell back to the default heading"
assert_grep "$S/$LOG_REL" "requested unknown prompt"             "fallback is logged, not silent"

test_case "the capture's filename date decides its day, not the clock"
S="$(new_sandbox)"
printf 'a capture from the past\n' > "$S/sync/Inbox/2029-12-25-0800-memo.md"
run_proc "$S" DAILY_LOOP_ENGINE_STUB=1
assert_file    "$S/repo/daily/2029-12-25.md"          "entry landed on the filename's date"
assert_no_file "$S/repo/daily/$(date +%Y-%m-%d).md"   "entry did NOT land on today"

test_case "the host guard keeps every other machine out of the loop"
S="$(new_sandbox)"
printf 'capture\n' > "$S/sync/Inbox/2030-01-05-0900-memo.md"
run_proc "$S" DAILY_LOOP_ENGINE_STUB=1 DAILY_LOOP_ALLOWED_HOST="not-this-host-$$"
assert_file    "$S/sync/Inbox/2030-01-05-0900-memo.md" "capture untouched on a non-allowed host"
assert_no_file "$S/repo/daily/2030-01-05.md"           "no daily entry written"

test_case "housekeeping files in the inbox are ignored"
S="$(new_sandbox)"
printf 'not a capture\n' > "$S/sync/Inbox/README.md"
printf 'hidden\n'        > "$S/sync/Inbox/.DS_Store.md"
run_proc "$S" DAILY_LOOP_ENGINE_STUB=1
assert_file    "$S/sync/Inbox/README.md"         "README left in place"
assert_no_grep "$S/$LEDGER_REL" "README.md"      "README not ledgered"

test_case "config file: settings are read from one file instead of the environment"
S="$(new_sandbox)"
printf 'capture\n' > "$S/sync/Inbox/2030-01-05-0900-memo.md"
cat > "$S/repo/daily-loop/daily-loop.conf" <<CONF
: "\${DAILY_LOOP_OWNER:=Configured Owner}"
: "\${DAILY_LOOP_ALLOWED_HOST:=not-this-host-$$}"
CONF
run_proc "$S" DAILY_LOOP_ENGINE_STUB=1 DAILY_LOOP_CONFIG="$S/repo/daily-loop/daily-loop.conf"
assert_file    "$S/sync/Inbox/2030-01-05-0900-memo.md" "host guard set purely from the config file took effect"
assert_no_file "$S/repo/daily/2030-01-05.md"           "no daily entry written"

test_case "config file: the real environment still wins over the config file"
S="$(new_sandbox)"
printf 'capture\n' > "$S/sync/Inbox/2030-01-05-0900-memo.md"
cat > "$S/repo/daily-loop/daily-loop.conf" <<CONF
: "\${DAILY_LOOP_ALLOWED_HOST:=not-this-host-$$}"
CONF
run_proc "$S" DAILY_LOOP_ENGINE_STUB=1 DAILY_LOOP_CONFIG="$S/repo/daily-loop/daily-loop.conf" \
         DAILY_LOOP_ALLOWED_HOST="$(hostname -s)"
assert_file "$S/repo/daily/2030-01-05.md" "env override beat the config file's host guard"

test_case "adapters: a connector's tool verbs are configurable, not hardcoded"
S="$(new_sandbox)"
cat > "$S/argv-agent" <<'AGENT'
#!/usr/bin/env bash
cat >/dev/null
printf 'ARGV %s\n' "$*"
AGENT
chmod +x "$S/argv-agent"
printf 'capture\n' > "$S/sync/Inbox/2030-01-05-0900-memo.md"
run_proc "$S" DAILY_LOOP_CLAUDE="$S/argv-agent" DAILY_LOOP_ENGINE_TIMEOUT=15 \
         DAILY_LOOP_SYNC_DISABLED=0 \
         DAILY_LOOP_MEMORY_MCP=mcp__vendorX \
         DAILY_LOOP_MEMORY_CAPTURE_TOOL=add_memory \
         DAILY_LOOP_MEMORY_SEARCH_TOOL=find_memory
assert_grep "$S/$LOG_REL" "mcp__vendorX__add_memory"  "memory capture verb reached the allow-list"
assert_grep "$S/$LOG_REL" "mcp__vendorX__find_memory" "memory search verb reached the allow-list"

test_case "adapters: an empty connector name drops its tools instead of passing dangling names"
S="$(new_sandbox)"
cat > "$S/argv-agent" <<'AGENT'
#!/usr/bin/env bash
cat >/dev/null
printf 'ARGV %s\n' "$*"
AGENT
chmod +x "$S/argv-agent"
printf 'capture\n' > "$S/sync/Inbox/2030-01-05-0900-memo.md"
run_proc "$S" DAILY_LOOP_CLAUDE="$S/argv-agent" DAILY_LOOP_ENGINE_TIMEOUT=15 \
         DAILY_LOOP_SYNC_DISABLED=0 DAILY_LOOP_MEMORY_MCP=
assert_grep    "$S/$LOG_REL" "allowedTools Edit,Read" "allow-list is exactly Edit,Read with no memory connector"
assert_no_grep "$S/$LOG_REL" "capture_thought"        "no dangling default tool name leaked in"

test_case "installer: installs, is idempotent, and never clobbers your config"
S="$(mktemp -d)"; mkdir -p "$S/repo/trackers" "$S/sync"; printf '# Tasks\n' > "$S/repo/trackers/TASKS.md"
bash "$MODULE_DIR/bin/install.sh" --repo "$S/repo" --sync-root "$S/sync" --no-samples --skip-preflight >/dev/null 2>&1
assert_file "$S/repo/daily-loop/bin/daily-inbox-processor.sh" "processor installed"
assert_file "$S/repo/daily-loop/daily-loop.conf"              "config written"
assert_file "$S/sync/Prompts/nudge.md"                        "prompts installed"
printf '# hand-tuned by me\n' >> "$S/repo/daily-loop/daily-loop.conf"
printf 'my own prompt\n' > "$S/sync/Prompts/nudge.md"
bash "$MODULE_DIR/bin/install.sh" --repo "$S/repo" --sync-root "$S/sync" --no-samples --skip-preflight >/dev/null 2>&1
assert_grep "$S/repo/daily-loop/daily-loop.conf" "# hand-tuned by me" "re-install kept your config"
assert_grep "$S/sync/Prompts/nudge.md" "my own prompt"              "re-install kept your tuned prompt"

test_case "installer: --dry-run changes nothing"
S="$(mktemp -d)"; mkdir -p "$S/repo/trackers" "$S/sync"; printf '# Tasks\n' > "$S/repo/trackers/TASKS.md"
bash "$MODULE_DIR/bin/install.sh" --repo "$S/repo" --sync-root "$S/sync" --dry-run >/dev/null 2>&1
assert_no_file "$S/repo/daily-loop/bin/daily-inbox-processor.sh" "dry run installed nothing"
assert_no_file "$S/repo/daily-loop/daily-loop.conf"              "dry run wrote no config"

# ---------------------------------------------------------------------------

printf '\n----------------------------------------\n'
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
