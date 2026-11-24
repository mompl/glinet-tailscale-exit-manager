# Native GL.iNet GUI (APPLICATIONS > Tailscale Exit Manager)

Status: **the MAIN GUI, part of the default install; not verified on real firmware.** LuCI (`luci-gui`) is installed next to it as the fallback.

## 1. What the investigation found (public sources only; nothing was run on the router)

| question | result | evidence |
|---|---|---|
| Frontend | The GL.iNet 4.x admin panel is the proprietary "OUI" (Vue 2 single-page app, runtime-only build), **not** LuCI | community packages describe a "native OUI panel" next to LuCI; GL.iNet staff call UI edits unsupported |
| Menu entries | JSON files in `/usr/share/oui/menu.d/*.json`, read on every menu request (no restart) | community package READMEs; a forum recipe adds an entry under APPLICATIONS with `parent`, `parent_icon`, `parent_index`, `level`, `index`, `view`, `title`, `show_mode` |
| View | `/www/views/gl-sdk4-ui-<view>.common.js(.gz)`; the loader evaluates the file and the result must be the Vue component object | community package READMEs (one of them has a contract test) |
| Backend | Lua RPC objects in `/usr/lib/oui-httpd/rpc/<object>`, loaded lazily; browser calls `POST /rpc` with `[sid, object, method, args]` | community package READMEs |
| Supported plugin interface? | **No official, documented interface.** The 4.x API documentation is closed | GL.iNet docs; staff statements |
| Without touching firmware core files? | **Yes, additive:** new files in those three directories, no existing file is edited | community packages do exactly this; this component does the same |
| Firmware upgrade | Not documented. Files outside the keep lists are the firmware's version after an upgrade (the component must be reinstalled); the UI may cache bundles (hard refresh) | community reports; the preflight reports the router's keep lists |
| Package-manager clash | A firmware release started shipping a file a community package also installed ("file clashes") | forum thread on 4.7 |
| Reported failure | One forum recipe was reported (no staff answer) to break admin login; so a bad file in these directories can hurt the UI | forum thread |

Conclusion: native integration is possible **without patching any firmware file**, but through an interface GL.iNet does not
document. Because of that the installer treats it with care. It is part of the **default install** (decision of the owner: the GUI belongs under APPLICATIONS in the GL.iNet UI, LuCI is secondary):

* A default `install.sh` installs it when the firmware layout is there; otherwise it is **skipped with the reason** and everything else is installed. `--no-native-gui` opts out.
* Named explicitly (`--components native-gui`) it is **refused** unless `--accept-undocumented-native-gui` is given.
* It is refused (nothing changed) when `/usr/share/oui/menu.d`, `/usr/lib/oui-httpd/rpc`, `/www/views`, `gzip`, `jsonfilter` or the
  `api` component are missing, when no Tailscale menu entry exists to copy `parent/level/icon/mode` from, or when a file with
  one of the target names exists that tsem did not install.
* It never edits, replaces or deletes a GL.iNet file and never restarts nginx. If anything fails, the journaled installer rolls back.
* No riskier fallback method exists. If native integration cannot be installed, LuCI is the GUI.

## 2. Files (all new)

| file | purpose |
|---|---|
| `/usr/share/oui/menu.d/tsem.json` | generated at install time from the Tailscale entry: same parent/icon/level/mode, `view: tsem`, `index` = Tailscale's + 1 (`--native-index N` overrides) |
| `/www/views/gl-sdk4-ui-tsem.common.js` and `.gz` | the view (generated from `native/tsem-view.js` + `tsem/logic.js`, checked for drift by the tests) |
| `/usr/lib/oui-httpd/rpc/tsem` | Lua bridge: whitelisted methods, validated parameters, forces `source=gui`, calls `/usr/libexec/rpcd/tsem` |

No business logic is duplicated: the sentences (what is *reached*, what is only *requested*, probe wording, EN/DE texts) come from
`src/www/luci-static/resources/tsem/logic.js`, used by both UIs; every decision is the controller's, behind the one API.

## 3. Security model

* **Authentication:** whatever `oui-httpd` enforces for every RPC object (GL.iNet admin session). tsem never reads or checks a
  session itself and never bypasses GL.iNet authentication. *UNVERIFIED:* that a newly added object is refused without a session
  (the acceptance sends an unauthenticated DIRECT request and requires refusal and an unchanged mode).
* **Authorization:** GL.iNet has one administrator; there is no separate read/write role here (LuCI keeps `tsem-read`/`tsem-write`).
* **CSRF:** the session id travels in the JSON body, not as an automatically sent cookie; the request is `application/json` with the
  custom header `glinet: 1`, so a foreign page cannot send it without a CORS preflight. *Not independently verified on the firmware.*
* **DIRECT** needs `confirm: true` (the bridge passes only the boolean `true`; the plugin refuses otherwise) and the view asks first.
* **No WAN surface:** no port, no daemon; the preflight reports which web ports listen on all addresses so the WAN input rules can be reviewed.
* **No secrets:** diagnostics contain none (tested); nothing is put in URLs.
* **Success only after the controller's status:** the view shows *requested* and then the status read after the change; it polls until settled.

## 4. What is still UNVERIFIED (the read-only preflight, section 12, and the acceptance decide)

1. The session-id source the view uses (cookie `Admin-Token`): preflight greps the stock Tailscale view for `Admin-Token`, `/rpc`, `glinet`, `"call"`.
2. The Lua module shape and `cjson` availability: preflight compares with the stock `rpc/tailscale` object. No Lua interpreter exists in the test environment: the bridge is only statically checked (whitelist equals the API plugin's methods).
3. Whether a new RPC object is protected by the session check and how `oui-httpd` hands parameters to it.
4. Rendering in the real GL.iNet UI (desktop and phone), menu position, behaviour after a firmware upgrade.
5. After a firmware upgrade the native files are the firmware's version again unless they are kept: reinstall `native-gui` (the installer is repeatable).

## 5. Not built (needs a decision; not in the controller's data today)

* **A selectable BLOCKED mode.** BLOCKED is today the fail-closed *state* GERMAN falls into; a user-selectable mode is a new controller intent that changes the failover state machine and the hardware-switch semantics. It is shown, not selectable.
* **Public IP and exit-node country, DERP versus direct path, "last leak check" as a stored result, watchdog/recovery status, editing of failover intervals/timeouts/subnets.** The controller does not measure or expose these; editing the subnets or timings would be a new write path into the kill switch. Failover parameters and allowed subnets are shown read-only (`config_get.params`).

## 6. Uninstall and update

`install.sh` is repeatable; `uninstall.sh` removes exactly the files recorded in the manifest (menu entry, view, `.gz`, bridge), so no
broken menu entry remains; GL.iNet files are never touched. `--rollback` undoes only the last install.
