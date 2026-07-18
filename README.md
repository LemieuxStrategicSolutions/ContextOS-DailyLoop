# ContextOS-DailyLoop

[![CI](https://github.com/LemieuxStrategicSolutions/ContextOS-DailyLoop/actions/workflows/ci.yml/badge.svg)](https://github.com/LemieuxStrategicSolutions/ContextOS-DailyLoop/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

**Say something into your phone. Fifteen minutes later it's a summarized entry in today's note, your task list is reconciled against it, and the context is banked in memory — without you filing anything.**

ContextOS-DailyLoop is the capture layer of the ContextOS ecosystem: an unattended processor that turns raw captures into a daily note, syncs what they change, and publishes the day to your phone. Use it with ContextOS, or point it at any git repo and any synced folder.

```text
phone capture (Shortcut / anything that writes a text file)
   → <SYNC_ROOT>/Inbox/2030-01-05-0930-memo.md
   → [always-on machine] daily-inbox-processor.sh, every ~15 min:
        dedup → route by "#prompt:" → summarize (headless agent call)
        → append to <repo>/daily/YYYY-MM-DD.md
        → sync: reconcile trackers/TASKS.md + bank context to your memory connector
        → git commit (path-scoped) + push
   → (optional) a Cloudflare Worker renders today's note as a private mobile page
```

## Why this is harder than it looks

An unattended loop on a 15-minute schedule fails in ways an interactive script never does, and every rule below cost real debugging time:

- **A capture is never lost.** An engine failure, a timeout, or empty output leaves the source file exactly where it was, unledgered, for the next tick. Only success moves it to `Inbox/processed/` — which doubles as your raw archive.
- **Dedup is two-layer.** The physical move is the hard guard; the JSON ledger is the audit trail. Either alone eventually double-posts.
- **Locks self-heal.** A single-instance lock via atomic `mkdir` (stock macOS has no `flock`), with stale-lock recovery — otherwise one crashed run wedges the loop forever.
- **Every agent call has a bash-native timeout.** macOS ships no GNU `timeout`, and an unattended call that hangs forever is how a scheduled loop eats a machine.
- **Stuck rebases get repaired.** This loop shares a working tree with humans. A clean-but-unfinished rebase is finalized; a conflicted one is aborted loudly — an unattended run must never guess at a merge.
- **Commits are path-scoped.** Never `git add -A`, so a human's work-in-progress is never swept into a robot commit.
- **The filename's date decides the day**, not the clock — so a capture that syncs late still lands where it belongs.

## Install

```sh
bin/install.sh --repo ~/your-context-repo \
               --sync-root ~/your/synced-folder \
               --owner Sam --tz America/New_York \
               --memory-mcp mcp__claude_ai_Memory \
               --calendar-mcp mcp__claude_ai_Google_Calendar
```

Idempotent, non-interactive, never clobbers a config or prompt you've tuned, and **schedules nothing**. It preflights by running the test suite *and* a stubbed dry run against your real paths, and refuses to claim success if either fails. Try `--dry-run` first — it describes without doing. `--help` lists every flag.

### Requirements

- An **always-on machine**: bash, git with push credentials, python3 (stdlib only), and a headless-capable agent CLI (default `claude`; any CLI that does stdin→text with a tool allow-list works via `DAILY_LOOP_CLAUDE`).
- A **git repo** with `daily/` and a task file, and a **synced folder** your phone can write into.
- **Optional:** memory and calendar connectors. Both degrade gracefully — the loop runs without them.

> **No always-on machine?** The processor is the same either way — the "always-on machine,
> every ~15 min" line is a *deployment choice*, not a hard dependency. Where the loop must
> survive every machine sleeping, run it **event-driven** instead: a small Worker writes
> the capture into the repo, and the push triggers the processor on a hosted CI runner in
> seconds. That variant isn't shipped here (it's a hosting pattern, not code), but see
> ContextOS `ARCHITECTURE.md` → *When you outgrow the always-on machine* for the shape.

## Configuration

One file, `daily-loop/daily-loop.conf` (annotated reference: [`daily-loop.conf.example`](daily-loop.conf.example)). Precedence is **environment > config file > built-in default**, so a one-off run overrides anything without editing the file.

## Adapters

The loop talks to three things you might do differently: a **task list** (a Markdown file it edits), a **memory connector**, and a **calendar connector**. Connectors are addressed by name *and by verb*:

```sh
: "${DAILY_LOOP_MEMORY_MCP:=mcp__mem0}"
: "${DAILY_LOOP_MEMORY_CAPTURE_TOOL:=add_memory}"     # yours may not say "capture_thought"
: "${DAILY_LOOP_MEMORY_SEARCH_TOOL:=search_memory}"
```

Naming the connector while hardcoding its vocabulary is what makes a loop portable in theory and broken in practice. Set a connector to `""` and its tools drop out of the allow-list entirely, rather than being passed as dangling names that match nothing.

> **The single most common silent failure:** a headless call names connectors by *display name* (`mcp__claude_ai_<Name>`), not the `mcp__<uuid>` form a desktop session shows. The uuid form matches nothing and every unattended call is quietly permission-blocked. Verify with a real dry run before you schedule anything.

## Tests

```sh
bash tests/run-tests.sh    # 49 assertions, no framework, agent, network, or git
```

Each test drives the **real processor** in a throwaway sandbox using `DRY_RUN` plus either the built-in engine stub or a fake agent binary — the plumbing under test is the real thing, not a mock of it. Covered: a capture is never lost (engine failure *and* empty output), idempotency (a re-dropped capture doesn't double-post; an empty tick leaves the note byte-identical), recovery (a stranded capture processes next tick; a stale lock self-heals and says so), the guards (live lock, host guard, housekeeping files), routing and fallback, config precedence, and installer idempotency.

## Scheduling

Register the job in your automation registry **in the same action** — no silent automations — then schedule the processor every ~15 minutes as your AI agent's own scheduled task.

On macOS, do **not** use launchd if any path is cloud-synced. macOS grants Full Disk Access per binary: a launchd job's children (`git`, `python3`, the agent CLI) don't inherit it, and when they touch a synced path they don't error — they **hang forever**, piling up until the machine dies.

Optional second machine: schedule `bin/daily-inbox-fallback.sh` hourly on a laptop; it only acts when the primary has clearly missed ≥2 cycles.

## Files

| Path | Role |
|---|---|
| `bin/install.sh` | The installer. Idempotent, preflights, schedules nothing. |
| `bin/daily-inbox-processor.sh` | The processor. Heavily commented — read it before scheduling it. |
| `bin/daily-inbox-fallback.sh` | Second-machine fallback runner. |
| `bin/ledger.py` · `bin/strip_daily_header.py` | Args-only helpers (never stdin heredocs — some schedulers hang on those). |
| `daily-loop.conf.example` | Every setting, annotated. |
| `prompts/` | The `#prompt:` routing convention + three starter prompts. |
| `examples/inbox/` | Sample captures covering all three routing paths. |
| `tests/run-tests.sh` | The suite. |
| `worker/` | Optional Cloudflare Worker: today's note as a private mobile page. |

## ContextOS ecosystem

[ContextOS](https://github.com/LemieuxStrategicSolutions/ContextOS) provides the portable context foundation this loop writes into. It composes with [ContextOS-ContextCheck](https://github.com/LemieuxStrategicSolutions/ContextOS-ContextCheck) (audit the notes and trackers this produces for drift) and [ContextOS-Decisions](https://github.com/LemieuxStrategicSolutions/ContextOS-Decisions). None of them require each other.

## Privacy

Your captures and notes stay in your own repo and synced folder. The processor reads the paths you give it; the bundled `examples/` are synthetic. The optional Worker is key-gated and reads your repo through a read-only, single-repo token stored as a Worker secret — never a file.

## License

MIT — see [`LICENSE`](LICENSE).
