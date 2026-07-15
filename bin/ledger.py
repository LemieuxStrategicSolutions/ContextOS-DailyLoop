#!/usr/bin/env python3
"""Dedup/audit ledger for the Daily Loop processor.

Standalone (args only, never reads stdin) so it runs reliably under any scheduler —
the `python3 - <<HEREDOC` program-on-stdin pattern hangs in some of them.

  ledger.py has <ledger.json> <source-basename>            -> exit 0 if present, 1 if not
  ledger.py add <ledger.json> <source> <prompt> <daily> <iso-ts>
"""
import json, os, sys


def load(path):
    try:
        data = json.load(open(path))
        return data if isinstance(data, dict) else {"processed": data}
    except Exception:
        return {"processed": []}


def main():
    if len(sys.argv) < 3:
        sys.exit(2)
    cmd, ledger = sys.argv[1], sys.argv[2]

    if cmd == "has":
        name = sys.argv[3]
        items = load(ledger).get("processed", [])
        sys.exit(0 if any(r.get("source") == name for r in items) else 1)

    if cmd == "add":
        name, prompt, daily, ts = sys.argv[3:7]
        data = load(ledger)
        data.setdefault("processed", []).append(
            {"source": name, "prompt": prompt, "daily": daily, "processed_at": ts}
        )
        tmp = ledger + ".tmp"
        json.dump(data, open(tmp, "w"), indent=2)
        os.replace(tmp, ledger)
        sys.exit(0)

    sys.exit(2)


if __name__ == "__main__":
    main()
