# IPv4 + IPv6 packet tests on the isolated VM `ht-dev`

The container runner (Alpine, no CAP_NET_ADMIN/CAP_SYS_ADMIN) cannot create network namespaces, so CI runs only `static` and `unit`.
Tests that need a real kernel netfilter are listed there as **NOT RUN** (never as passed). The packet tests run for real on `ht-dev`
with `tools/run-netns-vm.sh`. The gate for "packet path proven" is the Gitea commit status **`netns-vm/ht-dev`** on the tested commit.

## What the script proves before it runs anything (PREFLIGHT, no bypass)
root · CAP_NET_ADMIN + CAP_SYS_ADMIN · python3 >= 3.12 with `os.unshare`/`os.setns` · iptables, ip6tables, iptables-restore,
ip6tables-restore, dash, bash · `/proc/net/if_inet6` and `disable_ipv6=0` · and a live check in a throw-away namespace that
`iptables` and `ip6tables` can create chains and IPv6 forwarding can be enabled. Any failure ⇒ verdict **NOT-RUN**, exit 2.

## Verdict
* **PASSED** (exit 0): IPv4 suite (44 scenarios), IPv6 suite (6 scenarios) and the `iptables-restore` syntax test ran, 0 failed, nothing skipped,
  and the passed count equals the scenario count read from the source. Commit attributable (clean checkout, or `--sha` given for an unpacked archive).
* **FAILED** (exit 1): something ran and failed, or fewer scenarios passed than exist.
* **NOT-RUN** (exit 2): preflight failed, a suite skipped (rc 77 or a SKIPPED line) or printed no summary, or the checkout is dirty / is not `--sha`. **Not a pass.**

## Flow (on ht-dev, as root; nothing outside temporary namespaces and the output directory is changed)
1. Get the exact commit (either way; no token is stored in the repo):
   * `git clone -b main https://github.com/mompl/glinet-tailscale-exit-manager.git && cd glinet-tailscale-exit-manager && git checkout <SHA>`
   * or from the Mac: `git archive --format=tar.gz -o tsem.tgz <SHA>`, `scp` it to ht-dev, unpack; then pass `--sha <SHA>`.
2. Run (token only for the hand-over, from a file with mode 600 that holds a Gitea token allowed to write commit statuses):
   `sudo sh tools/run-netns-vm.sh --post --token-file ~/.tsem-gitea-token`
3. Read the last lines: `VERDICT: …` and the path of `result.md`/`run.log` (default `/tmp/tsem-netns-vm-<time>/`).
4. Gitea now shows `netns-vm/ht-dev` on that commit: `success` only for PASSED, `failure` for FAILED, `error` for NOT-RUN.
   Without a token the script says "not posted"; paste `result.md` into PR #7 by hand, with the verdict as printed.

## Notes
* The router runs iptables-legacy. The script prints the VM's backend (`legacy` or `nf_tables`); if it is nf_tables, say so in the report.
* The IPv6 suite (`tests/netns/netns6_test.py`) has not been executed by its author yet: the first ht-dev run is its first real execution.
  If it fails, that is a finding about the test or the product, to be fixed, not hidden.
* `tests/t_netns_vm.sh` tests the verdict logic itself with fake suites (`TSEM_VM_SELFTEST=1`, marked and never posted).
