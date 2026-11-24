# TSEM local API (ubus object `tsem`)

One API, three clients: the router GUI (LuCI), Home Assistant and scripts. The hardware switch uses the same
controller (`tsem set ... --source hw`). Nothing else changes modes, firewall rules or exit nodes.

* Implemented as an **rpcd exec plugin** (`/usr/libexec/rpcd/tsem`). No extra daemon, no extra port: it is
  reachable through the web server that already serves `/ubus` (uhttpd/LuCI) on the **LAN** only.
* **Authentication and authorization are rpcd's** (ubus session + ACL file `/usr/share/rpcd/acl.d/tsem.json`).
  The plugin contains no security logic of its own, only strict input validation (no value is ever interpolated
  into a shell command).
* ACL groups: `tsem-read` (status, config_get, nodes, events, diag) and `tsem-write` (read + set_mode,
  set_failover, failover_now, config_set). The default `root` login of rpcd has `*` and can do both.
  A dedicated login (optional, needs a system user with a password):

      config login
          option username 'tsem'
          option password '$p$tsem'
          list read 'tsem-read'
          list write 'tsem-write'

* Unauthenticated sessions can call nothing of `tsem`. `tsem-api-check` (on the router) and the final
  acceptance verify this (unauthenticated read and a harmless unauthenticated write must be refused).
* **No WAN exposure:** the installer opens no port and changes no firewall zone. `tsem-api-check` inspects
  `zone_wan_input` and reports FAIL if WAN traffic to the web port is accepted (UNVERIFIED if it cannot tell).

## Methods

| method | needs | request | answer |
|---|---|---|---|
| `status` | read | – | `{"ok":true,"status":{…}}` = `tsem status --json` |
| `config_get` | read | – | primary/secondary (+names), `auto_return`, `failover` |
| `nodes` | read | – | exit-capable tailnet peers with `online`, `exit_option`, `role` |
| `events` | read | – | recent `tsem` log lines |
| `diag` | read | – | `tsem diag` text (lines) |
| `set_mode` | write | `{"mode":"german\|direct","source":"gui\|ha\|api","confirm":true}` | `requested`, `rc`, `message`, `status` **read after the change** |
| `set_failover` | write | `{"mode":"auto\|off","source":…}` | same |
| `failover_now` | write | – | same; `code:"refused"` if the other node is not usable |
| `config_set` | write | any of `primary, primary_name, secondary, secondary_name, auto_return` | `config` + `status` |

Rules:

* `direct` needs `"confirm":true` (it switches the kill switch off). Without it: `code:"confirmation_required"`,
  nothing changes. There is **no automatic transition from german/blocked to direct** anywhere.
* A reply to a change always carries the status read **afterwards**. Clients show *requested* and *reached*
  separately: `german` is only reached when `state` is `PRIMARY_ACTIVE`/`SECONDARY_ACTIVE`.
* Errors: `{"ok":false,"code":…,"error":…}` with codes `invalid_argument`, `confirmation_required`, `refused`,
  `backend`, `not_found`. Invalid configuration is rejected before anything is written
  (`tsem config set` validates, writes atomically, keeps a `.bak`, and resets the node verification **without**
  ever opening the guard).
* Every change is logged by the controller with its source (`set german requested by source=gui …`), the API
  adds no second log. `source` values are limited to `gui`, `ha`, `api`; `hw` is reserved for the switch hook.
* Concurrent changes are serialized by the controller's lock; the last writer wins and the intent file is never
  half written.

## Examples

    ubus call tsem status
    ubus call tsem set_mode '{"mode":"german","source":"api"}'
    curl -s -d '{"jsonrpc":"2.0","id":1,"method":"call","params":["<session>","tsem","status",{}]}' http://ROUTER/ubus


## `config_get`: read-only parameters

`config_get` also returns `params` (`interval`, `interval_recovery`, `fail_n`, `up_n`, `return_n`, `dwell`, `backoff_min`, `backoff_max`, `probe_timeout`, `allow_subnets4`). They are shown by both UIs and cannot be changed through the API.

## Native GL.iNet GUI bridge

The `native-gui` component adds a Lua RPC object `tsem` (method `call`, arguments `{m: method, p: params}`) that forwards the methods above, with strict parameter validation and `source=gui`, to this plugin. Authentication is the GL.iNet session; see `docs/native-gui.md`.
