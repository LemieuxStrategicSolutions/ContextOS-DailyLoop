# Sample captures

Drop these into your `Inbox/` to exercise the loop end to end without waiting for a real
capture. They cover the three routing paths:

| File | Path exercised |
|---|---|
| `2030-01-05-0900-voice-memo.md` | Default handling — the engine classifies it as a solo memo and writes a TL;DR. |
| `2030-01-05-1430-standup.md` | Explicit `#prompt:` routing to the meeting-notes prompt. |
| `2030-01-05-1800-nudge.md` | The `nudge` passthrough — pre-written text, sync step skipped. |

Try them without touching git or spending a token:

```sh
cp modules/daily-loop/examples/inbox/*.md "$SYNC_ROOT/Inbox/"
DAILY_LOOP_DRY_RUN=1 DAILY_LOOP_ENGINE_STUB=1 bash daily-loop/bin/daily-inbox-processor.sh
```

Then read `daily/2030-01-05.md`. Note the date: the day a capture lands on comes from its
**filename**, not the clock, so these always land on 2030-01-05.
