# Leak test (v1.2)

`tsem leaktest` (and the **Leak test** card in the GL.iNet page, API method `leaktest`) checks what the router itself can see about its own
traffic and rules. It changes nothing and takes up to about 20 seconds.

```sh
tsem leaktest          # PASS / WARN / FAIL / INFO per check, exit status 0 = no FAIL
tsem leaktest --json
```

| Mode | Checks |
|---|---|
| EXIT | the kill switch is closed and consistent with the mode; IPv6 is guarded; the router's own DNS is redirected; **the public address seen outside is not your own uplink address**; no IPv6 connection leaves the router |
| BLOCKED | the kill switch is closed and consistent; the router really cannot reach the Internet |
| DIRECT | shows your own public address and keeps it as the baseline for later comparisons |

**The baseline.** To tell an exit address from your own, TSEM remembers the public address it saw while the router was in DIRECT
(`/etc/tsem/egress_direct`). If you never ran the test in DIRECT, the result says so (INFO) and shows the address for you to check.

**What it cannot see.** A device behind the router decides what it uses. The rules this test checks cover those devices, but only the
device itself shows what it sees: open any "what is my IP" page on it. The address check asks `myip.wtf` (the same service as the address
card) and needs an Internet path, so in EXIT it measures the exit node's path. The texts of the single checks are English.
