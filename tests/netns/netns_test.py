#!/usr/bin/env python3
"""Packet-path tests for the tsem kill switch (IPv4) in Linux network namespaces.

Topology (one fresh set per scenario):

   client C ---br-lan--- ROUTER R ---apclix0--- W (ISP side, replies "WAN")
                            |
                       tailscale0 ---- X (tunnel side, replies "TUN")

W and X both own the "internet" address 203.0.113.9, so the answer tells which
path a packet really took. R runs the REAL tsem scripts with the REAL iptables
and ip-rule backend; only tailscale is a stub that installs/removes the default
route in table 52 the way tailscaled does. A pass here is evidence about packet
processing in this kernel (iptables-nft front end), NOT about the GL-MT3000.

IPv6 is not exercised: the kernel used for CI/sandbox may have no IPv6 at all.
"""
import os
import pickle
import select
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
P1, P2 = "100.64.0.10", "100.64.0.11"
NET = os.CLONE_NEWNET
INTERNET = "203.0.113.9"
EXTNET_NETS = ["10.30.0.0/24", "10.30.1.0/24", "10.30.2.0/24"]
EXTNET = ["10.30.0.10", "10.30.1.10", "10.30.2.10"]
OTHER_PRIVATE_NET, OTHER_PRIVATE = "10.60.0.0/24", "10.60.0.10"  # private, advertised, but NOT allowed by config


class Fail(Exception):
    pass


def check(cond, msg):
    if not cond:
        raise Fail(msg)


# ---------------------------------------------------------------- namespaces
class NS:
    def __init__(self, name):
        self.name = name
        r, w = os.pipe()
        self.pid = os.fork()
        if self.pid == 0:
            os.close(r)
            os.unshare(NET)
            os.write(w, b"x")
            os.close(w)
            signal.pause()
            os._exit(0)
        os.close(w)
        os.read(r, 1)
        os.close(r)
        self.fd = os.open("/proc/%d/ns/net" % self.pid, os.O_RDONLY)
        self.children = []

    def run(self, cmd, env=None, check_rc=True, timeout=60):
        p = subprocess.run(cmd, shell=isinstance(cmd, str), env=env, capture_output=True, text=True,
                           preexec_fn=lambda: os.setns(self.fd, NET), timeout=timeout)
        if check_rc and p.returncode != 0:
            raise Fail("[%s] %r failed rc=%d: %s%s" % (self.name, cmd, p.returncode, p.stdout, p.stderr))
        return p

    def call(self, fn, *args):
        """Run fn(*args) inside the namespace in a forked child, return its result."""
        r, w = os.pipe()
        pid = os.fork()
        if pid == 0:
            os.close(r)
            try:
                os.setns(self.fd, NET)
                res = ("ok", fn(*args))
            except BaseException as e:  # noqa
                res = ("err", repr(e))
            os.write(w, pickle.dumps(res))
            os._exit(0)
        os.close(w)
        buf = b""
        while True:
            c = os.read(r, 65536)
            if not c:
                break
            buf += c
        os.close(r)
        os.waitpid(pid, 0)
        kind, val = pickle.loads(buf)
        if kind == "err":
            raise Fail("[%s] call failed: %s" % (self.name, val))
        return val

    def spawn(self, fn, *args):
        pid = os.fork()
        if pid == 0:
            try:
                os.setns(self.fd, NET)
                fn(*args)
            finally:
                os._exit(0)
        self.children.append(pid)
        return pid

    def kill(self):
        for pid in self.children + [self.pid]:
            try:
                os.kill(pid, signal.SIGKILL)
                os.waitpid(pid, 0)
            except OSError:
                pass


def serve(token, tcp_port=9000, extra_udp=()):
    """UDP/TCP responder: answers `token`; UDP 53 answers b'DNS-'+token."""
    socks, tcpl = [], socket.socket()
    tcpl.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    tcpl.bind(("0.0.0.0", tcp_port))
    tcpl.listen(16)
    conns = []
    for port, tok in [(9000, token), (9001, token), (53, b"DNS-" + token)] + list(extra_udp):
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.bind(("0.0.0.0", port))
        socks.append((s, tok))
    while True:
        rl, _, _ = select.select([s for s, _ in socks] + [tcpl] + conns, [], [], 1)
        for s in rl:
            if s is tcpl:
                c, _ = tcpl.accept()
                c.send(token)
                conns.append(c)
            elif s in conns:
                d = s.recv(64)
                if not d:
                    conns.remove(s)
                    s.close()
                else:
                    s.send(token)
            else:
                d, a = s.recvfrom(64)
                tok = [t for ss, t in socks if ss is s][0]
                s.sendto(tok, a)


def serve_tcp(token, port):
    """TCP responder on an extra port (e.g. 443 for the underlay-exception tests)."""
    l = socket.socket()
    l.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    l.bind(("0.0.0.0", port))
    l.listen(16)
    while True:
        c, _ = l.accept()
        c.send(token)
        c.close()


def serve_private(token, port, need_prefix, addrs):
    """Responder for a remote private network (remote-site): answers ONLY when the source address
    starts with need_prefix. Without SNAT the client's 10.50.x source is not routable there,
    so a missing MASQUERADE shows up as 'no answer'. UDP is bound per address so that the
    reply carries the address that was asked (needed for conntrack/un-NAT)."""
    socks = []
    for ad in addrs:
        u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        u.bind((ad, port))
        socks.append(u)
    t = socket.socket()
    t.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    t.bind(("0.0.0.0", port))
    t.listen(16)
    while True:
        rl, _, _ = select.select(socks + [t], [], [], 1)
        for sk in rl:
            if sk is t:
                c, a = t.accept()
                if a[0].startswith(need_prefix):
                    c.send(token)
                c.close()
            else:
                d, a = sk.recvfrom(64)
                if a[0].startswith(need_prefix):
                    sk.sendto(token, a)


def udp_probe(dst, port=9000, timeout=0.5, mark=None, sport=None):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(timeout)
    if mark:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_MARK, mark)
    try:
        if sport:
            s.bind(("0.0.0.0", sport))
        s.sendto(b"?", (dst, port))
        return s.recvfrom(64)[0].decode()
    except OSError:
        return None
    finally:
        s.close()


def tcp_probe(dst, port=9000, timeout=0.6, mark=None):
    s = socket.socket()
    s.settimeout(timeout)
    if mark:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_MARK, mark)
    try:
        s.connect((dst, port))
        return s.recv(64).decode() or None
    except OSError:
        return None
    finally:
        s.close()


def held_tcp(dst, ctl_r, res_w):
    """Connect, report first answer, wait for GO, send again, report whether data came back."""
    s = socket.socket()
    s.settimeout(0.8)
    try:
        s.connect((dst, 9000))
        first = s.recv(64).decode()
    except OSError:
        os.write(res_w, pickle.dumps(("first-failed", None)))
        return
    os.write(res_w, pickle.dumps(("first", first)))
    os.read(ctl_r, 1)
    try:
        s.send(b"again\n")
        second = s.recv(64).decode() or None
    except OSError:
        second = None
    os.write(res_w, pickle.dumps(("second", second)))


# --------------------------------------------------------------- environment
class Env:
    def __init__(self, dns_redirect="", extra_conf=None):
        self.tmp = tempfile.mkdtemp(prefix="tsem-ns-")
        self.stub = os.path.join(self.tmp, "ts")
        os.makedirs(self.stub)
        self.now = 1790000000
        self.R, self.C, self.W, self.X = (NS(n) for n in "RCWX")
        R, C, W, X = self.R, self.C, self.W, self.X
        ip = os.path.join(HERE, "bin", "ip")
        for ns in (R, C, W, X):
            ns.run([ip, "link", "set", "lo", "up"])
        for a, b, na, nb in (("br-lan", "lanc", R, C), ("apclix0", "wanp", R, W), ("tailscale0", "tsx", R, X)):
            R.run([ip, "link", "add", a, "type", "veth", "peer", "name", b])
            R.run([ip, "link", "set", b, "netns", str({C: C.pid, W: W.pid, X: X.pid}[nb])])
        sysctl = lambda ns, k, v: ns.run("echo %s > /proc/sys/net/%s" % (v, k))  # noqa
        for ns, ifs, addrs in (
            (R, ["br-lan", "apclix0", "tailscale0"], [("br-lan", "10.20.0.1/24"), ("apclix0", "192.0.2.2/24"), ("tailscale0", "100.100.0.2/24")]),
            (C, ["lanc"], [("lanc", "10.20.0.50/24")]),
            (W, ["wanp"], [("wanp", "192.0.2.1/24")]),
            (X, ["tsx"], [("tsx", "100.100.0.1/24")]),
        ):
            for i in ifs:
                ns.run([ip, "link", "set", i, "up"])
            for i, a in addrs:
                ns.run([ip, "addr", "add", a, "dev", i])
        sysctl(R, "ipv4/ip_forward", 1)
        for k in ("all", "default", "br-lan", "apclix0", "tailscale0"):
            sysctl(R, "ipv4/conf/%s/rp_filter" % k, 0)
        C.run([ip, "route", "add", "default", "via", "10.20.0.1", "dev", "lanc"])
        R.run([ip, "route", "add", "default", "via", "192.0.2.1", "dev", "apclix0"])
        W.run([ip, "route", "add", "10.20.0.0/24", "via", "192.0.2.2", "dev", "wanp"])
        X.run([ip, "route", "add", "10.20.0.0/24", "via", "100.100.0.2", "dev", "tsx"])
        for a in (INTERNET + "/32", "203.0.113.53/32"):
            W.run([ip, "addr", "add", a, "dev", "lo"])
            X.run([ip, "addr", "add", a, "dev", "lo"])
        X.run([ip, "addr", "add", P1 + "/32", "dev", "lo"])
        for a in EXTNET + [OTHER_PRIVATE]:
            X.run([ip, "addr", "add", a + "/32", "dev", "lo"])
        X.spawn(serve_private, b"EXTNET", 9100, "100.", EXTNET + [OTHER_PRIVATE])
        for k in ("all", "default", "wanp"):
            sysctl(W, "ipv4/conf/%s/rp_filter" % k, 0)
        for k in ("all", "default", "tsx"):
            sysctl(X, "ipv4/conf/%s/rp_filter" % k, 0)
        W.spawn(serve, b"WAN", 9000, ((123, b"WAN"), (67, b"WAN")))
        W.spawn(serve_tcp, b"WAN", 443)
        X.spawn(serve, b"TUN")
        R.spawn(serve, b"ROUTER")
        # what tailscaled installs (static part): its rule priorities and the tailnet route
        R.run([ip, "rule", "add", "priority", "5210", "fwmark", "0x80000/0xff0000", "lookup", "main"])
        R.run([ip, "rule", "add", "priority", "5270", "lookup", "52"])
        R.run([ip, "route", "add", "100.64.0.0/10", "dev", "tailscale0", "table", "52"])
        for net in EXTNET_NETS + [OTHER_PRIVATE_NET]:  # subnet routes advertised by the remote-site exit/subnet routers
            R.run([ip, "route", "add", net, "dev", "tailscale0", "table", "52"])
        self.env = dict(os.environ)
        self.env.update(
            PATH=os.path.join(HERE, "bin") + ":" + os.environ["PATH"],
            TSEM_BACKEND="ipt", TSEM_LIBDIR=os.path.join(ROOT, "src/usr/lib/tsem"),
            TSEM_STATE_DIR=os.path.join(self.tmp, "state"), TSEM_RUN_DIR=os.path.join(self.tmp, "run"),
            TSEM_CONF=os.path.join(self.tmp, "none.conf"), TSEM_PRIMARY=P1, TSEM_SECONDARY=P2,
            TSEM_LAN_IFACES="br-lan", TSEM_TAILSCALE=os.path.join(ROOT, "tests/stubs/tailscale"),
            TS_STUB_DIR=self.stub, TSEM_PROBE_CMD=os.path.join(HERE, "probe_egress.py"),
            TSEM_PROBE_TIMEOUT="1", TSEM_SYSLOG="0", TSEM_SET_TICK_DELAY="0", TSEM_NOW=str(self.now),
            # router-own DNS is redirected to a resolver BOTH test sides own: the answer token tells the path taken
            TSEM_DNS_ROUTER="203.0.113.53",
        )
        if dns_redirect:
            self.env["TSEM_DNS_REDIRECT"] = dns_redirect
        for k, v in (extra_conf or {}).items():
            self.env[k] = v
        os.makedirs(self.env["TSEM_STATE_DIR"])

    # tsem on the router
    def tsem(self, *a, check_rc=False):
        self.env["TSEM_NOW"] = str(self.now)
        return self.R.run(["sh", os.path.join(ROOT, "src/usr/sbin/tsem")] + list(a), env=self.env, check_rc=check_rc)

    def tick(self, n=1):
        for _ in range(n):
            self.tsem("tick")
            self.now += 5

    def status(self):
        out = self.tsem("status").stdout
        return dict(l.split("=", 1) for l in out.splitlines() if "=" in l)

    def go_german(self, maxticks=14):
        self.tsem("set", "german", "--no-wait", "--source", "test")
        for _ in range(maxticks):
            if self.status()["state"] in ("PRIMARY_ACTIVE", "SECONDARY_ACTIVE"):
                return
            self.tick()
        raise Fail("did not become active: " + str(self.status()))

    def flag(self, name, on=True):
        p = os.path.join(self.stub, name)
        if on:
            open(p, "w").close()
        elif os.path.exists(p):
            os.remove(p)

    def ip(self, ns, *a, check_rc=True):
        return ns.run([os.path.join(HERE, "bin", "ip")] + list(a), env=self.env, check_rc=check_rc)

    def client(self, proto="udp", dst=INTERNET, port=9000, **kw):
        if proto == "udp":
            return self.C.call(udp_probe, dst, port, kw.get("timeout", 0.5))
        return self.C.call(tcp_probe, dst, port)

    def r_udp(self, dst=INTERNET, port=9000, mark=None, sport=None):
        """UDP request from a router-own socket (optionally with tailscaled's fwmark)."""
        return self.R.call(udp_probe, dst, port, 0.5, mark, sport)

    def r_tcp(self, dst=INTERNET, port=9000, mark=None):
        return self.R.call(tcp_probe, dst, port, 0.6, mark)

    def router_marked(self, dst=INTERNET):
        return self.R.call(udp_probe, dst, 9000, 0.5, 0x80000)

    def masq(self, on=True):
        """The fw3 zone masquerading as found on root (zone_tailscale0_postrouting / MASQUERADE).
        Created and removed ONLY by the test harness; tsem must never touch it."""
        self.iptc("-t", "nat", "-N", "zone_tailscale0_postrouting")
        self.iptc("-t", "nat", "-F", "zone_tailscale0_postrouting")
        while "zone_tailscale0_postrouting" in self.iptc("-t", "nat", "-S", "POSTROUTING"):
            self.iptc("-t", "nat", "-D", "POSTROUTING", "-o", "tailscale0", "-j", "zone_tailscale0_postrouting")
        if on:
            self.iptc("-t", "nat", "-A", "zone_tailscale0_postrouting", "-j", "MASQUERADE")
            self.iptc("-t", "nat", "-A", "POSTROUTING", "-o", "tailscale0", "-j", "zone_tailscale0_postrouting")

    def nat_post(self):
        return self.iptc("-t", "nat", "-S", "POSTROUTING") + self.iptc("-t", "nat", "-S", "zone_tailscale0_postrouting")

    def iptc(self, *a):
        return self.R.run(["iptables", "-w", "5"] + list(a), env=self.env, check_rc=False).stdout

    def close(self):
        for ns in (self.R, self.C, self.W, self.X):
            ns.kill()
        subprocess.run(["rm", "-rf", self.tmp])


class LeakMonitor(threading.Thread):
    """Continuously probes from the client namespace; records every reply."""

    def __init__(self, env):
        super().__init__(daemon=True)
        self.env, self.stop, self.rows = env, False, []

    def run(self):
        os.setns(self.env.C.fd, NET)
        while not self.stop:
            t = time.monotonic()
            self.rows.append((t, "udp", udp_probe(INTERNET, 9000, 0.04)))
            t = time.monotonic()
            self.rows.append((t, "tcp", tcp_probe(INTERNET, 9000, 0.08)))
            time.sleep(0.01)

    def leaks_since(self, t0):
        return [r for r in self.rows if r[0] >= t0 and r[2] == "WAN"]

    def seen(self, tok):
        return any(r[2] == tok for r in self.rows)


class RouterMonitor(threading.Thread):
    """Probes from router-OWN (unmarked) sockets: plain traffic and DNS. Any answer from the WAN side is a leak."""

    def __init__(self, env):
        super().__init__(daemon=True)
        self.env, self.stop, self.rows = env, False, []

    def run(self):
        os.setns(self.env.R.fd, NET)
        while not self.stop:
            t = time.monotonic()
            self.rows.append((t, "udp", udp_probe(INTERNET, 9000, 0.04)))
            self.rows.append((t, "dns", udp_probe(INTERNET, 53, 0.04)))
            self.rows.append((t, "tcp", tcp_probe(INTERNET, 9000, 0.08)))
            time.sleep(0.01)

    def leaks_since(self, t0):
        return [r for r in self.rows if r[0] >= t0 and r[2] in ("WAN", "DNS-WAN")]

    def seen(self, tok):
        return any(r[2] == tok for r in self.rows)


# ------------------------------------------------------------------ scenarios
def s_direct_baseline(e):
    e.tsem("set", "direct", "--no-wait", check_rc=True)
    check(e.client("udp") == "WAN" and e.client("tcp") == "WAN", "DIRECT must reach the WAN path")
    check(e.client("udp", "10.20.0.1", 9001) == "ROUTER", "router reachable")
    check(e.status()["state"] == "DISABLED" and e.status()["guard"] == "open", "state/guard")
    check("TSEM_FWD" in e.iptc("-S") and "tsem:open" in e.iptc("-S", "TSEM_FWD"), "open chain present")


def s_german_active_tunnel_only(e):
    e.go_german()
    st = e.status()
    check(st["state"] == "PRIMARY_ACTIVE" and st["guard"] == "german" and st["leak_risk"] == "false", str(st))
    check(e.client("udp") == "TUN" and e.client("tcp") == "TUN", "GERMAN must use the tunnel path")
    check(e.client("udp", "10.20.0.1", 9001) == "ROUTER", "management access must stay")
    check(e.client("udp", P1) == "TUN", "tailnet reachable")


def s_transition_direct_to_german_no_leak(e):
    e.tsem("set", "direct", "--no-wait", check_rc=True)
    check(e.client() == "WAN", "precondition")
    m = LeakMonitor(e)
    m.start()
    time.sleep(0.2)
    e.tsem("set", "german", "--no-wait", "--source", "hw", check_rc=True)
    t0 = time.monotonic()
    for _ in range(14):
        e.tick()
        if e.status()["state"] == "PRIMARY_ACTIVE":
            break
    time.sleep(0.2)
    m.stop = True
    m.join()
    check(not m.leaks_since(t0), "WAN leak after the switch to GERMAN: %r" % m.leaks_since(t0)[:3])
    check(m.seen("TUN"), "tunnel never became usable")


def s_layer1_alone_stops_leak_when_firewall_is_flushed(e):
    e.go_german()
    e.tsem("set", "german", "--no-wait")
    # fw3 reload / hostile flush: no netfilter protection at all, policy ACCEPT
    e.iptc("-F", "FORWARD")
    e.iptc("-P", "FORWARD", "ACCEPT")
    # exit node forgotten (tailscaled restarted without it)
    e.ip(e.R, "route", "del", "default", "table", "52")
    check(e.client("udp") is None and e.client("tcp") is None, "layer 1 (policy routing) alone must stop the leak")


def s_layer2_alone_stops_leak_when_rules_are_gone(e):
    e.go_german()
    for prio in (5280, 5290):
        e.ip(e.R, "rule", "del", "iif", "br-lan", "priority", str(prio))
    e.ip(e.R, "route", "del", "default", "table", "52")
    check(e.client("udp") is None and e.client("tcp") is None, "layer 2 (netfilter) alone must stop the leak")


def s_accept_rules_cannot_bypass(e):
    e.go_german()
    e.iptc("-I", "FORWARD", "1", "-j", "ACCEPT")  # some other tool inserts ACCEPT-all in front
    e.ip(e.R, "route", "del", "default", "table", "52")
    check(e.client() is None, "an ACCEPT rule in front must not leak (layer 1 still blocks)")
    st = e.status()
    check(st["guard"] == "inconsistent" and st["leak_risk"] == "true", "hook displacement must be reported: " + str(st))
    e.tick()
    check(e.status()["guard"] in ("german", "blocked"), "tick must restore hook position 1")
    check(e.iptc("-S", "FORWARD").splitlines()[1] == "-A FORWARD -j TSEM_FWD", "hook is first rule again")


def s_established_flow_does_not_bypass(e):
    e.tsem("set", "direct", "--no-wait", check_rc=True)
    ctl_r, ctl_w = os.pipe()
    res_r, res_w = os.pipe()
    e.C.spawn(held_tcp, INTERNET, ctl_r, res_w)
    kind, first = pickle.loads(os.read(res_r, 4096))
    check(first == "WAN", "established flow should start on the WAN path, got %r" % (first,))
    e.tsem("set", "german", "--no-wait", check_rc=True)
    os.write(ctl_w, b"g")
    kind, second = pickle.loads(os.read(res_r, 4096))
    check(second is None, "ESTABLISHED flow kept working through the WAN after switching to GERMAN: %r" % (second,))


def s_tailscaled_dead_blocks(e):
    e.go_german()
    e.flag("ts_dead")
    e.ip(e.R, "route", "del", "default", "table", "52")
    e.ip(e.R, "rule", "del", "priority", "5270")  # tailscaled removes its rules when it exits
    check(e.client("udp") is None and e.client("tcp") is None, "dead tailscaled must not leak")
    check(e.router_marked() == "WAN", "router's own underlay (marked) traffic must keep working")


def s_control_and_management_in_all_states(e):
    for label in ("direct", "active", "blocked"):
        if label == "direct":
            e.tsem("set", "direct", "--no-wait", check_rc=True)
        elif label == "active":
            e.go_german()
        else:
            e.flag("egress_down_all")
            e.flag("ping_all_down")
            e.tick(12)
            check(e.status()["state"] == "BLOCKED", "expected BLOCKED, got " + e.status()["state"])
        check(e.router_marked() == "WAN", "%s: tailscale underlay (marked) traffic must work" % label)
        check(e.client("udp", "10.20.0.1", 9001) == "ROUTER", "%s: management access" % label)


def s_failover_with_no_leak(e):
    e.go_german()
    m = LeakMonitor(e)
    m.start()
    t0 = time.monotonic()
    e.flag("egress_down_" + P1)
    for _ in range(16):
        e.tick()
        if e.status()["state"] == "SECONDARY_ACTIVE":
            break
    time.sleep(0.2)
    m.stop = True
    m.join()
    check(e.status()["state"] == "SECONDARY_ACTIVE", "no failover: " + str(e.status()))
    check(not m.leaks_since(t0), "WAN leak during failover: %r" % m.leaks_since(t0)[:3])
    check(e.client() == "TUN", "traffic must flow over the tunnel after failover")
    check(open(os.path.join(e.stub, "exit")).read().strip() == P2, "exit node is the secondary")


def s_both_down_blocked_then_recovers(e):
    e.go_german()
    m = LeakMonitor(e)
    m.start()
    t0 = time.monotonic()
    e.flag("egress_down_all")
    e.flag("ping_all_down")
    e.tick(14)
    check(e.status()["state"] == "BLOCKED", str(e.status()))
    check(e.client() is None and e.client("tcp") is None, "BLOCKED must stop internet traffic")
    check(e.client("udp", P1) == "TUN", "tailnet destinations stay reachable in BLOCKED")
    check(e.client("udp", "10.20.0.1", 9001) == "ROUTER", "management access in BLOCKED")
    e.flag("egress_down_all", False)
    e.flag("ping_all_down", False)
    e.tick(16)
    time.sleep(0.2)
    m.stop = True
    m.join()
    check(e.status()["state"] == "PRIMARY_ACTIVE", "no recovery: " + str(e.status()))
    check(not m.leaks_since(t0), "WAN leak during outage/recovery: %r" % m.leaks_since(t0)[:3])
    check(e.client() == "TUN", "tunnel restored")


def s_firewall_reload(e):
    e.go_german()
    m = LeakMonitor(e)
    m.start()
    t0 = time.monotonic()
    e.iptc("-F", "FORWARD")      # fw3 reload flushes the built-in chain
    e.iptc("-F", "TSEM_FWD")     # and (worst case) our chain contents
    time.sleep(0.3)
    st = e.status()
    check(st["leak_risk"] == "true" and st["guard"] == "inconsistent", "drift must be visible: " + str(st))
    e.tsem("reapply", check_rc=True)  # what the firewall include / tick does
    st = e.status()
    check(st["guard"] == "german" and st["leak_risk"] == "false", "reapply must restore: " + str(st))
    m.stop = True
    m.join()
    check(not m.leaks_since(t0), "WAN leak during firewall reload: %r" % m.leaks_since(t0)[:3])


def s_firewall_reload_repaired_by_tick(e):
    e.go_german()
    e.iptc("-F", "FORWARD")
    e.tick()
    check(e.status()["guard"] == "german", "tick must repair a flushed FORWARD chain")


def s_reboot_fail_closed_then_recovers(e):
    e.go_german()
    # simulate a fresh kernel: all netfilter state, our rules and the tunnel route are gone
    e.iptc("-F")
    for c in ("FORWARD",):
        e.iptc("-F", c)
    e.iptc("-X")
    for prio in (5280, 5290):
        e.ip(e.R, "rule", "del", "iif", "br-lan", "priority", str(prio), check_rc=False)
    e.flag("exit", False)
    e.ip(e.R, "route", "del", "default", "table", "52", check_rc=False)
    subprocess.run(["rm", "-rf", e.env["TSEM_RUN_DIR"]])  # tmpfs is gone, intent (flash) stays
    r = e.tsem("boot", check_rc=True)
    st = e.status()
    check(st["guard"] == "blocked" and st["mode"] == "german", "boot must be fail-closed: " + str(st))
    check(e.client() is None, "no traffic may pass between boot and the first verified node")
    for _ in range(14):
        e.tick()
        if e.status()["state"] == "PRIMARY_ACTIVE":
            break
    check(e.status()["state"] == "PRIMARY_ACTIVE" and e.client() == "TUN", "must recover after reboot")


def s_wan_change(e):
    e.go_german()
    e.ip(e.R, "route", "replace", "default", "via", "192.0.2.1", "dev", "apclix0", "metric", "50")
    e.ip(e.R, "route", "del", "default", "via", "192.0.2.1", "dev", "apclix0", "metric", "0", check_rc=False)
    e.tsem("reapply", check_rc=True)
    e.tick(2)
    check(e.client() == "TUN" and e.status()["state"] == "PRIMARY_ACTIVE", "WAN route change must not disturb GERMAN")


def s_idempotent_apply(e):
    e.go_german()
    def snap():
        return (e.iptc("-S", "TSEM_FWD"), e.iptc("-S", "FORWARD"), e.ip(e.R, "rule", "show").stdout, e.iptc("-t", "nat", "-S", "PREROUTING"))
    before = snap()
    for _ in range(3):
        e.tsem("reapply", check_rc=True)
    e.tick(2)
    check(snap() == before, "repeated apply must not change rules")
    check(e.iptc("-S", "FORWARD").count("-j TSEM_FWD") == 1, "exactly one hook")


def s_dns_redirect(e):
    e.go_german()
    check(e.client("udp", "203.0.113.53", 53) == "DNS-TUN", "DNS to a resolver goes through the tunnel")
    e.flag("egress_down_all")
    e.flag("ping_all_down")
    e.tick(14)
    check(e.client("udp", "203.0.113.53", 53) is None, "no DNS in BLOCKED")


def s_dns_redirect_forces_all_client_dns(e):
    e.go_german()
    # client asks a random public resolver; it must end up at the configured resolver via the tunnel
    r = e.client("udp", "8.8.8.8", 53)
    check(r == "DNS-TUN", "client DNS to 8.8.8.8 must be redirected through the tunnel, got %r" % (r,))
    e.tsem("set", "direct", "--no-wait", check_rc=True)
    check("DNAT" not in e.iptc("-t", "nat", "-S", "TSEM_DNS"), "redirect removed in DIRECT")


def s_set_direct_restores_and_teardown_removes_everything(e):
    e.go_german()
    e.tsem("set", "direct", "--no-wait", check_rc=True)
    check(e.client() == "WAN", "DIRECT restored")
    e.go_german()
    e.tsem("teardown", check_rc=True)
    check("TSEM" not in e.iptc("-S"), "no TSEM chains after teardown")
    check("5280" not in e.ip(e.R, "rule", "show").stdout and "5290" not in e.ip(e.R, "rule", "show").stdout, "no ip rules after teardown")
    check("-j TSEM" not in e.iptc("-S", "FORWARD"), "no hooks after teardown")


def s_stray_deny_rule_from_an_older_release_is_removed(e):
    """A leftover 'iif br-lan blackhole' on the suppress priority silently cuts every LAN client in DIRECT. tsem removes it."""
    e.tsem("set", "direct", "--no-wait", check_rc=True)
    e.ip(e.R, "rule", "add", "iif", "br-lan", "priority", "5280", "blackhole")
    check(e.client() != "WAN", "precondition: the stray rule must block the LAN client")
    check(e.status()["guard"] != "open", "a stray deny rule must make the guard state inconsistent, not 'open'")
    e.tsem("set", "direct", "--no-wait", check_rc=True)
    e.tsem("tick")
    check("blackhole" not in e.ip(e.R, "rule", "show").stdout, "the stray rule must be gone after DIRECT is applied")
    check(e.client() == "WAN", "DIRECT must reach the WAN again")
    e.go_german()
    e.ip(e.R, "rule", "add", "iif", "br-lan", "priority", "5280", "blackhole")
    e.tsem("set", "direct", "--no-wait", check_rc=True)
    check(e.client() == "WAN" and "blackhole" not in e.ip(e.R, "rule", "show").stdout, "stray rule removed when leaving the protected mode too")


def s_selftest(e):
    e.go_german()
    out = e.tsem("selftest").stdout
    check("FAIL" not in out, "selftest reported FAIL:\n" + out)
    check("rule-order" in out and "PASS rule-order" in out, "rule order check: " + out)


def s_guard_rule_text_is_stable(e):
    e.go_german()
    rules = e.iptc("-S", "TSEM_FWD")
    rules = rules.replace('"', "")
    for needle in ("-A TSEM_FWD -i br-lan -o tailscale0 -j RETURN", "-A TSEM_FWD -i br-lan -o br-lan -j RETURN", "--comment tsem:german"):
        check(needle in rules, "missing rule: " + needle + "\n" + rules)
    check("-d" not in rules.replace("-A TSEM_FWD", ""), "german rules must not contain destination filters")


# ---- router-own traffic (RC2): OUTPUT guard ------------------------------------
def no_tunnel_route(e):
    """tailscaled has nothing to offer: router-own traffic would fall back to the main (WAN) default route."""
    e.ip(e.R, "route", "del", "default", "table", "52", check_rc=False)


def s_router_own_open_in_direct(e):
    e.tsem("set", "direct", "--no-wait", check_rc=True)
    check(e.r_udp() == "WAN" and e.r_udp(port=53) == "DNS-WAN", "DIRECT must leave router traffic alone")
    check("tsem:open" in e.iptc("-S", "TSEM_OUT"), "OUTPUT chain must be in the open state")


def s_router_own_goes_through_tunnel_when_active(e):
    e.go_german()
    check(e.r_udp() == "TUN", "router traffic must use the tunnel: %r" % e.r_udp())
    check(e.r_udp(port=53) == "DNS-TUN", "router DNS must use the tunnel")
    check(e.status()["guard"] == "german" and e.status()["leak_risk"] == "false", str(e.status()))


def s_router_own_blocked_when_no_exit_route(e):
    """Both exit nodes down AND no tunnel default route: nothing router-own may reach the WAN, except the documented exceptions."""
    e.go_german()
    e.flag("egress_down_all")
    e.flag("ping_all_down")
    e.tick(14)
    check(e.status()["state"] == "BLOCKED", str(e.status()))
    no_tunnel_route(e)
    check(e.r_udp() is None and e.r_tcp() is None, "router-own traffic leaked to the WAN while BLOCKED")
    check(e.r_udp(port=53) is None, "router-own DNS leaked to the WAN while BLOCKED")
    check(e.r_tcp(port=53) is None, "router-own DNS/tcp leaked")
    check(e.client() is None and e.client("tcp") is None, "client traffic leaked while BLOCKED")
    # documented exceptions
    check(e.r_udp(mark=0x80000) == "WAN", "tailscaled underlay (marked udp) must work")
    check(e.r_tcp(port=443, mark=0x80000) == "WAN", "tailscaled underlay (marked tcp/443) must work")
    check(e.r_udp(port=123) == "WAN", "NTP exception (default on) must work")
    check(e.r_udp(port=67, sport=68) == "WAN", "DHCP client exception must work")
    # the exceptions must stay narrow
    check(e.r_udp(port=53, mark=0x80000) is None, "marked traffic must not be an open door for DNS")
    check(e.r_tcp(port=9000, mark=0x80000) is None, "marked tcp is limited to 80/443")
    check(e.r_tcp(port=443) is None, "unmarked tcp/443 must not reach the WAN")
    check(e.r_udp(port=67) is None, "DHCP exception is bound to source port 68")
    check(e.r_udp(port=9000, sport=123) is None, "source port 123 alone must not open anything")
    check(e.status()["leak_risk"] == "false", str(e.status()))


def tunnel_default_routes(e):
    out = e.ip(e.R, "route", "show", "table", "52", check_rc=False).stdout
    return "\n".join(l for l in out.splitlines() if l.startswith("default") or l.startswith("0.0.0.0/0"))


def s_f01_blocked_router_cannot_use_the_tunnel_default_route(e):
    """F01/F02 (hardware t03_both_down): in BLOCKED the exit node stayed selected, so tailscale's default route
    in table 52 stayed and router-own HTTPS still got out through the tunnel of a node declared unusable.
    The route is NOT removed by the test harness here: tsem itself must clear the exit node."""
    e.go_german()
    # control: with a working exit node the router really uses the tunnel (proves the probe can see the tunnel path)
    check(e.r_udp() == "TUN" and e.r_tcp() == "TUN", "control: router traffic goes through the tunnel while active")
    check(tunnel_default_routes(e) != "", "control: the tunnel default route exists while active")
    m = RouterMonitor(e)
    m.start()
    t0 = time.monotonic()
    e.flag("egress_down_all")
    e.flag("ping_all_down")
    e.tick(14)
    st = e.status()
    check(st["state"] == "BLOCKED", str(st))
    check(st["exit_node"] == "none", "BLOCKED must not keep an exit node selected: " + str(st))
    check(tunnel_default_routes(e) == "", "BLOCKED must leave no default route in table 52: " + tunnel_default_routes(e))
    check(e.r_udp() is None and e.r_tcp() is None, "router-own traffic got out in BLOCKED: udp=%r tcp=%r" % (e.r_udp(), e.r_tcp()))
    check(e.r_tcp(port=443) is None, "router-own HTTPS got out in BLOCKED (the F01 symptom)")
    check(e.r_udp(port=53) is None, "router-own DNS got out in BLOCKED")
    check(e.client() is None and e.client("tcp") is None, "client traffic got out in BLOCKED")
    check(e.r_udp(P1) == "TUN", "tailnet destinations stay reachable for the router in BLOCKED")
    check(e.client("udp", P1) == "TUN", "tailnet destinations stay reachable for clients in BLOCKED")
    check(st["leak_risk"] == "false", str(st))
    e.flag("egress_down_all", False)
    e.flag("ping_all_down", False)
    e.tick(16)
    time.sleep(0.2)
    m.stop = True
    m.join()
    check(e.status()["state"] == "PRIMARY_ACTIVE", "no automatic recovery: " + str(e.status()))
    check(e.r_udp() == "TUN" and e.client() == "TUN", "tunnel restored for router and clients")
    check(not m.leaks_since(t0), "router-own WAN leak during outage/recovery: %r" % m.leaks_since(t0)[:3])


def s_f01_explicit_blocked_mode_clears_the_exit_node(e):
    e.go_german()
    e.tsem("set", "blocked", "--no-wait", check_rc=True)
    st = e.status()
    check(st["state"] == "BLOCKED" and st["exit_node"] == "none", str(st))
    check(tunnel_default_routes(e) == "", "explicit BLOCKED must leave no tunnel default route")
    check(e.r_udp() is None and e.r_tcp(port=443) is None, "router-own traffic got out in explicit BLOCKED")
    check(e.client() is None and e.client("tcp") is None, "client traffic got out in explicit BLOCKED")
    e.tick(3)
    check(e.status()["state"] == "BLOCKED" and e.status()["exit_node"] == "none", "tick must hold BLOCKED: " + str(e.status()))


def s_f01_exit_node_that_cannot_be_cleared_never_opens_the_wan(e):
    """If tailscaled refuses to clear the exit node, the result is an ERROR with a closed guard. The router may still
    reach the Internet through the (unusable) exit node's tunnel, but NEVER through the WAN, and clients stay blocked."""
    e.go_german()
    e.flag("egress_down_all")
    e.flag("ping_all_down")
    e.flag("set_fail")
    e.tick(14)
    st = e.status()
    check(st["state"] == "ERROR" and st["guard"] in ("blocked", "german"), str(st))
    check(e.client() is None and e.client("tcp") is None, "client traffic must stay blocked")
    check(e.r_udp() != "WAN" and e.r_tcp() != "WAN" and e.r_tcp(port=443) != "WAN", "router-own traffic reached the WAN")


ISP_DNS = "203.0.113.99"  # an ISP resolver: only the WAN side owns it, the exit node cannot reach it (F03)


def isp_dns(e):
    e.ip(e.W, "addr", "add", ISP_DNS + "/32", "dev", "lo")


def s_f03_router_own_dns_to_the_isp_resolver_is_redirected_through_the_tunnel(e):
    """F03 (hardware): `nslookup` on the router timed out in GERMAN. Its upstream resolvers were ISP resolvers (103.100.x);
    router-own traffic leaves through the exit node, which cannot reach them."""
    isp_dns(e)
    e.tsem("set", "direct", "--no-wait", check_rc=True)
    check(e.r_udp(ISP_DNS, 53) == "DNS-WAN", "control: DIRECT must leave router DNS alone (the ISP resolver answers over the WAN)")
    check(e.iptc("-t", "nat", "-S", "TSEM_DNS_OUT").count("DNAT") == 0, "no DNAT in DIRECT")
    e.go_german()
    check(e.r_udp(ISP_DNS, 53) == "DNS-TUN", "GERMAN: a router-own query to the ISP resolver must end at the tunnel-side resolver, got %r" % (e.r_udp(ISP_DNS, 53),))
    check(e.r_udp("8.8.8.8", 53) == "DNS-TUN", "GERMAN: router-own query to any public resolver must be redirected too")
    rules = e.iptc("-t", "nat", "-S", "TSEM_DNS_OUT")
    check("-p tcp" in rules and "-p udp" in rules and "203.0.113.53" in rules, "udp and tcp must both be redirected:\n" + rules)
    check(e.status()["guard"] == "german" and e.status()["leak_risk"] == "false", str(e.status()))


def s_f03_without_the_router_dns_redirect_the_isp_resolver_is_unreachable(e):
    """Negative control: this is the F03 failure itself (TSEM_DNS_ROUTER empty = the old behaviour)."""
    isp_dns(e)
    e.go_german()
    check(e.r_udp(ISP_DNS, 53) is None, "without the redirect the ISP resolver must be unreachable from the exit node (F03 root cause)")


def s_f03_router_dns_never_leaks_in_blocked_and_survives_failover(e):
    isp_dns(e)
    e.go_german()
    m = RouterMonitor(e)
    m.start()
    t0 = time.monotonic()
    e.flag("egress_down_" + P1)
    for _ in range(16):
        e.tick()
        if e.status()["state"] == "SECONDARY_ACTIVE":
            break
    check(e.status()["state"] == "SECONDARY_ACTIVE", "no failover: " + str(e.status()))
    check(e.r_udp(ISP_DNS, 53) == "DNS-TUN", "router DNS must keep working through the secondary exit node")
    e.flag("egress_down_all")
    e.flag("ping_all_down")
    e.tick(14)
    check(e.status()["state"] == "BLOCKED", str(e.status()))
    check(e.r_udp(ISP_DNS, 53) is None and e.r_udp("203.0.113.53", 53) is None and e.r_udp(port=53) is None, "router DNS got out in BLOCKED")
    check(e.client("udp", ISP_DNS, 53) is None, "client DNS to the ISP resolver got out in BLOCKED")
    e.flag("egress_down_all", False)
    e.flag("egress_down_" + P1, False)
    e.flag("ping_all_down", False)
    e.tick(40)
    m.stop = True
    m.join()
    check(e.status()["state"] in ("PRIMARY_ACTIVE", "SECONDARY_ACTIVE"), "no recovery: " + str(e.status()))
    check(e.r_udp(ISP_DNS, 53) == "DNS-TUN", "router DNS works again after recovery")
    check(not [r for r in m.leaks_since(t0)], "router DNS/traffic leaked to the WAN: %r" % m.leaks_since(t0)[:3])


def s_f03_underlay_marked_dns_and_tailnet_dns_are_not_redirected(e):
    """tailscaled's own marked sockets keep their own policy; MagicDNS (tailnet address) is not touched."""
    isp_dns(e)
    e.go_german()
    check(e.r_udp(ISP_DNS, 53, mark=0x80000) is None, "marked DNS stays blocked while TSEM_ALLOW_UNDERLAY_DNS=0 (not silently redirected)")
    check(e.r_udp(P1, 53) == "DNS-TUN", "a tailnet resolver is queried directly (no DNAT)")
    rules = e.iptc("-t", "nat", "-S", "TSEM_DNS_OUT")
    check("--mark 0x80000/0xff0000" in rules and "-d 100.64.0.0/10" in rules, rules)


def s_f03_router_dns_chain_is_repaired_removed_and_checked(e):
    e.go_german()
    check(e.status()["guard"] == "german", str(e.status()))
    e.iptc("-t", "nat", "-F", "TSEM_DNS_OUT")  # a firewall reload that dropped our rules
    check(e.status()["guard"] == "inconsistent", "a missing router DNS redirect must be reported: " + e.status()["guard"])
    e.tick(2)
    check(e.status()["guard"] == "german" and "DNAT" in e.iptc("-t", "nat", "-S", "TSEM_DNS_OUT"), "tick must repair the router DNS redirect")
    e.tsem("teardown", check_rc=True)
    check("TSEM_DNS_OUT" not in e.iptc("-t", "nat", "-S"), "teardown must remove the router DNS chain and its hook")


def _fail_over_then_heal(e, derp_only):
    """Primary dies, the secondary takes over, the primary comes back (optionally only via DERP, ping exit code 1).
    Returns the number of simulated seconds until the controller is on the primary again (None = never)."""
    e.go_german()
    e.flag("egress_down_" + P1)
    e.flag("ping_down_" + P1)
    for _ in range(20):
        e.tick()
        if e.status()["state"] == "SECONDARY_ACTIVE":
            break
    check(e.status()["state"] == "SECONDARY_ACTIVE", "no failover: " + str(e.status()))
    e.flag("egress_down_" + P1, False)
    e.flag("ping_down_" + P1, False)
    if derp_only:
        e.flag("ping_derp_" + P1)  # `tailscale ping` prints the pong via DERP and exits 1 (hardware observation)
    t0 = e.now
    seen = []
    for _ in range(80):
        e.tick()
        s = e.status()
        seen.append((e.now - t0, s["state"], s["primary_probe"], s["primary_ok"], s["return_wait"]))
        if s["state"] == "PRIMARY_ACTIVE":
            return e.now - t0, seen
    return None, seen


def s_f06_primary_returns_after_hysteresis_with_a_direct_path(e):
    """F06: `primary_ok=ok primary_probe=reach state=SECONDARY_ACTIVE`. Hysteresis (TSEM_RETURN_N successes, TSEM_DWELL
    seconds, backoff) explains a delay; it must never become 'stuck'. Bounded: backoff + the larger of the two."""
    dt, seen = _fail_over_then_heal(e, derp_only=False)
    check(dt is not None, "the primary was never taken back although it is healthy: " + str(seen[-3:]))
    check(dt <= 30 + 60 + 40, "the return took %ss, more than backoff(30)+dwell(60)+margin" % dt)
    # while waiting, the controller says why (primary healthy, hysteresis running) and the guard stays closed
    check(any(s[2] == "reach" and s[3] == "ok" and s[1] == "SECONDARY_ACTIVE" for s in seen), "no waiting phase observed: " + str(seen[:6]))
    # the waiting is explained, not silent: return_wait names the counters while the primary is healthy but not yet selected
    check(any(s[4].startswith("successes:") for s in seen), "return_wait never explained the wait: " + str(seen[:6]))
    check(e.client() == "TUN", "traffic must flow through the tunnel after the return")
    check(open(os.path.join(e.stub, "exit")).read().strip() == P1, "exit node is the primary again")


def s_f06_primary_reachable_only_via_derp_also_returns(e):
    dt, seen = _fail_over_then_heal(e, derp_only=True)
    check(dt is not None, "a DERP-only primary was never taken back: " + str(seen[-3:]))
    check(dt <= 30 + 60 + 40, "the return took %ss" % dt)


def s_f06_auto_return_off_keeps_the_secondary(e):
    e.tsem("config", "set", "TSEM_AUTO_RETURN=0", check_rc=False)
    e.env["TSEM_AUTO_RETURN"] = "0"
    dt, seen = _fail_over_then_heal(e, derp_only=False)
    check(dt is None, "TSEM_AUTO_RETURN=0 must keep the secondary active, but the primary was taken back after %ss" % dt)
    check(e.status()["state"] == "SECONDARY_ACTIVE" and e.status()["auto_return"] == "false", str(e.status()))


def s_f04_selftest_checks_the_hardware_switch_hook(e):
    """F04 (hardware): the RC5 install kept the original prototype hook, so no switch event ever reached tsem."""
    d = os.path.join(e.tmp, "glsw")
    os.makedirs(d)
    hook = os.path.join(d, "tailscale-de.sh")
    e.env["TSEM_GL_SWITCH_DIR"] = d
    with open(hook, "w") as f:
        f.write("#!/bin/sh\n# the old prototype\n")
    os.chmod(hook, 0o755)
    out = e.tsem("selftest").stdout
    check("FAIL hw-hook" in out, "a foreign hook must FAIL the selftest:\n" + out)
    with open(hook, "w") as f:
        f.write(open(os.path.join(ROOT, "contrib/tsem-switch.sh")).read())
    os.chmod(hook, 0o644)
    check("FAIL hw-hook" in e.tsem("selftest").stdout, "a non-executable hook must FAIL (the firmware refuses to run it)")
    os.chmod(hook, 0o755)
    out = e.tsem("selftest").stdout
    check("PASS hw-hook" in out and "FAIL hw-hook" not in out, "the tsem hook, executable, must PASS:\n" + out)


def s_no_hardware_switch_is_a_normal_setup_not_a_failure(e):
    """A router without a toggle button: the selftest passes the switch check; where the button exists but the hook is missing it warns."""
    d = os.path.join(e.tmp, "noglsw")  # directory does not exist: no switch support
    e.env["TSEM_GL_SWITCH_DIR"] = d
    e.env["TSEM_SWITCH_CONF"] = os.path.join(e.tmp, "no-switch-button")
    out = e.tsem("selftest").stdout
    check("PASS hw-switch" in out and "FAIL hw-" not in out, "no switch on the router must not fail the selftest:\n" + out)
    os.makedirs(d)  # the firmware's switch directory exists, but no tsem hook is installed
    out = e.tsem("selftest").stdout
    check("WARN hw-switch" in out and "FAIL hw-" not in out, "a switch without the hook must warn, not fail:\n" + out)


def s_f05_selftest_checks_the_boot_link(e):
    """F05 (hardware): no /etc/rc.d/S18tsem was found, so nothing would start tsem after a reboot. selftest must say so."""
    ini = os.path.join(e.tmp, "initd")
    rcd = os.path.join(e.tmp, "rcd")
    os.makedirs(ini)
    os.makedirs(rcd)
    with open(os.path.join(ini, "tsem"), "w") as f:
        f.write("#!/bin/sh\n")
    os.chmod(os.path.join(ini, "tsem"), 0o755)
    e.env["TSEM_INITD"], e.env["TSEM_RC_D"] = ini, rcd
    out = e.tsem("selftest").stdout
    check("FAIL autostart" in out, "selftest must FAIL without boot links:\n" + out)
    for l in ("S18tsem", "K10tsem"):
        os.symlink(os.path.join(ini, "tsem"), os.path.join(rcd, l))
    out = e.tsem("selftest").stdout
    check("PASS autostart" in out and "FAIL autostart" not in out, "selftest must PASS with both boot links:\n" + out)
    os.remove(os.path.join(rcd, "S18tsem"))
    check("FAIL autostart" in e.tsem("selftest").stdout, "a missing S18 link alone must fail")


def s_router_ntp_exception_can_be_disabled(e):
    e.go_german()
    no_tunnel_route(e)
    e.flag("egress_down_all")
    e.flag("ping_all_down")
    e.tick(14)
    check(e.r_udp(port=123) is None, "TSEM_ALLOW_NTP=0 must close the NTP exception")
    check(e.r_udp(port=67, sport=68) == "WAN", "DHCP stays")


def s_router_underlay_dns_exception_is_opt_in(e):
    e.go_german()
    no_tunnel_route(e)
    e.flag("egress_down_all")
    e.flag("ping_all_down")
    e.tick(14)
    check(e.r_udp(port=53, mark=0x80000) == "DNS-WAN", "TSEM_ALLOW_UNDERLAY_DNS=1 must allow marked DNS")
    check(e.r_udp(port=53) is None, "unmarked DNS must stay blocked even then")


def s_router_own_no_leak_during_transitions(e):
    e.tsem("set", "direct", "--no-wait", check_rc=True)
    m = RouterMonitor(e)
    m.start()
    time.sleep(0.2)
    e.tsem("set", "german", "--no-wait", "--source", "hw", check_rc=True)
    t0 = time.monotonic()
    for _ in range(14):
        e.tick()
        if e.status()["state"] == "PRIMARY_ACTIVE":
            break
    e.flag("egress_down_" + P1)
    for _ in range(16):
        e.tick()
        if e.status()["state"] == "SECONDARY_ACTIVE":
            break
    e.flag("egress_down_all")
    e.flag("ping_all_down")
    e.tick(14)
    no_tunnel_route(e)
    time.sleep(0.3)
    e.flag("egress_down_all", False)
    e.flag("ping_all_down", False)
    e.flag("egress_down_" + P1, False)
    e.tick(16)
    time.sleep(0.2)
    m.stop = True
    m.join()
    check(not m.leaks_since(t0), "router-own WAN leak during transitions: %r" % m.leaks_since(t0)[:3])
    check(m.seen("TUN"), "tunnel never carried router traffic")


def s_router_firewall_reload_is_detected_and_repaired(e):
    e.go_german()
    # fw3 reload: built-in chains are flushed
    e.iptc("-F", "FORWARD")
    e.iptc("-F", "OUTPUT")
    st = e.status()
    check(st["guard"] == "inconsistent" and st["leak_risk"] == "true", "missing OUTPUT/FORWARD hooks must be reported as a leak risk: " + str(st))
    e.tsem("reapply", check_rc=True)
    st = e.status()
    check(st["guard"] == "german" and st["leak_risk"] == "false", str(st))
    no_tunnel_route(e)
    e.flag("egress_down_all")
    check(e.r_udp() is None and e.client() is None, "protection must be back after reapply")


def s_router_out_chain_tamper_is_detected_and_repaired(e):
    e.go_german()
    e.iptc("-I", "TSEM_OUT", "1", "-j", "RETURN")  # someone punches a hole
    check(e.status()["guard"] == "inconsistent", "tampered OUTPUT chain must be detected: " + str(e.status()))
    e.tick(2)
    check(e.status()["guard"] == "german", "tick must repair the OUTPUT chain: " + str(e.status()))
    check("-A TSEM_OUT -j RETURN" not in e.iptc("-S", "TSEM_OUT"), "hole still present")
    # a foreign rule in front of our hook must be pushed back behind it
    e.iptc("-I", "OUTPUT", "1", "-j", "ACCEPT")
    check(e.status()["guard"] == "inconsistent", "foreign rule before our OUTPUT hook must be detected")
    e.tsem("reapply", check_rc=True)
    check(e.iptc("-S", "OUTPUT").splitlines()[1].startswith("-A OUTPUT -j TSEM_OUT"), "OUTPUT hook must be first: " + e.iptc("-S", "OUTPUT"))


def s_router_boot_with_german_intent_closes_router_and_clients(e):
    e.go_german()
    e.iptc("-F")
    e.iptc("-X")
    for prio in (5280, 5290):
        e.ip(e.R, "rule", "del", "iif", "br-lan", "priority", str(prio), check_rc=False)
    e.flag("exit", False)
    e.ip(e.R, "route", "del", "default", "table", "52", check_rc=False)
    subprocess.run(["rm", "-rf", e.env["TSEM_RUN_DIR"]])
    cf = os.path.join(e.stub, "calls")
    n0 = len(open(cf).read().splitlines()) if os.path.exists(cf) else 0
    e.tsem("boot", check_rc=True)  # no probes, no tailscale calls: only the persisted intent
    n1 = len(open(cf).read().splitlines()) if os.path.exists(cf) else 0
    check(n1 == n0, "boot must not call tailscale (it runs before tailscaled is ready)")
    st = e.status()
    check(st["guard"] == "blocked" and st["mode"] == "german" and st["leak_risk"] == "false", str(st))
    check(e.client() is None and e.r_udp() is None and e.r_udp(port=53) is None, "boot with a german intent must close clients AND router")


def s_boot_without_intent_is_blocked_never_direct(e):
    e.go_german()
    e.iptc("-F")
    e.iptc("-X")
    for prio in (5280, 5290):
        e.ip(e.R, "rule", "del", "iif", "br-lan", "priority", str(prio), check_rc=False)
    no_tunnel_route(e)
    os.remove(os.path.join(e.env["TSEM_STATE_DIR"], "intent"))
    subprocess.run(["rm", "-rf", e.env["TSEM_RUN_DIR"]])
    e.tsem("boot", check_rc=True)
    check(e.status()["guard"] == "blocked", str(e.status()))
    check(e.client() is None and e.r_udp() is None, "missing intent must never mean DIRECT")


def s_tailscaled_restart_is_fail_closed_and_recovers(e):
    e.go_german()
    # tailscaled stops: routes and rules vanish
    e.flag("ts_dead")
    no_tunnel_route(e)
    e.ip(e.R, "rule", "del", "priority", "5270", check_rc=False)
    check(e.client() is None and e.r_udp() is None and e.r_udp(port=53) is None, "tailscaled down must not leak (clients or router)")
    e.tick(3)
    check(e.status()["leak_risk"] == "false", str(e.status()))
    check(e.client() is None and e.r_udp() is None, "still closed while tailscaled is down")
    # tailscaled is back: rule 5270 returns, the exit node must be re-proven before german opens
    e.flag("ts_dead", False)
    e.ip(e.R, "rule", "add", "priority", "5270", "lookup", "52")
    for _ in range(20):
        e.tick()
        if e.status()["state"] == "PRIMARY_ACTIVE":
            break
    check(e.status()["state"] == "PRIMARY_ACTIVE" and e.client() == "TUN" and e.r_udp() == "TUN", "must recover after the restart: " + str(e.status()))


def s_firewall_init_failure_is_not_functional(e):
    import shutil
    real = shutil.which("iptables-restore")
    shim = os.path.join(e.tmp, "shim")
    os.makedirs(shim)
    with open(os.path.join(shim, "iptables-restore"), "w") as f:
        f.write('#!/bin/sh\nd=$(cat)\ncase $d in *TSEM_OUT*) echo "shim: cannot load TSEM_OUT" >&2; exit 1 ;; esac\nprintf "%s\\n" "$d" | exec ' + real + ' "$@"\n')
    os.chmod(os.path.join(shim, "iptables-restore"), 0o755)
    old = e.env["PATH"]
    e.env["PATH"] = shim + ":" + old
    e.tsem("set", "german", "--no-wait", "--source", "test")
    for _ in range(8):
        e.tick()
    st = e.status()
    check(st["state"] == "ERROR" and "apply" in st["error"], "failed protection must be an ERROR, not a working exit mode: " + str(st))
    check(st["leak_risk"] == "true", "the incomplete protection must be reported as a leak risk: " + str(st))
    check(e.client() is None and e.client("tcp") is None, "client traffic must stay blocked when the router chain cannot be loaded")
    check(e.status()["state"] != "DISABLED", "never fall back to DIRECT")
    e.env["PATH"] = old  # firewall works again: self-heals
    for _ in range(20):
        e.tick()
        if e.status()["state"] == "PRIMARY_ACTIVE":
            break
    st = e.status()
    check(st["state"] == "PRIMARY_ACTIVE" and st["leak_risk"] == "false", "no self-heal: " + str(st))


# ---- private tailscale subnets behind tailscale0 (remote-site) with fw3 masquerading ----
def extnet_all(e):
    return [e.client("udp", h, 9100) for h in EXTNET], [e.client("tcp", h, 9100) for h in EXTNET]


def block_everything(e):
    e.flag("egress_down_all")
    e.flag("ping_all_down")
    e.tick(14)
    check(e.status()["state"] == "BLOCKED", str(e.status()))


def s_extnet_subnets_reachable_with_masq_in_german_and_blocked(e):
    e.masq(True)
    nat0 = e.nat_post()
    e.go_german()
    u, t = extnet_all(e)
    check(u == ["EXTNET"] * 3 and t == ["EXTNET"] * 3, "GERMAN: LAN -> tailscale0 -> remote-site (SNAT + return path) failed: %r %r" % (u, t))
    block_everything(e)
    check(e.status()["guard"] == "blocked", str(e.status()))
    u, t = extnet_all(e)
    check(u == ["EXTNET"] * 3 and t == ["EXTNET"] * 3, "BLOCKED: explicitly allowed remote-site subnets must stay reachable: %r %r" % (u, t))
    # still no internet and no unlisted private network in BLOCKED
    check(e.client() is None and e.client("tcp") is None, "BLOCKED must still stop internet traffic")
    check(e.client("udp", OTHER_PRIVATE, 9100) is None and e.client("tcp", OTHER_PRIVATE, 9100) is None,
          "a private network that is not in TSEM_ALLOW_SUBNETS4 must stay blocked (no blanket RFC1918 release)")
    check(e.client("udp", "192.168.77.7", 9100) is None and e.client("udp", "172.16.0.9", 9100) is None, "other RFC1918 must stay blocked")
    check(e.status()["leak_risk"] == "false", str(e.status()))
    check(e.nat_post() == nat0, "tsem must not change the fw3 masquerade rules")


def s_extnet_policy_routing_does_not_block_allowed_subnets(e):
    e.masq(True)
    e.go_german()
    rules = e.ip(e.R, "rule", "show").stdout
    check("5280" in rules and "5290" in rules, "policy-routing guard must be active in this test: " + rules)
    block_everything(e)
    rules = e.ip(e.R, "rule", "show").stdout
    check("5290" in rules and "prohibit" in rules, "prohibit rule must still be present in BLOCKED")
    # the lookup of table 52 (prio 5270) wins before the 5280/5290 guard for these destinations
    u, _ = extnet_all(e)
    check(u == ["EXTNET"] * 3, "policy-routing prohibit rule blocked the allowed subnets: %r" % (u,))
    # ... and without the table-52 route the guard blocks them (proves the guard is really in the path)
    for n in EXTNET_NETS:
        e.ip(e.R, "route", "del", n, "table", "52")
    e.ip(e.R, "route", "del", "default", "table", "52", check_rc=False)  # no usable route in table 52 at all (tsem already cleared the exit node in BLOCKED: F01)
    got = e.client("udp", EXTNET[0], 9100)
    check(got is None, "without any table-52 route the traffic must be prohibited, not sent to the WAN: got %r" % (got,))
    check(e.r_udp(EXTNET[0], 9100) is None, "router-own traffic must not leak to the WAN either")


def s_extnet_missing_masquerade_is_detected(e):
    e.masq(False)
    e.go_german()
    check(e.iptc("-t", "nat", "-S", "zone_tailscale0_postrouting").count("MASQUERADE") == 0, "test setup: masquerade must be off")
    u, t = extnet_all(e)
    check(u == [None] * 3 and t == [None] * 3,
          "without SNAT the remote network cannot answer; the test must see that: %r %r" % (u, t))
    e.masq(True)
    u, t = extnet_all(e)
    check(u == ["EXTNET"] * 3 and t == ["EXTNET"] * 3, "with masquerading the same path must work: %r %r" % (u, t))


def s_extnet_blocked_without_allow_config_is_closed(e):
    e.masq(True)
    e.go_german()
    check(extnet_all(e)[0] == ["EXTNET"] * 3, "GERMAN reaches remote-site through the tunnel")
    block_everything(e)
    u, t = extnet_all(e)
    check(u == [None] * 3 and t == [None] * 3, "BLOCKED without TSEM_ALLOW_SUBNETS4 must not reach private subnets: %r %r" % (u, t))


def s_masquerade_untouched_by_state_changes_reload_and_teardown(e):
    e.masq(True)
    nat0 = e.nat_post()
    e.go_german()
    check(e.nat_post() == nat0, "go german changed the masquerade rules")
    block_everything(e)
    check(e.nat_post() == nat0, "BLOCKED changed the masquerade rules")
    e.iptc("-F", "FORWARD")
    e.iptc("-F", "OUTPUT")  # fw3 reload flushes built-in chains (not the zone chains of the nat table)
    e.tsem("reapply", check_rc=True)
    e.tick(2)
    check(e.nat_post() == nat0, "reapply/tick changed the masquerade rules")
    e.tsem("set", "direct", "--no-wait", check_rc=True)
    check(e.nat_post() == nat0, "DIRECT changed the masquerade rules")
    e.flag("egress_down_all", False)
    e.flag("ping_all_down", False)
    e.go_german()
    e.tsem("teardown", check_rc=True)
    check(e.nat_post() == nat0, "teardown (uninstall) changed the masquerade rules")


def _deny_action_scenario(e, action):
    e.env["TSEM_RT_DENY"] = action
    e.go_german()
    rules = e.ip(e.R, "rule", "show").stdout
    check(("5290:" in rules) and action in rules.split("5290:", 1)[1].splitlines()[0], "deny rule must use %s: %s" % (action, rules))
    check(e.status()["guard"] == "german" and e.status()["leak_risk"] == "false", str(e.status()))
    # layer 1 alone must stop the leak with this action too
    e.iptc("-F", "FORWARD")
    e.iptc("-P", "FORWARD", "ACCEPT")
    e.ip(e.R, "route", "del", "default", "table", "52")
    check(e.client("udp") is None and e.client("tcp") is None, "%s deny rule alone must stop the leak" % action)
    check(e.client("udp", "10.20.0.1", 9001) == "ROUTER", "management access must stay")


def s_rc3_deny_unreachable_is_fail_closed(e):
    _deny_action_scenario(e, "unreachable")


def s_rc3_deny_blackhole_is_fail_closed(e):
    _deny_action_scenario(e, "blackhole")


def s_rc3_fastpath_is_unloaded_before_guard_closes(e):
    mods = os.path.join(e.tmp, "modules")
    open(mods, "w").write("nf_conntrack 1 0 - Live 0x0\nshortcut_fe_cm 1 0 - Live 0x0\nshortcut_fe 1 1 shortcut_fe_cm, Live 0x0\n")
    rm = os.path.join(e.tmp, "rmmod")
    open(rm, "w").write('#!/bin/sh\ngrep -v "^$1 " "%s" > "%s.n"; mv "%s.n" "%s"\n' % (mods, mods, mods, mods))
    os.chmod(rm, 0o755)
    e.env.update(TSEM_PROC_MODULES=mods, TSEM_RMMOD=rm, TSEM_FASTPATH="unload")
    e.tsem("set", "direct", "--no-wait", check_rc=True)
    check("shortcut_fe" in open(mods).read(), "direct mode must not touch the fast path")
    e.go_german()
    left = open(mods).read()
    check("shortcut_fe" not in left and "nf_conntrack" in left, "fast path must be removed (and only it): %r" % left)
    check(e.status()["guard"] == "german" and e.status()["leak_risk"] == "false", str(e.status()))
    check(e.client("udp") == "TUN", "tunnel path must work")


def s_rc3_fastpath_refuse_mode_is_reported_as_leak_risk(e):
    mods = os.path.join(e.tmp, "modules")
    open(mods, "w").write("shortcut_fe_cm 1 0 - Live 0x0\n")
    e.env.update(TSEM_PROC_MODULES=mods, TSEM_FASTPATH="refuse")
    e.tsem("set", "german", "--no-wait")
    for _ in range(6):
        e.tick()
    st = e.status()
    check(st["leak_risk"] == "true" and st["guard"] != "german", "a loaded fast path must NOT be reported as protected: %s" % st)
    os.remove(mods)
    e.tick(2)
    check(e.status()["leak_risk"] == "false", "protected once the fast path is gone: %s" % e.status())


def s_rc3_fastpath_unload_failure_is_not_functional(e):
    mods = os.path.join(e.tmp, "modules")
    open(mods, "w").write("shortcut_fe_cm 1 0 - Live 0x0\n")
    rm = os.path.join(e.tmp, "rmmod")
    open(rm, "w").write("#!/bin/sh\nexit 1\n")
    os.chmod(rm, 0o755)
    e.env.update(TSEM_PROC_MODULES=mods, TSEM_RMMOD=rm, TSEM_FASTPATH="unload")
    e.tsem("set", "german", "--no-wait")
    for _ in range(6):
        e.tick()
    st = e.status()
    check(st["leak_risk"] == "true", "unload failure must keep leak_risk=true: %s" % st)
    check(e.client("udp") is None, "LAN must stay blocked while the guard is not verified")


def s_rc3_invalid_intent_boot_is_blocked_and_reasoned(e):
    open(os.path.join(e.env["TSEM_STATE_DIR"], "intent"), "w").write("v=1\nmode=direct\ncrc=bad\n")
    e.tsem("boot")
    st = e.status()
    check(st["intent"] == "invalid" and st["intent_reason"] == "crc-mismatch" and st["guard"] == "blocked", str(st))
    check(e.client("udp") is None and e.client("tcp") is None, "invalid intent must never open the WAN")
    check(e.router_marked() == "WAN", "tailscaled underlay must survive")
    check(e.r_udp() is None, "router-own plain traffic must be blocked too")


SCENARIOS = [v for k, v in sorted(globals().items()) if k.startswith("s_")]
SCENARIOS_DNS = {"s_dns_redirect", "s_dns_redirect_forces_all_client_dns"}
_EXTNET_CONF = {"TSEM_ALLOW_SUBNETS4": " ".join(EXTNET_NETS)}
SCENARIO_CONF = {
    "s_extnet_subnets_reachable_with_masq_in_german_and_blocked": _EXTNET_CONF,
    "s_extnet_policy_routing_does_not_block_allowed_subnets": _EXTNET_CONF,
    "s_extnet_missing_masquerade_is_detected": _EXTNET_CONF,
    "s_router_ntp_exception_can_be_disabled": {"TSEM_ALLOW_NTP": "0"},
    "s_router_underlay_dns_exception_is_opt_in": {"TSEM_ALLOW_UNDERLAY_DNS": "1"},
    "s_f03_without_the_router_dns_redirect_the_isp_resolver_is_unreachable": {"TSEM_DNS_ROUTER": ""},
}


def main():
    if os.geteuid() != 0:
        print("SKIPPED: netns tests need root")
        return 77
    pid = os.fork()
    if pid == 0:  # capability probe in a throw-away child (never unshare the harness itself)
        try:
            os.unshare(NET)
            os._exit(0)
        except Exception:
            os._exit(1)
    if os.waitpid(pid, 0)[1] != 0:
        print("SKIPPED: cannot create network namespaces (need CAP_SYS_ADMIN)")
        return 77
    sel = sys.argv[1:]
    fails = passed = 0
    for fn in SCENARIOS:
        if sel and fn.__name__ not in sel:
            continue
        e = None
        try:
            e = Env(dns_redirect="203.0.113.53" if fn.__name__ in SCENARIOS_DNS else "", extra_conf=SCENARIO_CONF.get(fn.__name__))
            fn(e)
            print("  ok   %s" % fn.__name__)
            passed += 1
        except Fail as x:
            print("  FAIL %s: %s" % (fn.__name__, x))
            fails += 1
        except Exception:
            print("  ERROR %s:\n%s" % (fn.__name__, traceback.format_exc()))
            fails += 1
        finally:
            if e:
                e.close()
    print("%d passed, %d failed (netns, IPv4 only)" % (passed, fails))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
