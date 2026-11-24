# Security policy

TSEM changes firewall and routing rules of a router, so security reports are taken seriously.

## Supported versions

Only the latest 1.0.x release receives fixes.

## Reporting a vulnerability

Please do **not** open a public issue for a security problem. Use GitHub's private reporting instead:
**Security tab > "Report a vulnerability"** on this repository. Describe what you saw, the router model and firmware, the TSEM
version (`tsem status`), and steps to reproduce. Never include passwords, keys or tokens.

This is a hobby project maintained by one person in their spare time: there is no service level and no guaranteed response time,
but reports are read and answered as soon as possible.

## What counts

A leak of traffic while the router is in EXIT or BLOCKED mode, a way to open the guard without authorisation, command injection
through the web interface or the API, and unsafe file handling in the installer are all in scope.

## No warranty

TSEM is provided "as is" without warranty (Apache License 2.0). Test it on your own router and keep local access to it.
