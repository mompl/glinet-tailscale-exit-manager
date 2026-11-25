#!/usr/bin/env python3
"""IPv6 packet-path tests for the tsem kill switch, in Linux network namespaces (real ip6tables).

Same topology as netns_test.py with an IPv6 plane added (documentation prefixes):

   client C fd82::50 --br-lan fd82::1-- ROUTER R --apclix0 2001:db8:1::2-- W (2001:db8:1::1, answers "WAN")
                                           |
                                      tailscale0 fd7a:115c:a1e0::2 -- X (fd7a:115c:a1e0::1, answers "TUN")

W and X both own 2001:db8:ffff::9, so the answer tells which path an IPv6 packet really took.
The claim under test (docs/rc/dns-ipv6.md): in GERMAN and BLOCKED a LAN client's IPv6 traffic to the Internet
never leaves through the WAN, also not after a firewall flush (second layer) and not while both exit nodes are down.

STRICT BY DESIGN: a kernel without IPv6, a missing ip6tables or missing namespace capability is a FAIL (exit 1),
never a skip. STATUS: written without an IPv6-capable kernel (the authoring sandbox has none), so this file has
NEVER been executed by its author. The first real run is the CI/IPv6 runner; read its result, not this comment.
"""
import os
import select
import socket
import sys
import time
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import netns_test as nt  # noqa: E402

INET6 = "2001:db8:ffff::9"


def serve6(token, port=9000):
    """UDP+TCP responder on :: answering `token`."""
    u = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
    # V6ONLY: the same namespaces already run the IPv4 responders on port 9000; a dual-stack bind would collide with them
    u.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
    u.bind(("::", port))
    t = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
    t.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
    t.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    t.bind(("::", port))
    t.listen(16)
    conns = []
    while True:
        rl, _, _ = select.select([u, t] + conns, [], [], 1)
        for s in rl:
            if s is u:
                _, a = u.recvfrom(64)
                u.sendto(token, a)
            elif s is t:
                c, _ = t.accept()
                c.send(token)
                conns.append(c)
            else:
                if not s.recv(64):
                    conns.remove(s)
                    s.close()


def udp6(dst, port=9000, timeout=0.6):
    s = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
    s.settimeout(timeout)
    try:
        s.sendto(b"?", (dst, port))
        return s.recvfrom(64)[0].decode()
    except OSError:
        return None
    finally:
        s.close()


def tcp6(dst, port=9000, timeout=0.8):
    s = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
    s.settimeout(timeout)
    try:
        s.connect((dst, port))
        return s.recv(64).decode() or None
    except OSError:
        return None
    finally:
        s.close()


class Env6(nt.Env):
    def __init__(self):
        super().__init__()
        R, C, W, X = self.R, self.C, self.W, self.X
        # no duplicate-address-detection delay. The per-device value is copied from "default" when the device is
        # CREATED (by the IPv4 Env above), so "all"/"default" alone are too late: set every device explicitly,
        # otherwise the addresses stay tentative for about a second and the very first probes are lost.
        for ns, devs in ((R, ("br-lan", "apclix0", "tailscale0")), (C, ("lanc",)), (W, ("wanp", "lo")), (X, ("tsx", "lo"))):
            for k in ("all", "default") + devs:
                ns.run("echo 0 > /proc/sys/net/ipv6/conf/%s/accept_dad" % k)
        R.run("echo 1 > /proc/sys/net/ipv6/conf/all/forwarding")
        for ns, dev, addr in (
            (R, "br-lan", "fd82::1/64"), (C, "lanc", "fd82::50/64"),
            (R, "apclix0", "2001:db8:1::2/64"), (W, "wanp", "2001:db8:1::1/64"),
            (R, "tailscale0", "fd7a:115c:a1e0::2/64"), (X, "tsx", "fd7a:115c:a1e0::1/64"),
            (W, "lo", INET6 + "/128"), (X, "lo", INET6 + "/128"),
        ):
            self.ip(ns, "addr", "add", addr, "dev", dev)
        self.ip(C, "-6", "route", "add", "default", "via", "fd82::1", "dev", "lanc")
        self.ip(R, "-6", "route", "add", "default", "via", "2001:db8:1::1", "dev", "apclix0")
        self.ip(W, "-6", "route", "add", "fd82::/64", "via", "2001:db8:1::2", "dev", "wanp")
        self.ip(X, "-6", "route", "add", "fd82::/64", "via", "fd7a:115c:a1e0::2", "dev", "tsx")
        W.spawn(serve6, b"WAN")
        X.spawn(serve6, b"TUN")
        time.sleep(0.3)
        # warm-up: resolve the neighbours (client-router and router-WAN, both directions) before any test measures anything;
        # a probe that races the first neighbour discovery would otherwise look like a broken test plane
        for _ in range(25):
            if self.C.call(udp6, INET6, 9000, 0.3) == "WAN":
                break
            time.sleep(0.2)

    def c6(self, proto="udp", dst=INET6):
        return self.C.call(udp6 if proto == "udp" else tcp6, dst)

    def ip6tables(self, *a):
        return self.R.run(["ip6tables", "-w", "5"] + list(a), env=self.env, check_rc=False).stdout


def check(cond, msg):
    if not cond:
        raise nt.Fail(msg)


def s6_baseline_direct_reaches_the_wan(e):
    # the control: without it every "no leak" result below could just mean the test plane is broken
    e.tsem("set", "direct", "--no-wait", check_rc=True)
    check(e.c6("udp") == "WAN" and e.c6("tcp") == "WAN", "IPv6 control path to the WAN does not work: the test plane is broken")


def s6_german_never_leaks_ipv6_to_the_wan(e):
    e.tsem("set", "direct", "--no-wait", check_rc=True)
    check(e.c6("udp") == "WAN", "precondition: IPv6 reaches the WAN in direct")
    e.go_german()
    check(e.c6("udp") != "WAN" and e.c6("tcp") != "WAN", "IPv6 leaked to the WAN in GERMAN")
    check(e.ip6tables("-S", "TSEM_FWD").count("REJECT") >= 1, "no IPv6 reject rule in GERMAN: " + e.ip6tables("-S", "TSEM_FWD"))


def s6_blocked_mode_never_leaks_ipv6(e):
    e.tsem("set", "direct", "--no-wait", check_rc=True)
    check(e.c6("udp") == "WAN", "precondition: IPv6 reaches the WAN in direct")
    e.tsem("set", "blocked", "--no-wait", check_rc=True)
    e.tick(4)
    check(e.status()["guard"] == "blocked", str(e.status()))
    check(e.c6("udp") != "WAN" and e.c6("tcp") != "WAN", "IPv6 leaked to the WAN in BLOCKED")


def s6_both_exit_nodes_down_never_leaks_ipv6(e):
    e.go_german()
    e.flag("egress_down_all")
    e.flag("ping_all_down")
    e.tick(14)
    check(e.status()["state"] == "BLOCKED", str(e.status()))
    check(e.c6("udp") != "WAN" and e.c6("tcp") != "WAN", "IPv6 leaked to the WAN with both exit nodes down")


def s6_router_own_ipv6_is_closed_in_blocked_and_open_in_direct(e):
    """F01 for IPv6: the router's own IPv6 traffic must not reach the WAN in BLOCKED (control: it does in DIRECT)."""
    e.tsem("set", "direct", "--no-wait", check_rc=True)
    check(e.R.call(udp6, INET6) == "WAN", "control: router-own IPv6 reaches the WAN in DIRECT")
    e.go_german()
    e.flag("egress_down_all")
    e.flag("ping_all_down")
    e.tick(14)
    check(e.status()["state"] == "BLOCKED" and e.status()["exit_node"] == "none", str(e.status()))
    check(e.R.call(udp6, INET6) != "WAN", "router-own IPv6 reached the WAN in BLOCKED")
    check(e.R.call(tcp6, INET6) != "WAN", "router-own IPv6/tcp reached the WAN in BLOCKED")
    check(e.c6("udp") != "WAN" and e.c6("tcp") != "WAN", "client IPv6 reached the WAN in BLOCKED")


def s6_firewall_flush_alone_does_not_open_ipv6(e):
    e.go_german()
    e.ip6tables("-F", "FORWARD")
    e.ip6tables("-P", "FORWARD", "ACCEPT")
    e.ip6tables("-F", "TSEM_FWD")
    e.ip(e.R, "-6", "route", "del", "default", "table", "52", check_rc=False)  # as the layer-1 test for IPv4: tunnel route gone
    check(e.c6("udp") != "WAN" and e.c6("tcp") != "WAN", "IPv6 leaked to the WAN after a firewall flush (second layer missing)")


def s6_reload_is_repaired_by_tick_for_ipv6(e):
    e.go_german()
    e.ip6tables("-F", "TSEM_FWD")
    e.tick(3)
    check(e.c6("udp") != "WAN" and e.c6("tcp") != "WAN", "IPv6 leaked to the WAN after a reload that dropped TSEM_FWD")


SCENARIOS = [v for k, v in sorted(globals().items()) if k.startswith("s6_")]


def main():
    if os.geteuid() != 0:
        print("FAIL: IPv6 packet tests need root (mandatory test, not skipped)")
        return 1
    if not os.path.exists("/proc/net/if_inet6"):
        print("FAIL: this kernel has no IPv6 (/proc/net/if_inet6 missing): the mandatory IPv6 packet tests cannot run here")
        return 1
    for tool in ("ip6tables", "iptables"):
        if not any(os.access(os.path.join(p, tool), os.X_OK) for p in os.environ["PATH"].split(":")):
            print("FAIL: %s is not installed: the mandatory IPv6 packet tests cannot run" % tool)
            return 1
    pid = os.fork()
    if pid == 0:
        try:
            os.unshare(nt.NET)
            os._exit(0)
        except Exception:
            os._exit(1)
    if os.waitpid(pid, 0)[1] != 0:
        print("FAIL: cannot create network namespaces (need CAP_SYS_ADMIN): the mandatory IPv6 packet tests cannot run")
        return 1
    sel = sys.argv[1:]
    fails = passed = 0
    for fn in SCENARIOS:
        if sel and fn.__name__ not in sel:
            continue
        e = None
        try:
            e = Env6()
            fn(e)
            print("  ok   %s" % fn.__name__)
            passed += 1
        except nt.Fail as x:
            print("  FAIL %s: %s" % (fn.__name__, x))
            fails += 1
        except Exception:
            print("  ERROR %s:\n%s" % (fn.__name__, traceback.format_exc()))
            fails += 1
        finally:
            if e:
                e.close()
    print("%d passed, %d failed (netns, IPv6)" % (passed, fails))
    return 1 if fails or not passed else 0


if __name__ == "__main__":
    sys.exit(main())
