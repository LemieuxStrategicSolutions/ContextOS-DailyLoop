# Contributing

Contributions must preserve the guarantee this loop exists to make: **a capture is never
lost**. An engine failure, timeout, or empty output leaves the source file in place for the
next tick. If a change can drop a capture on any path, it isn't ready.

## Development

```sh
bash tests/run-tests.sh
```

No framework, no network, no agent, no git. Each test drives the real processor in a
throwaway sandbox via `DAILY_LOOP_DRY_RUN` plus either the built-in engine stub or a fake
agent binary.

## Pull requests

- Any change to dedup, the lock, the timeout, git handling, or the engine call needs a test —
  the negative case especially. "It worked when I ran it once" is not coverage for something
  that runs unattended every 15 minutes.
- Keep helpers args-only. Never `python3 - <<HEREDOC`: reading a script from stdin hangs
  under some schedulers, silently.
- Never `git add -A`. Commits stay path-scoped so a human's work-in-progress is never swept
  into a robot commit.
- Keep examples synthetic. Never include a real capture, contact, employer, client,
  credential, private URL, or machine-specific path.
