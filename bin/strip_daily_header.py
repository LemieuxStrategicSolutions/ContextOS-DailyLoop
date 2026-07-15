#!/usr/bin/env python3
"""Helper for daily-inbox-processor's skeleton merge.

Writes <file>.body.tmp containing the file's content minus its own leading
"# Daily — <date>" header line (the fresh skeleton supplies its own header).

Args only, never stdin — the `python3 - <<HEREDOC` program-on-stdin pattern
hangs under some schedulers.
"""
import sys

path = sys.argv[1]
with open(path) as f:
    lines = f.readlines()
if lines and lines[0].startswith("# Daily —"):
    lines = lines[1:]
body = "".join(lines).lstrip("\n")
with open(path + ".body.tmp", "w") as f:
    f.write(body)
