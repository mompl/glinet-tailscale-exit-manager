# TSEM router GUI (LuCI)

A small LuCI view: **Services → Tailscale Exit Manager**. It talks only to the local API (`docs/api.md`) with the
LuCI session; it has no state and no logic of its own beyond turning the controller's status into sentences.

**Requirement:** LuCI (`luci-base`) on the router. The GL.iNet firmware's own UI is not extensible in a supported way,
so this GUI lives in LuCI. Whether the GL-MT3000 firmware 4.11.0 ships LuCI (or on which port) is **UNVERIFIED** until
the final acceptance; the installer installs the files regardless and the acceptance reports `mac.gui.served`.

What it shows (all from `tsem status`, polled every 5 s):

* **Desired mode** (GERMAN / DIRECT / none) and **actually reached**: reached is `yes` only when the controller reports an
  active, verified state. `CONNECTING_*`, `DEGRADED` and `BLOCKED` are shown as *not reached*, with the reason.
* Active exit node, primary/secondary with the kind of evidence behind their state (`Internet through this node works
  (verified)` vs `reachable (ping only)` vs `unreachable`/`rejected`).
* Kill switch, IPv6 and DNS protection (claimed only when the firewall guard is verified), leak risk, last error, boot failure.
* Failover policy, automatic return, hardware switch (**last position reported by the firmware since boot**, shown as
  such, plus whether it matches the mode), last mode change with its source.
* Event log (live) and diagnostics (on demand).

What you can do: switch to GERMAN, switch to DIRECT (confirmation dialog; it turns the kill switch off), fail over now,
pick primary/secondary from the tailnet's online exit-node peers (configured IPs stay selectable), toggle failover and
automatic return. After every action the page shows *Requested … – Result: …* from the status read after the change and keeps
refreshing while the controller is still verifying. Refusals and errors are shown as such.

Languages: English and German (browser/LuCI language).


## Native GL.iNet GUI

The `native-gui` component (menu entry under APPLICATIONS, installed by default) is the main GUI and is described in `docs/native-gui.md`. This LuCI view is the fallback and shares its logic (`tsem/logic.js`) with it.
