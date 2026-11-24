# Contributing

Thank you for helping. Small, focused changes are easiest to review.

## Before you open a pull request

* Run the tests: `sh tests/run.sh` (and `SH=bash sh tests/run.sh`). The packet tests need Linux with iptables and network
  namespaces; without them they are listed as NOT RUN, never as passed.
* Shell code must stay POSIX `sh` (BusyBox ash is the target) and pass `shellcheck` as in `.github/workflows/test.yml`.
* A change to behaviour needs a test. A bug fix needs a test that fails without it.
* Do not weaken the fail-closed behaviour: a protected mode must never silently fall back to the open internet.
* No secrets, no real addresses of your own network, no personal data in code, tests, logs or docs.

## Sign your work (Developer Certificate of Origin)

By contributing you confirm that you wrote the change or have the right to submit it under the Apache License 2.0
(https://developercertificate.org). Add this line to every commit message:

    Signed-off-by: Your Name <you@example.com>

(`git commit -s` does it for you.) Contributions are licensed under the Apache License 2.0, the same as the project; the copyright
of your contribution stays with you.
