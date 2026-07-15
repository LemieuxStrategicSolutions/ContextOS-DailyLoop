# Prompts — the `#prompt:` routing convention

A capture whose **first line** is `#prompt: <slug>` is processed with the matching
`Prompts/<slug>.md` prompt instead of default handling. Slugs are lowercased;
an unknown slug falls back to default handling (and logs a warning).

Deploy: copy this folder's `*.md` files to `<SYNC_ROOT>/Prompts/` (the processor reads
them from there, outside the repo, next to `Inbox/`). Add your own prompts as plain
markdown files — the filename (minus `.md`) is the slug.

Ships with three:

| Slug | Behavior |
|---|---|
| `nudge` | Passthrough: the capture body is already the finished text (a pre-written checkbox/reminder). The sync step is skipped — nothing to reason about. Used by the system itself for health alerts and fallback notices. |
| `verbatim` | The capture is finished content — clean it up minimally (typos, spacing) and place it as-is. |
| `meeting-notes-with-action-items` | Full meeting-notes treatment. Also applied automatically when default handling classifies a capture as an obvious meeting/call transcript. |

Default handling (no `#prompt:` line): classify meeting-transcript vs solo memo →
meeting notes or a 1–3 bullet TL;DR. Raw transcripts never land in the daily note; the
source file keeps the full text in `Inbox/processed/`.
