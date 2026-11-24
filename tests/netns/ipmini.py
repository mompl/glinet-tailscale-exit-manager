#!/usr/bin/env python3
"""Minimal `ip` replacement for the test sandbox (no iproute2 installed).

Implements exactly the subset tsem's iptables backend and the netns tests use:
  ip [-4|-6] rule add|del|show ...     ip [-4|-6] route add|replace|del|show ...
  ip link add N type veth peer name P  ip link set DEV up|down|netns PID
  ip addr add CIDR dev DEV
Pure netlink, no external dependencies. NOT part of the product.
"""
import ipaddress
import os
import socket
import struct
import sys

REQ, ACK, DUMP = 1, 4, 0x300
REPLACE, EXCL, CREATE = 0x100, 0x200, 0x400
RTM_NEWLINK, RTM_NEWADDR, RTM_NEWROUTE, RTM_DELROUTE, RTM_GETROUTE = 16, 20, 24, 25, 26
RTM_NEWRULE, RTM_DELRULE, RTM_GETRULE = 32, 33, 34
TABLES = {"main": 254, "local": 255, "default": 253}
RTABLES = {v: k for k, v in TABLES.items()}


def attr(t, d):
    n = 4 + len(d)
    return struct.pack("HH", n, t) + d + b"\0" * ((4 - n % 4) % 4)


def u32(v):
    return struct.pack("I", v)


def nl(mtype, flags, payload):
    s = socket.socket(socket.AF_NETLINK, socket.SOCK_RAW, 0)
    s.bind((0, 0))
    s.send(struct.pack("IHHII", 16 + len(payload), mtype, flags | REQ | ACK if not flags & DUMP == DUMP else flags | REQ, 1, 0) + payload)
    out = []
    while True:
        data = s.recv(65536)
        off = 0
        while off < len(data):
            ln, t, fl, _, _ = struct.unpack_from("IHHII", data, off)
            body = data[off + 16: off + ln]
            if t == 2:  # NLMSG_ERROR
                err = struct.unpack_from("i", body)[0]
                if err:
                    s.close()
                    raise OSError(-err, os.strerror(-err))
                s.close()
                return out
            if t == 3:  # DONE
                s.close()
                return out
            out.append((t, body))
            off += (ln + 3) & ~3
        if not flags & DUMP == DUMP:
            pass


def parse_attrs(b):
    d, off = {}, 0
    while off + 4 <= len(b):
        n, t = struct.unpack_from("HH", b, off)
        if n < 4:
            break
        d[t & 0x7FFF] = b[off + 4: off + n]
        off += (n + 3) & ~3
    return d


def tid(v):
    return TABLES[v] if v in TABLES else int(v)


def ifindex(name):
    return socket.if_nametoindex(name)


def fam_of(addr):
    return socket.AF_INET6 if ":" in addr else socket.AF_INET


def pack_ip(addr):
    return socket.inet_pton(fam_of(addr), addr)


# ------------------------------------------------------------------ rule
def rule_args(args):
    r = dict(src=None, dst=None, iif=None, oif=None, prio=None, mark=None, mask=None, table=None, suppress=None, action=None)
    i = 0
    while i < len(args):
        a = args[i]
        if a == "from":
            r["src"] = args[i + 1]; i += 2
        elif a == "to":
            r["dst"] = args[i + 1]; i += 2
        elif a == "iif":
            r["iif"] = args[i + 1]; i += 2
        elif a == "oif":
            r["oif"] = args[i + 1]; i += 2
        elif a in ("priority", "prio", "pref", "preference"):
            r["prio"] = int(args[i + 1]); i += 2
        elif a == "fwmark":
            v = args[i + 1].split("/")
            r["mark"] = int(v[0], 0); r["mask"] = int(v[1], 0) if len(v) > 1 else 0xFFFFFFFF; i += 2
        elif a in ("lookup", "table"):
            r["table"] = tid(args[i + 1]); r["action"] = 1; i += 2
        elif a == "suppress_prefixlength":
            r["suppress"] = int(args[i + 1]); i += 2
        elif a in ("prohibit", "blackhole", "unreachable"):
            r["action"] = {"blackhole": 6, "unreachable": 7, "prohibit": 8}[a]; i += 1
        else:
            raise SystemExit("ip: unsupported rule argument: " + a)
    return r


def rule_msg(fam, r, add):
    src_len = dst_len = 0
    attrs = b""
    if r["src"] and r["src"] != "all":
        n = ipaddress.ip_network(r["src"], strict=False)
        src_len = n.prefixlen
        attrs += attr(2, pack_ip(str(n.network_address)))
    if r["dst"] and r["dst"] != "all":
        n = ipaddress.ip_network(r["dst"], strict=False)
        dst_len = n.prefixlen
        attrs += attr(1, pack_ip(str(n.network_address)))
    if r["iif"]:
        attrs += attr(3, r["iif"].encode() + b"\0")
    if r["oif"]:
        attrs += attr(17, r["oif"].encode() + b"\0")
    if r["prio"] is not None:
        attrs += attr(6, u32(r["prio"]))
    if r["mark"] is not None:
        attrs += attr(10, u32(r["mark"])) + attr(16, u32(r["mask"]))
    if r["suppress"] is not None:
        attrs += attr(14, u32(r["suppress"]))
    table = 0
    if r["table"] is not None:
        table = r["table"] if r["table"] < 256 else 252
        attrs += attr(15, u32(r["table"]))
    action = r["action"] or 0
    if add and not action:
        raise SystemExit("ip: rule needs lookup/prohibit/...")
    hdr = struct.pack("BBBBBBBBI", fam, dst_len, src_len, 0, table, 0, 0, action, 0)
    return hdr + attrs


def rule_show(fam):
    msgs = nl(RTM_GETRULE, DUMP, struct.pack("BBBBBBBBI", fam, 0, 0, 0, 0, 0, 0, 0, 0))
    rows = []
    for _, b in msgs:
        h = struct.unpack_from("BBBBBBBBI", b)
        a = parse_attrs(b[12:])
        prio = struct.unpack("I", a[6])[0] if 6 in a else 0
        src = "all"
        if 2 in a:
            src = socket.inet_ntop(fam, a[2]) + ("/%d" % h[2] if h[2] else "")
        parts = ["from " + src]
        if 1 in a:
            parts.append("to " + socket.inet_ntop(fam, a[1]) + "/%d" % h[1])
        if 3 in a:
            parts.append("iif " + a[3].rstrip(b"\0").decode())
        if 10 in a:
            m = struct.unpack("I", a[10])[0]
            mk = struct.unpack("I", a[16])[0] if 16 in a else 0xFFFFFFFF
            parts.append("fwmark 0x%x/0x%x" % (m, mk) if mk != 0xFFFFFFFF else "fwmark 0x%x" % m)
        act = h[7]
        if act == 1:
            t = struct.unpack("I", a[15])[0] if 15 in a else h[4]
            parts.append("lookup " + RTABLES.get(t, str(t)))
        else:
            parts.append({6: "blackhole", 7: "unreachable", 8: "prohibit"}.get(act, "action%d" % act))
        if 14 in a and struct.unpack("I", a[14])[0] != 0xFFFFFFFF:
            parts.append("suppress_prefixlength %d" % struct.unpack("I", a[14])[0])
        rows.append((prio, "%d:\t%s" % (prio, " ".join(parts))))
    for _, line in sorted(rows, key=lambda x: x[0]):
        print(line)


# ----------------------------------------------------------------- route
def route_args(args):
    r = dict(dst="default", gw=None, dev=None, table=254, metric=None, src=None)
    r["dst"] = args[0]
    i = 1
    while i < len(args):
        a = args[i]
        if a == "via":
            r["gw"] = args[i + 1]; i += 2
        elif a == "dev":
            r["dev"] = args[i + 1]; i += 2
        elif a == "table":
            r["table"] = tid(args[i + 1]); i += 2
        elif a == "metric":
            r["metric"] = int(args[i + 1]); i += 2
        elif a == "src":
            r["src"] = args[i + 1]; i += 2
        elif a == "onlink":
            i += 1
        else:
            raise SystemExit("ip: unsupported route argument: " + a)
    return r


def route_msg(fam, r, add):
    dst = r["dst"]
    if dst == "default":
        plen, daddr = 0, None
    else:
        n = ipaddress.ip_network(dst, strict=False)
        plen, daddr = n.prefixlen, str(n.network_address)
        fam = socket.AF_INET6 if n.version == 6 else socket.AF_INET
    attrs = b""
    if daddr:
        attrs += attr(1, pack_ip(daddr))
    if r["dev"]:
        attrs += attr(4, u32(ifindex(r["dev"])))
    if r["gw"]:
        attrs += attr(5, pack_ip(r["gw"]))
    if r["src"]:
        attrs += attr(7, pack_ip(r["src"]))
    if r["metric"] is not None:
        attrs += attr(6, u32(r["metric"]))
    t = r["table"]
    attrs += attr(15, u32(t))
    scope = 0 if r["gw"] else 253
    proto = 3 if add else 0
    rtype = 1 if add else 0
    # like iproute2: delete uses scope NOWHERE so it matches any scope
    hdr = struct.pack("BBBBBBBBI", fam, plen, 0, 0, t if t < 256 else 252, proto, scope if add else 255, rtype, 0)
    return fam, hdr + attrs


# ------------------------------------------------------------------ main
def main(argv):
    fam = None
    while argv and argv[0] in ("-4", "-6", "-family"):
        if argv[0] == "-4":
            fam = socket.AF_INET
        elif argv[0] == "-6":
            fam = socket.AF_INET6
        argv = argv[1:]
    if not argv:
        raise SystemExit("usage: ip OBJECT ...")
    obj, rest = argv[0], argv[1:]
    f = fam or socket.AF_INET
    if obj == "rule":
        cmd = rest[0] if rest else "show"
        if cmd in ("show", "list", "ls"):
            rule_show(f)
        elif cmd == "help":
            print("Usage: ip rule { add | del } SELECTOR ACTION\nSELECTOR := [ from PREFIX ] [ to PREFIX ] [ iif STRING ] [ oif STRING ] [ priority NUMBER ] [ fwmark MARK[/MASK] ]\n"
                  "ACTION := [ table TABLE_ID ] [ suppress_prefixlength NUMBER ]\nTYPE := { prohibit | blackhole | unreachable }")
        elif cmd == "add":
            nl(RTM_NEWRULE, CREATE | EXCL, rule_msg(f, rule_args(rest[1:]), True))
        elif cmd in ("del", "delete"):
            nl(RTM_DELRULE, 0, rule_msg(f, rule_args(rest[1:]), False))
        else:
            raise SystemExit("ip: unsupported rule command " + cmd)
    elif obj == "route":
        cmd = rest[0]
        if cmd in ("add", "replace"):
            ff, m = route_msg(f, route_args(rest[1:]), True)
            nl(RTM_NEWROUTE, CREATE | (REPLACE if cmd == "replace" else EXCL), m)
        elif cmd in ("del", "delete"):
            ff, m = route_msg(f, route_args(rest[1:]), False)
            nl(RTM_DELROUTE, 0, m)
        elif cmd in ("show", "list"):
            tbl = 254
            if "table" in rest:
                tbl = tid(rest[rest.index("table") + 1])
            for _, b in nl(RTM_GETROUTE, DUMP, struct.pack("BBBBBBBBI", f, 0, 0, 0, 0, 0, 0, 0, 0)):
                h = struct.unpack_from("BBBBBBBBI", b)
                a = parse_attrs(b[12:])
                t = struct.unpack("I", a[15])[0] if 15 in a else h[4]
                if t != tbl:
                    continue
                d = (socket.inet_ntop(f, a[1]) + "/%d" % h[1]) if 1 in a else "default"
                line = d
                if 5 in a:
                    line += " via " + socket.inet_ntop(f, a[5])
                if 4 in a:
                    line += " dev " + socket.if_indextoname(struct.unpack("I", a[4])[0])
                print(line)
        else:
            raise SystemExit("ip: unsupported route command " + cmd)
    elif obj == "addr":
        assert rest[0] == "add" and rest[2] == "dev", "ip addr add CIDR dev DEV"
        n = ipaddress.ip_interface(rest[1])
        fa = socket.AF_INET6 if n.version == 6 else socket.AF_INET
        pk = pack_ip(str(n.ip))
        body = struct.pack("BBBBI", fa, n.network.prefixlen, 0, 0, ifindex(rest[3])) + attr(2, pk) + attr(1, pk)
        nl(RTM_NEWADDR, CREATE | EXCL, body)
    elif obj == "link":
        if rest[0] == "add":
            name = rest[1]
            assert rest[2:5] == ["type", "veth", "peer"] and rest[5] == "name"
            ifi = struct.pack("BBHiII", 0, 0, 0, 0, 0, 0)
            info = attr(1, b"veth\0") + attr(2, attr(1, ifi + attr(3, rest[6].encode() + b"\0")))
            nl(RTM_NEWLINK, CREATE | EXCL, ifi + attr(3, name.encode() + b"\0") + attr(18, info))
        elif rest[0] in ("show", "list"):
            if len(rest) > 1:
                dev = rest[-1]
                ifindex(dev)  # OSError -> rc 2 when the device does not exist
                print("%d: %s" % (ifindex(dev), dev))
            else:
                for i, n in socket.if_nameindex():
                    print("%d: %s" % (i, n))
        elif rest[0] == "set":
            dev = rest[1]
            idx = ifindex(dev)
            ifi_up = struct.pack("BBHiII", 0, 0, 0, idx, 1, 1)
            ifi_dn = struct.pack("BBHiII", 0, 0, 0, idx, 0, 1)
            if rest[2] == "up":
                nl(RTM_NEWLINK, 0, ifi_up)
            elif rest[2] == "down":
                nl(RTM_NEWLINK, 0, ifi_dn)
            elif rest[2] == "netns":
                nl(RTM_NEWLINK, 0, struct.pack("BBHiII", 0, 0, 0, idx, 0, 0) + attr(19, u32(int(rest[3]))))
            else:
                raise SystemExit("ip: unsupported link set " + rest[2])
        else:
            raise SystemExit("ip: unsupported link command")
    else:
        raise SystemExit("ip: unsupported object " + obj)


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except OSError as e:
        sys.stderr.write("RTNETLINK answers: %s\n" % e.strerror)
        sys.exit(2)
