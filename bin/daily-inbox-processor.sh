#!/usr/bin/env bash
#
# daily-inbox-processor — the Daily Loop processor.
#
# Runs on ONE always-on machine only (never a second machine — avoids double-processing
# and git collisions; see the ALLOWED_HOST guard).
#
# Once per day (before any captures are processed): SKELETON step — ensure_daily_skeleton
# writes the fixed top of today's daily/YYYY-MM-DD.md:
#   "## ✅ Tasks for the Day" (curated 3-6 items from trackers/TASKS.md, fires first) →
#   "## 📅 Schedule for the Day" (today's calendar) → "## 💡 Insight for the Day" (one
#   thought from the memory connector) → "## 📝 Notes Captured" (empty heading — the
#   per-capture stream below fills this in for the rest of the day). Idempotent — no-op
#   once the skeleton exists for the day. Any stray content already on disk (e.g. a
#   capture that landed before the skeleton ran) is preserved and reattached under Notes
#   Captured, never dropped.
#
# Per new file in the synced Inbox/:
#   1. dedup (already moved/ledgered → skip)
#   2. route: first line `#prompt: <name>` → Prompts/<name>.md, else default handling —
#      the engine first judges if the capture is obviously a meeting/call transcript and,
#      if so, applies the Meeting Notes (with Action Items) prompt; otherwise a light
#      TL;DR only. The daily note carries summaries, not raw transcripts — the source
#      file (full raw text) is preserved at Inbox/processed/.
#   3. run the matching prompt through a headless agent call (`claude -p` by default)
#   4. append the result to  <repo>/daily/YYYY-MM-DD.md  under a timestamped heading
#   5. SYNC step (skipped for the `nudge` passthrough prompt): a second headless call,
#      run from the repo root with Edit + memory-connector tool access, reads
#      trackers/TASKS.md and matches this capture against open items — closes/updates
#      items the capture answered, adds new items it introduced, and banks
#      surprising/non-obvious context to the memory connector. Also propagates closures
#      into today's "## ✅ Tasks for the Day" section ONLY.
#   6. move the source file to Inbox/processed/
#   7. record it in daily-loop/processed.json (audit ledger)
#   8. git pull --rebase → commit (daily/ + trackers/TASKS.md + ledger + log) → push
#   9. log the run to daily-loop/processor-log.md
#
# Capture (Inbox/) and Prompts/ live at the synced-folder root (OUTSIDE the repo — where
# phone capture tools can drop files). The PUBLISHED daily notes live INSIDE the repo
# (daily/) so web sessions and the optional Worker can read them from the git host. The
# physical move to Inbox/processed/ is the hard dedup guard; the JSON ledger is a
# secondary audit trail.
#
# NOTE on the TASKS.md boundary: a stricter variant of this loop stays path-scoped to
# daily/ + ledger + log and never touches trackers/TASKS.md, to avoid git collisions with
# other machines that edit TASKS.md. Letting the sync step edit TASKS.md unattended is a
# deliberate trade: small residual collision risk, accepted because the loop pulls
# --rebase --autostash before AND after every commit. If TASKS.md edits ever start
# fighting another machine's edits, re-scope this first.
#
# Safe to run on a tight schedule — it self-locks, and a failed engine call leaves the
# source file in place for the next run (a capture is never lost). It also self-heals a
# stuck rebase (see git_clear_stuck_rebase): this loop can share its working tree with
# interactive sessions, and a concurrent manual `git rebase` can leave a rebase-merge
# directory behind that makes every subsequent `git pull --rebase` fail outright.
#
# Usage:
#   daily-inbox-processor.sh            # normal run
#   DAILY_LOOP_DRY_RUN=1 ...            # process + write locally, but NO git commit/push
#   DAILY_LOOP_ENGINE_STUB=1 ...        # skip the agent, canned transform (plumbing test)
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Config (every path is env-overridable)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Optional config file — one place to set everything instead of exporting env vars in your
# scheduler. Plain shell using `: "${VAR:=value}"`, sourced BEFORE the defaults below, so
# precedence is: real environment > config file > built-in default. Point elsewhere with
# DAILY_LOOP_CONFIG. See daily-loop.conf.example.
CONFIG_FILE="${DAILY_LOOP_CONFIG:-${DAILY_LOOP_REPO:-$(cd "$SCRIPT_DIR/../.." && pwd)}/daily-loop/daily-loop.conf}"
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
fi

REPO_ROOT="${DAILY_LOOP_REPO:-$(cd "$SCRIPT_DIR/../.." && pwd)}"   # daily-loop/bin -> repo root
SYNC_ROOT="${DAILY_LOOP_SYNC_ROOT:-$(cd "$REPO_ROOT/.." && pwd)}"  # the synced folder holding the repo

INBOX_DIR="${DAILY_LOOP_INBOX:-$SYNC_ROOT/Inbox}"
PROMPTS_DIR="${DAILY_LOOP_PROMPTS:-$SYNC_ROOT/Prompts}"
DAILY_DIR="${DAILY_LOOP_DAILY:-$REPO_ROOT/daily}"
TASKS_FILE="${DAILY_LOOP_TASKS:-$REPO_ROOT/trackers/TASKS.md}"
LEDGER="${DAILY_LOOP_LEDGER:-$REPO_ROOT/daily-loop/processed.json}"
LOG="${DAILY_LOOP_LOG:-$REPO_ROOT/daily-loop/processor-log.md}"
PROCESSED_DIR="${DAILY_LOOP_PROCESSED:-$INBOX_DIR/processed}"
LOCK_DIR="${DAILY_LOOP_LOCK:-$REPO_ROOT/daily-loop/.processor.lock}"
LOCK_STALE_SECS="${DAILY_LOOP_LOCK_STALE_SECS:-1800}"   # self-heal a lock left by a crashed/killed run
HEALTH_LOG="${DAILY_LOOP_HEALTH_LOG:-$REPO_ROOT/daily-loop/host-health.log}"

# How the engine prompts refer to the human whose captures these are.
OWNER_NAME="${DAILY_LOOP_OWNER:-the user}"

TZ_NAME="${DAILY_LOOP_TZ:-UTC}"          # set your IANA timezone — daily rollover follows it
GIT_BRANCH="${DAILY_LOOP_BRANCH:-main}"
CLAUDE_BIN="${DAILY_LOOP_CLAUDE:-claude}"
# Model for the MECHANICAL engine calls (per-capture summarize + once-daily skeleton) — a
# cheaper tier by default: these are text-transform/formatting tasks, not judgment. The
# judgment-heavy SYNC call (matches captures → closes/updates TASKS.md + writes memory) is
# left on the runtime default deliberately.
ENGINE_MODEL="${DAILY_LOOP_ENGINE_MODEL:-sonnet}"
ENGINE_TIMEOUT_SECS="${DAILY_LOOP_ENGINE_TIMEOUT:-600}"   # hard kill guard on every engine call
DRY_RUN="${DAILY_LOOP_DRY_RUN:-0}"
ENGINE_STUB="${DAILY_LOOP_ENGINE_STUB:-0}"
SYNC_DISABLED="${DAILY_LOOP_SYNC_DISABLED:-0}"   # 1 = skip the TASKS.md/memory sync step entirely
SKELETON_DISABLED="${DAILY_LOOP_SKELETON_DISABLED:-0}"   # 1 = skip the once-per-day skeleton
HEALTH_DISABLED="${DAILY_LOOP_HEALTH_DISABLED:-0}"   # 1 = skip the host health check (it can drop an Inbox capture)
# GOTCHA: headless `claude -p` names claude.ai connectors mcp__claude_ai_<Name>, NOT the
# mcp__<uuid> prefix desktop sessions see. Verified live: uuid-prefixed names silently
# matched nothing → every unattended memory/calendar call was permission-blocked. Set
# these to YOUR connectors' headless names.
# NOTE the `-` (not `:-`): an explicitly EMPTY value must survive as empty, because empty
# is how you declare "I have no such connector". With `:-`, setting it to "" would silently
# hand back the default and re-break the very thing you were opting out of.
MEMORY_MCP="${DAILY_LOOP_MEMORY_MCP-mcp__claude_ai_Memory}"
CALENDAR_MCP="${DAILY_LOOP_CALENDAR_MCP-mcp__claude_ai_Google_Calendar}"
# Adapter tool vocabulary. A connector's tool NAMES are vendor-specific — one memory
# connector calls it `capture_thought`, another `add_memory`, another `create_note`. Naming
# only the connector but hardcoding its verbs makes the loop portable in theory and broken
# in practice (the calls silently match nothing — GOTCHAS #2). So the verbs are config too.
# Set the connector name to "" to declare that adapter absent: its tools are then dropped
# from the allow-list rather than passed as dangling names.
MEMORY_CAPTURE_TOOL="${DAILY_LOOP_MEMORY_CAPTURE_TOOL:-capture_thought}"
MEMORY_SEARCH_TOOL="${DAILY_LOOP_MEMORY_SEARCH_TOOL:-search_thoughts}"
MEMORY_LIST_TOOL="${DAILY_LOOP_MEMORY_LIST_TOOL:-list_thoughts}"
CALENDAR_LIST_TOOL="${DAILY_LOOP_CALENDAR_LIST_TOOL:-list_events}"
# Optional hard guard: if set, only run when `hostname -s` matches (keeps every other
# machine out of the loop).
ALLOWED_HOST="${DAILY_LOOP_ALLOWED_HOST:-}"

export TZ="$TZ_NAME"

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------
now_stamp()  { date "+%Y-%m-%d %H:%M:%S %Z"; }
log_line()   { printf '%s\n' "$1" >> "$LOG"; }
note()       { printf '[daily-loop] %s\n' "$1" >&2; }

# Adapter helpers. Resolve a connector verb to its full tool name, or to the empty string
# when that adapter isn't configured — so an absent connector drops out of the allow-list
# and the prompt instead of appearing as a dangling name that matches nothing.
mem_tool()   { [[ -n "$MEMORY_MCP" ]]   && printf '%s__%s' "$MEMORY_MCP" "$1"; }
cal_tool()   { [[ -n "$CALENDAR_MCP" ]] && printf '%s__%s' "$CALENDAR_MCP" "$1"; }

# Join tool names with commas, skipping empties. Allow-lists are COMMA-separated — a
# space-separated list fails silently (GOTCHAS #2), as does a stray leading/trailing comma.
join_tools() {
  local out="" t
  for t in "$@"; do
    [[ -z "$t" ]] && continue
    out="${out:+$out,}$t"
  done
  printf '%s' "$out"
}

# Hard kill guard for every engine call — macOS has no GNU `timeout` by default, so this
# is a bash-native watchdog: run the given function in the background, poll with kill -0,
# SIGTERM then SIGKILL past ENGINE_TIMEOUT_SECS. A killed run logs one line and returns
# 124 — the caller treats that exactly like any other engine failure (leaves the source
# file in place, retries next tick). Never eval/string-build the command — pass a
# function name + args so paths with spaces (cloud-synced folders!) stay safe.
run_with_timeout() {  # run_with_timeout <outfile> <fn> [args...] -> exit status of fn (124 = timed out)
  local outfile="$1"; shift
  "$@" > "$outfile" 2>&1 &
  local pid=$! waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if [[ "$waited" -ge "$ENGINE_TIMEOUT_SECS" ]]; then
      note "engine call (pid $pid) exceeded ${ENGINE_TIMEOUT_SECS}s — killing."
      log_line "- ❌ $(now_stamp) · engine call timed out after ${ENGINE_TIMEOUT_SECS}s — killed (pid $pid), left for retry"
      kill -TERM "$pid" 2>/dev/null; sleep 3; kill -KILL "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 124
    fi
    sleep 3
    waited=$((waited + 3))
  done
  wait "$pid"
}

# Title-case a prompt slug for the daily heading: "meeting-notes" -> "Meeting Notes"
pretty_name() {
  printf '%s\n' "$1" | tr '-' ' ' | awk '{ for (i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2) } 1'
}

# ledger membership / append, via a standalone python helper (args only, no stdin —
# the `python3 - <<HEREDOC` program-on-stdin pattern hangs under some schedulers).
PYBIN="${DAILY_LOOP_PYTHON:-python3}"
LEDGER_PY="$SCRIPT_DIR/ledger.py"

ledger_has() {  # ledger_has <basename> -> exit 0 if present
  "$PYBIN" "$LEDGER_PY" has "$LEDGER" "$1"
}

ledger_add() {  # ledger_add <basename> <prompt> <daily_file>
  "$PYBIN" "$LEDGER_PY" add "$LEDGER" "$1" "$2" "$3" "$(now_stamp)"
}

# ---------------------------------------------------------------------------
# Git safety: self-heal a stuck rebase before doing anything else. This loop can run on
# a shared repo a human session also touches directly — a manual `git rebase` can leave a
# stuck-but-conflict-free rebase-merge directory that then makes every subsequent
# `git pull --rebase` in this script fail outright. Unattended runs can never resolve a
# REAL conflict (no human to ask), so the policy is narrow: if a rebase is mid-flight
# with nothing left to apply (clean, just not finalized), finish it onto the branch; if
# it has actual unmerged conflicts, abort it loudly — local work is never lost (the
# source Inbox/ file stays in place; the next run retries from a clean base).
# ---------------------------------------------------------------------------
git_clear_stuck_rebase() {  # git_clear_stuck_rebase <repo>
  local repo="$1" gitdir
  gitdir="$(git -C "$repo" rev-parse --absolute-git-dir 2>/dev/null)" || return 0
  [[ -d "$gitdir/rebase-merge" || -d "$gitdir/rebase-apply" ]] || return 0

  note "found a stuck rebase in $repo — attempting self-heal."
  if [[ -n "$(git -C "$repo" diff --name-only --diff-filter=U 2>/dev/null)" ]]; then
    note "stuck rebase has real conflicts — aborting it (unattended run can't resolve conflicts)."
    log_line "- ⚠️  $(now_stamp) · found a CONFLICTED rebase on entry — ran \`git rebase --abort\` (no human to resolve; nothing lost, will retry next run)"
    git -C "$repo" rebase --abort >/dev/null 2>&1 || true
  else
    local head_sha branch_ref
    head_sha="$(git -C "$repo" rev-parse HEAD 2>/dev/null)"
    branch_ref="$(cat "$gitdir/rebase-merge/head-name" 2>/dev/null || cat "$gitdir/rebase-apply/head-name" 2>/dev/null || echo "refs/heads/$GIT_BRANCH")"
    if [[ -n "$head_sha" ]]; then
      git -C "$repo" update-ref "$branch_ref" "$head_sha"
      rm -rf "$gitdir/rebase-merge" "$gitdir/rebase-apply"
      git -C "$repo" symbolic-ref HEAD "$branch_ref" >/dev/null 2>&1 || true
      note "stuck rebase had no conflicts — finalized onto ${branch_ref} at ${head_sha:0:7}."
      log_line "- ✅ $(now_stamp) · found a clean-but-unfinished rebase on entry — finalized it onto \`${branch_ref#refs/heads/}\` at \`${head_sha:0:7}\`"
    fi
  fi
}

git_pull_rebase_safe() {  # git_pull_rebase_safe <repo> -> 0 on clean pull, 1 otherwise (never leaves a stuck rebase behind)
  local repo="$1"
  git_clear_stuck_rebase "$repo"
  if ! git -C "$repo" pull --rebase --autostash origin "$GIT_BRANCH" >/dev/null 2>&1; then
    git_clear_stuck_rebase "$repo"   # clean up whatever this attempt left behind, so next run isn't wedged
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# The processing engine — a headless agent call. Transcript in via stdin, the routed
# prompt (or default instruction) via -p. Output is finished markdown only.
# ---------------------------------------------------------------------------
_engine_cmd() {  # _engine_cmd <instruction> <file> — run from a neutral cwd so the engine does a
  # clean text->text transform and does not pull the full repo identity context into
  # every small summarization.
  ( cd "${TMPDIR:-/tmp}" && cat "$2" | "$CLAUDE_BIN" -p "$1" --model "$ENGINE_MODEL" --output-format text )
}

run_engine() {  # run_engine <instruction_text> <transcript_file> -> stdout = result
  local instruction="$1" file="$2"
  if [[ "$ENGINE_STUB" == "1" ]]; then
    printf '**Summary (stub)**\n- %s\n\n**Raw**\n' "$(head -1 "$file")"
    sed 's/^/> /' "$file"
    return 0
  fi
  local tmpout; tmpout="$(mktemp "${TMPDIR:-/tmp}/daily-loop-engine.XXXXXX")"
  run_with_timeout "$tmpout" _engine_cmd "$instruction" "$file"
  local rc=$?
  cat "$tmpout"; rm -f "$tmpout"
  return $rc
}

# Build the instruction for a file given its prompt slug ("" = default handling).
build_instruction() {  # build_instruction <slug>
  local slug="$1" pfile=""
  if [[ -n "$slug" ]]; then pfile="$PROMPTS_DIR/$slug.md"; fi
  if [[ -n "$slug" && -f "$pfile" ]]; then
    cat <<EOF
You are processing a voice transcript captured on ${OWNER_NAME}'s phone. Apply the prompt below
to the transcript provided on stdin. Output ONLY the finished markdown deliverable — no preamble,
no "here is", no closing remarks. Do not invent facts that are not in the transcript.

=== PROMPT: $(pretty_name "$slug") ===
$(cat "$pfile")
EOF
  else
    # Default handling (no explicit #prompt tag): first decide whether this is obviously a
    # meeting/call transcript (multiple speakers, back-and-forth dialogue, "said"/turn-taking
    # patterns, a recap of who-attended-what) vs. a solo voice memo / brain-dump. Meeting
    # transcripts get the general Meeting Notes treatment instead of raw+TL;DR, so the live
    # daily note gets a real summary, not a transcript dump.
    cat <<EOF
You are processing a capture (voice memo, brain-dump, or meeting/call transcript) from
${OWNER_NAME}'s phone, provided on stdin.

STEP 1 — classify: is this OBVIOUSLY a meeting or call transcript (multiple speakers, dialogue/
turn-taking, "so-and-so said", a recap of a conversation between ${OWNER_NAME} and one or more
other people)? If you are not confident it's a meeting, treat it as a solo voice memo/brain-dump.

STEP 2 — output ONLY the finished markdown deliverable per the matched case below. No preamble,
no "here is", no closing remarks. Do not invent facts that are not in the transcript.

CASE A — it IS a meeting/call transcript, apply this prompt:
=== PROMPT: Meeting Notes (with Action Items) ===
$(cat "$PROMPTS_DIR/meeting-notes-with-action-items.md")

CASE B — it is NOT a meeting (solo memo/brain-dump), produce ONLY this markdown:

**TL;DR**
- 1-3 short bullets capturing the gist and any action items (call out ${OWNER_NAME}'s own action
  items).
EOF
  fi
}

# ---------------------------------------------------------------------------
# The SYNC engine — a second headless call, run from the REPO ROOT (so trackers/TASKS.md
# and the identity context are in scope) with Edit + memory-connector tool access.
# Match/close/update/add discipline, applied per-capture against TASKS.md.
# ---------------------------------------------------------------------------
build_sync_instruction() {  # build_sync_instruction <today_date>
  local today="$1"
  local daily_file="daily/$today.md"
  cat <<EOF
You are ${OWNER_NAME}'s chief-of-staff automation, running unattended (no human will review this
turn). A single new capture (voice memo, brain-dump, or meeting/call transcript) just landed and
has already been summarized into today's daily note. Your job now is to sync that capture against
\`trackers/TASKS.md\`, the persistent task list, today's \`$daily_file\` "$SKELETON_MARKER" section
ONLY (never any other part of the daily note), and the memory connector, the long-term memory
layer.

The capture's raw transcript was on stdin. Read it, then:

1. **Read** \`trackers/TASKS.md\` in full.
2. **Match** the capture against open (\`[ ]\`) items in TASKS.md:
   - **Closed by this capture** — the capture gave a definitive answer/status. Mark \`[x]\` and
     append \`*(Completed $today)*\` to the line.
   - **Updated by this capture** — status changed but isn't fully closed. Edit the line text in
     place and append \`*(updated $today)*\` or a short \`**$today status:** ...\` annotation. Keep
     the \`[ ]\` marker so it stays visible as open.
   - **Not addressed** — leave untouched. Do not invent progress that isn't in the capture.
2b. **Propagate closures to today's daily note, "$SKELETON_MARKER" section only.** If \`$daily_file\`
    exists and has that section: for any TASKS.md item you just marked \`[x]\` in step 2, check
    whether the SAME task also appears as a line in that section (it's a curated 3-6 item subset of
    TASKS.md, not a mirror — most closures won't match anything there, that's fine). If it matches,
    mark that line \`[x]\` and wrap the task text in \`~~strikethrough~~\` too, in place — do NOT move
    it to a different section, do NOT touch any other part of the daily note (Schedule, Insight,
    Notes Captured are off-limits), and do NOT add a task there that wasn't already listed.
3. **Add** any genuinely new task the capture introduces (a new commitment, a new action item)
   as a new line in the right section, matching the surrounding format (priority emoji if used,
   bold name, dash-separated detail, parenthetical opened date \`(opened $today)\`). If you're
   unsure which section, use the Waiting On / Someday section or the closest topical section —
   never invent a new top-level section without strong justification.
4. **Never delete** existing tasks, even closed ones — they stay as historical record.
5. **Capture to memory** ($(mem_tool "$MEMORY_CAPTURE_TOOL")) anything from the capture that:
   - Isn't already fully captured by the TASKS.md edit you just made (nuance, context, a strategic
     read, a reason behind a decision — task lines are terse, memory carries the "why").
   - Will matter to a future session that won't have today's context.
   - Search first ($(mem_tool "$MEMORY_SEARCH_TOOL")) if you suspect this is already captured, to
     avoid duplicate thoughts on the same topic.
   Do NOT capture ephemeral status with no future value, or content that's already fully redundant
   with the TASKS.md line.
6. If the capture is empty, off-topic, or genuinely has nothing to sync (no TASKS.md match, nothing
   memory-worthy), do nothing — don't force an edit or a capture.

Tone for any TASKS.md edits: terse, matching the surrounding file's voice exactly — you are editing
${OWNER_NAME}'s own working document, not writing prose about it.

When you are done, output ONLY a single short audit line (no markdown, no preamble) describing what
you did, e.g.:
  TASKS.md: closed "renew registration" (done per capture); memory: 1 new thought
or, if nothing to do:
  no action
EOF
}

_sync_cmd() {  # _sync_cmd <instruction> <file>
  local tools
  tools="$(join_tools "Edit" "Read" \
    "$(mem_tool "$MEMORY_CAPTURE_TOOL")" "$(mem_tool "$MEMORY_SEARCH_TOOL")")"
  ( cd "$REPO_ROOT" && cat "$2" | "$CLAUDE_BIN" -p "$1" \
      --output-format text \
      --permission-mode acceptEdits \
      --allowedTools "$tools" \
  )
}

run_sync_engine() {  # run_sync_engine <transcript_file> <today_date> -> stdout = one-line audit summary
  local file="$1" today="$2" instruction
  if [[ "$ENGINE_STUB" == "1" || "$SYNC_DISABLED" == "1" ]]; then
    printf 'sync skipped (stub/disabled)\n'
    return 0
  fi
  instruction="$(build_sync_instruction "$today")"
  local tmpout; tmpout="$(mktemp "${TMPDIR:-/tmp}/daily-loop-sync.XXXXXX")"
  run_with_timeout "$tmpout" _sync_cmd "$instruction" "$file"
  local rc=$?
  cat "$tmpout"; rm -f "$tmpout"
  return $rc
}

# ---------------------------------------------------------------------------
# The SKELETON engine — generates the fixed top-of-day structure for daily/<date>.md,
# once per day: Tasks for the Day / Schedule for the Day / Insight for the Day, with an
# empty Notes Captured section below where per-capture appends land for the rest of the
# day. Runs on every tick (idempotent, cheap no-op once the day's skeleton exists) so it
# covers every day regardless of any separate morning-briefing schedule.
# ---------------------------------------------------------------------------
SKELETON_MARKER="## ✅ Tasks for the Day"

build_skeleton_instruction() {  # build_skeleton_instruction <day>
  local day="$1"
  cat <<EOF
You are ${OWNER_NAME}'s chief-of-staff automation, running unattended. Generate the fixed
top-of-day SKELETON for the daily note for $day — the structure that sits above the running
capture log for the rest of the day. Output ONLY the finished markdown, no preamble, in EXACTLY
this shape (keep the heading text and emoji identical — other code matches on them):

# Daily — $day

$SKELETON_MARKER
- [ ] **<task>** — <short detail>
(3-6 items max, ranked by urgency. Read \`trackers/TASKS.md\`: leading 🔴/🚨 fires first, then
anything explicitly due/dated for $day, then the next highest-leverage open items. Fewer than 3
relevant items is fine — don't pad with filler.)

## 📅 Schedule for the Day
- <HH:MM> — <event title>
(Use $(cal_tool "$CALENDAR_LIST_TOOL") for $day, timezone $TZ_NAME, ordered by start time. If nothing
is scheduled, write the single line "No meetings today." — keep the section, don't omit it.)

## 💡 Insight for the Day
> <one thought from the memory connector, 1-3 sentences, framed as a short reflective insight
worth ${OWNER_NAME} seeing first thing — a pattern, a standing priority, an unresolved strategic
thread. Pull via $(mem_tool "$MEMORY_SEARCH_TOOL") / $(mem_tool "$MEMORY_LIST_TOOL"). Pick ONE thing,
don't summarize everything you find.>

## 📝 Notes Captured

Leave nothing after the "Notes Captured" heading — that section fills in throughout the day as
new captures land via the normal per-capture pipeline. Do not invent tasks, events, or insights
that aren't actually in the source data.
EOF
}

_skeleton_cmd() {  # _skeleton_cmd <instruction>
  local tools
  tools="$(join_tools "Read" \
    "$(mem_tool "$MEMORY_SEARCH_TOOL")" "$(mem_tool "$MEMORY_LIST_TOOL")" \
    "$(cal_tool "$CALENDAR_LIST_TOOL")")"
  ( cd "$REPO_ROOT" && "$CLAUDE_BIN" -p "$1" \
      --model "$ENGINE_MODEL" \
      --output-format text \
      --permission-mode acceptEdits \
      --allowedTools "$tools" \
  )
}

run_skeleton_engine() {  # run_skeleton_engine <day> -> stdout = full skeleton markdown
  local day="$1" instruction
  if [[ "$ENGINE_STUB" == "1" ]]; then
    printf '# Daily — %s\n\n%s\n- [ ] **(stub) no tasks**\n\n## 📅 Schedule for the Day\nNo meetings today.\n\n## 💡 Insight for the Day\n> (stub)\n\n## 📝 Notes Captured\n\n' "$day" "$SKELETON_MARKER"
    return 0
  fi
  instruction="$(build_skeleton_instruction "$day")"
  local tmpout; tmpout="$(mktemp "${TMPDIR:-/tmp}/daily-loop-skeleton.XXXXXX")"
  run_with_timeout "$tmpout" _skeleton_cmd "$instruction"
  local rc=$?
  cat "$tmpout"; rm -f "$tmpout"
  return $rc
}

# Idempotent: no-op (return 3) once today's file already has the skeleton — return 0 only when
# a skeleton was actually (freshly) generated this run, so the caller can tell "nothing to do"
# apart from "did real work" (and not falsely trigger a commit attempt every single tick). If a
# stray capture already created a bare file before this ran (e.g. a prior failed attempt), the
# existing body (everything after its own "# Daily — <date>" header line) is preserved and
# reattached under the new skeleton's "Notes Captured" section — nothing is ever dropped.
ensure_daily_skeleton() {  # ensure_daily_skeleton <day> -> 0 generated, 1 failed, 3 no-op (already existed)
  local day="$1"
  local daily_file="$DAILY_DIR/$day.md"
  [[ "$SKELETON_DISABLED" == "1" ]] && return 3
  if [[ -f "$daily_file" ]] && grep -qF "$SKELETON_MARKER" "$daily_file"; then
    return 3   # already generated today — no-op
  fi

  note "generating daily skeleton for $day"
  local skeleton
  if ! skeleton="$(run_skeleton_engine "$day")" || [[ -z "${skeleton// /}" ]]; then
    note "skeleton engine failed/empty for $day — leaving file as-is, will retry next run."
    log_line "- ❌ $(now_stamp) · skeleton generation failed/empty for \`$day\` — left for retry"
    return 1
  fi

  if [[ -f "$daily_file" ]]; then
    # Preserve whatever's already there (drop only its own leading "# Daily — <date>" header line,
    # since the new skeleton supplies its own) and reattach it under Notes Captured. Body-merge
    # runs via a helper file, not a stdin heredoc (see the ledger.py stdin note above).
    "$PYBIN" "$SCRIPT_DIR/strip_daily_header.py" "$daily_file"
    { printf '%s\n\n' "$skeleton"; cat "$daily_file.body.tmp"; } > "$daily_file.new.tmp"
    rm -f "$daily_file.body.tmp"
    mv "$daily_file.new.tmp" "$daily_file"
    note "merged existing stray content under Notes Captured for $day."
  else
    printf '%s\n\n' "$skeleton" > "$daily_file"
  fi
  log_line "- 🌅 $(now_stamp) · generated daily skeleton for \`$day\`"
}

# ---------------------------------------------------------------------------
# Static daily nudge (optional). Pattern worth copying: replace "a full agent session
# that boots every morning purely to emit one fixed reminder checkbox" with pure bash —
# same output, zero tokens. Set DAILY_LOOP_STATIC_NUDGE_TEXT (and optionally
# DAILY_LOOP_STATIC_NUDGE_HEADING) to enable; empty = disabled.
# ---------------------------------------------------------------------------
STATIC_NUDGE_TEXT="${DAILY_LOOP_STATIC_NUDGE_TEXT:-}"
STATIC_NUDGE_HEADING="${DAILY_LOOP_STATIC_NUDGE_HEADING:-## 🔁 Daily Nudge}"

ensure_static_nudge() {  # ensure_static_nudge <day> -> appends the nudge once/day; no-op if present
  local day="$1"
  local daily_file="$DAILY_DIR/$day.md"
  [[ -n "$STATIC_NUDGE_TEXT" ]] || return 0
  [[ -f "$daily_file" ]] || return 0
  if grep -qF "$STATIC_NUDGE_TEXT" "$daily_file" 2>/dev/null; then
    return 0   # already added today — no-op
  fi
  {
    printf '%s\n' "$STATIC_NUDGE_HEADING"
    printf -- '- [ ] %s\n\n' "$STATIC_NUDGE_TEXT"
  } >> "$daily_file"
  log_line "- 🔁 $(now_stamp) · added static daily nudge to \`$day\`"
}

# ---------------------------------------------------------------------------
# HEALTH CHECK — one line every tick to daily-loop/host-health.log (a local trend line):
# agent-process count, available-memory %, swap, disk-used %. On genuine pressure, drop a
# "nudge" Inbox capture so it surfaces on the daily page — rate-limited to once per
# calendar day via a marker file so a sustained problem doesn't spam the Inbox.
# macOS-specific tools (vm_stat/sysctl); on Linux, adapt or disable via a no-op override.
# ---------------------------------------------------------------------------
run_health_check() {
  local proc_count avail_pages total_pages avail_pct swap_used_mb disk_pct
  # pgrep exits 1 when nothing matches; under `set -o pipefail` + `set -e` that non-zero
  # would abort the whole processor before any capture work. `|| true` keeps the count
  # correct (0) while neutralizing the no-match exit code.
  proc_count="$(pgrep -f 'claude' 2>/dev/null | wc -l | tr -d ' ' || true)"

  # Memory pressure signal. Raw "Pages free" is misleading on macOS (free pages exclude
  # reclaimable memory), reading ~1% on a healthy machine and firing false alerts. Track
  # *available* = free + inactive + speculative + purgeable, and add swap-used as the
  # true under-pressure signal (the kernel swaps only when genuinely tight).
  # NOTE: the leading-command failures below (vm_stat/sysctl absent on Linux) must not
  # kill the script under `set -e -o pipefail` — hence the `|| true` on each pipeline.
  # On non-macOS hosts these read as 0/absent and the alert thresholds simply never trip.
  avail_pages="$(vm_stat 2>/dev/null | awk '
    /^Pages free/        {gsub("\\.","",$3); f=$3}
    /^Pages inactive/    {gsub("\\.","",$3); i=$3}
    /^Pages speculative/ {gsub("\\.","",$3); s=$3}
    /^Pages purgeable/   {gsub("\\.","",$3); p=$3}
    END{print f+i+s+p}' || true)"
  total_pages=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 16384 ))
  avail_pct=100
  [[ -n "$avail_pages" && "$total_pages" -gt 0 ]] && avail_pct=$(( avail_pages * 100 / total_pages ))
  # vm.swapusage: "total = 1024.00M  used = 83.31M  free = 940.69M" → used value is $6.
  swap_used_mb="$(sysctl -n vm.swapusage 2>/dev/null | awk '{v=$6; u=v; gsub(/[0-9.]/,"",u); gsub(/[A-Za-z]/,"",v); if(u=="G")v=v*1024; printf "%d", v+0}' || true)"
  swap_used_mb="${swap_used_mb:-0}"
  disk_pct="$(df -h / 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}' || true)"

  printf '%s agent_procs=%s mem_avail_pct=%s%% swap_used_mb=%s disk_used_pct=%s%%\n' \
    "$(now_stamp)" "${proc_count:-0}" "${avail_pct:-100}" "${swap_used_mb:-0}" "${disk_pct:-0}" >> "$HEALTH_LOG"

  # Alert only on genuine pressure: too many agent procs, <10% *available* memory, or
  # >3 GB of swap in use (sustained thrashing that precedes a wedge).
  if [[ "${proc_count:-0}" -gt 5 || "${avail_pct:-100}" -lt 10 || "${swap_used_mb:-0}" -gt 3072 ]]; then
    local marker="$REPO_ROOT/daily-loop/.health-alert-sent-$(date +%Y-%m-%d)"
    if [[ ! -f "$marker" ]]; then
      note "health check elevated (agent_procs=$proc_count, mem_avail_pct=$avail_pct%, swap_used_mb=$swap_used_mb) — dropping alert capture."
      printf '#prompt: nudge\n⚠️ Always-on host under real memory pressure — check before it wedges (agent_procs=%s, mem_avail=%s%%, swap_used=%sMB, disk=%s%%)\n' \
        "$proc_count" "$avail_pct" "$swap_used_mb" "$disk_pct" > "$INBOX_DIR/$(date +%Y-%m-%d-%H%M)-host-health-alert.md"
      touch "$marker"
      log_line "- ⚠️ $(now_stamp) · health alert: agent_procs=$proc_count mem_avail_pct=${avail_pct}% swap_used_mb=${swap_used_mb} disk_used_pct=${disk_pct}% — Inbox nudge dropped"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
if [[ -n "$ALLOWED_HOST" && "$(hostname -s)" != "$ALLOWED_HOST" ]]; then
  note "host $(hostname -s) != DAILY_LOOP_ALLOWED_HOST=$ALLOWED_HOST — refusing to run (single-host guard)."
  exit 0
fi

mkdir -p "$DAILY_DIR" "$PROCESSED_DIR" "$(dirname "$LEDGER")"
[[ -f "$LEDGER" ]] || printf '{\n  "processed": []\n}\n' > "$LEDGER"
[[ -f "$LOG" ]] || printf '# Daily Loop — processor run log\n\n' > "$LOG"
[[ -d "$INBOX_DIR" ]] || { note "inbox not found: $INBOX_DIR"; exit 0; }

# Single-instance lock (mkdir is atomic; flock is absent on stock macOS). Self-heal a lock
# left behind by a run that died mid-flight (crash, kill -9, disk full) — otherwise every
# future run blocks forever on a lock nobody will ever release.
if [[ -d "$LOCK_DIR" ]]; then
  lock_age=$(( $(date +%s) - $(stat -f %m "$LOCK_DIR" 2>/dev/null || stat -c %Y "$LOCK_DIR" 2>/dev/null || echo 0) ))
  if [[ "$lock_age" -gt "$LOCK_STALE_SECS" ]]; then
    note "lock is ${lock_age}s old (> ${LOCK_STALE_SECS}s) — assuming stale, clearing it."
    log_line "- ⚠️  $(now_stamp) · cleared a stale lock (${lock_age}s old) left by a prior run that never released it"
    rmdir "$LOCK_DIR" 2>/dev/null || true
  fi
fi
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  note "another run holds the lock ($LOCK_DIR) — exiting."
  exit 0
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

# Health check runs every tick regardless of whether there's capture work to do.
# Disable-able because it can DROP A CAPTURE into the Inbox (the self-alert), which a test
# harness must be able to switch off to keep a sandbox deterministic.
[[ "$HEALTH_DISABLED" == "1" ]] || run_health_check

# Pull before processing so the push at the end fast-forwards cleanly.
if [[ "$DRY_RUN" != "1" ]]; then
  git_pull_rebase_safe "$REPO_ROOT" \
    || note "git pull --rebase failed (continuing; will retry at push)."
fi

# Ensure today's daily note has its Tasks/Schedule/Insight skeleton before any captures land.
# Idempotent — cheap no-op on every run after the first one each day.
processed_count=0
changed_dailies=()
today_date="$(date +%Y-%m-%d)"
if ensure_daily_skeleton "$today_date"; then
  changed_dailies+=("$today_date.md")
  processed_count=$((processed_count + 1))
fi

# Optional static daily nudge (no agent call) — must run AFTER the skeleton so the daily
# file exists. Idempotent; if it appends, make sure the day is committed/pushed this run.
if [[ -n "$STATIC_NUDGE_TEXT" && -f "$DAILY_DIR/$today_date.md" ]] && ! grep -qF "$STATIC_NUDGE_TEXT" "$DAILY_DIR/$today_date.md" 2>/dev/null; then
  ensure_static_nudge "$today_date"
  changed_dailies+=("$today_date.md")
  processed_count=$((processed_count + 1))
fi

# ---------------------------------------------------------------------------
# Process new inbox files (top level only — never recurse into processed/)
# ---------------------------------------------------------------------------

shopt -s nullglob
files=()
for f in "$INBOX_DIR"/*.md "$INBOX_DIR"/*.txt; do
  [[ -f "$f" ]] && files+=("$f")
done
# Stable chronological order by filename (capture tools should name files YYYY-MM-DD-HHMM).
IFS=$'\n' files=($(printf '%s\n' "${files[@]}" | sort)) || true
unset IFS

for file in "${files[@]}"; do
  base="$(basename "$file")"
  # Skip READMEs and our own dotfiles.
  [[ "$base" == "README.md" || "$base" == .* ]] && continue
  if ledger_has "$base"; then
    note "already in ledger, skipping: $base"
    continue
  fi

  # Route: first line `#prompt: <slug>`
  first_line="$(head -1 "$file" 2>/dev/null || true)"
  slug=""
  if [[ "$first_line" =~ ^#prompt:[[:space:]]*([A-Za-z0-9._-]+) ]]; then
    slug="$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')"
    if [[ ! -f "$PROMPTS_DIR/$slug.md" ]]; then
      note "prompt '$slug' not found in $PROMPTS_DIR — falling back to default handling."
      log_line "- ⚠️  $(now_stamp) · \`$base\` requested unknown prompt \`$slug\` → default handling"
      slug=""
    fi
  fi

  instruction="$(build_instruction "$slug")"
  note "processing $base (prompt: ${slug:-default})"

  # Run the engine. On failure/empty output, LEAVE the file for the next run (never lose capture).
  if ! result="$(run_engine "$instruction" "$file")" || [[ -z "${result// /}" ]]; then
    note "engine failed/empty for $base — leaving in place for retry."
    log_line "- ❌ $(now_stamp) · \`$base\` engine failed/empty — left for retry"
    continue
  fi

  # Target daily file: derive the date from the filename (YYYY-MM-DD-*) else today.
  if [[ "$base" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}) ]]; then
    day="${BASH_REMATCH[1]}"
  else
    day="$(date +%Y-%m-%d)"
  fi
  daily_file="$DAILY_DIR/$day.md"
  heading_time="$(date +%H:%M)"
  heading_label="${slug:+$(pretty_name "$slug")}"; heading_label="${heading_label:-Daily capture}"

  if [[ ! -f "$daily_file" ]]; then
    printf '# Daily — %s\n\n' "$day" > "$daily_file"
  fi
  {
    printf '## %s — %s\n' "$heading_time" "$heading_label"
    printf '*source: `Inbox/%s`*\n\n' "$base"
    printf '%s\n\n' "$result"
    printf -- '---\n\n'
  } >> "$daily_file"

  # Sync step: match this capture against TASKS.md + memory. Skip for the nudge passthrough
  # (pre-written reminder text, nothing to sync). Never let a sync failure lose the capture or
  # block the daily-note publish — log and move on.
  sync_summary="(skipped: nudge)"
  if [[ "$slug" != "nudge" ]]; then
    if sync_summary="$(run_sync_engine "$file" "$day" 2>>"$LOG")"; then
      sync_summary="${sync_summary:-no output}"
    else
      sync_summary="sync engine failed (TASKS.md/memory may be unchanged — see log)"
    fi
  fi

  # Move source to processed/ (hard dedup guard) + record in ledger.
  mv "$file" "$PROCESSED_DIR/$base"
  ledger_add "$base" "${slug:-default}" "daily/$day.md"

  log_line "- ✅ $(now_stamp) · \`$base\` → \`daily/$day.md\` (prompt: ${slug:-default})"
  log_line "  · sync: $sync_summary"
  changed_dailies+=("$day.md")
  processed_count=$((processed_count + 1))
done

# ---------------------------------------------------------------------------
# Commit + push (path-scoped lane: daily/ + TASKS.md + the ledger + the log)
# ---------------------------------------------------------------------------
if [[ "$processed_count" -eq 0 ]]; then
  note "nothing new to process."
  exit 0
fi

if [[ "$DRY_RUN" == "1" ]]; then
  note "DRY RUN: processed $processed_count file(s); skipping git commit/push."
  exit 0
fi

# Guard against committing mid-rebase (e.g. a concurrent manual session left one stuck) —
# never want a commit landing in detached HEAD instead of on the branch.
git_clear_stuck_rebase "$REPO_ROOT"

git -C "$REPO_ROOT" add -- daily "$TASKS_FILE" "$LEDGER" "$LOG" >/dev/null 2>&1 || true
if git -C "$REPO_ROOT" diff --cached --quiet; then
  note "no staged changes to commit."
  exit 0
fi

uniq_days="$(printf '%s\n' "${changed_dailies[@]}" | sort -u | tr '\n' ' ')"
commit_msg="daily-loop: process $processed_count capture(s) → ${uniq_days% } (+ tasks/memory sync)"
git -C "$REPO_ROOT" commit -m "$commit_msg" >/dev/null 2>&1 || { note "commit failed."; exit 1; }

# Rebase once more in case another machine pushed concurrently, then push.
git_pull_rebase_safe "$REPO_ROOT" || true
if git -C "$REPO_ROOT" push origin "$GIT_BRANCH" >/dev/null 2>&1; then
  note "pushed: $commit_msg"
  log_line "- ⬆️  $(now_stamp) · pushed \`$commit_msg\`"
else
  note "PUSH FAILED — commit is local; next run will retry."
  log_line "- ⚠️  $(now_stamp) · push failed for \`$commit_msg\` (local commit, will retry)"
fi
