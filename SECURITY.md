# Security and privacy

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting. Do not open a public issue containing
secrets, real captures, personal data, or a working exploit.

## Data boundary

The processor is local-first: it reads the paths you give it and pushes only to your own
git remote. Nothing is uploaded anywhere else.

Secrets never live in files. The optional Worker authenticates with a shared key over HTTPS
and reads your repo via a read-only, single-repo fine-grained token stored as a Worker
secret.

An unattended agent call runs with an explicit tool allow-list. Keep it that way: an
unattended loop should be physically unable to publish, send, or spend.
