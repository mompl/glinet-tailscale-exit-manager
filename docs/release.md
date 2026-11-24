# TSEM release: controlled hardware installation (GL-MT3000, firmware 4.11.0)

Status: **READY FOR CONTROLLED HARDWARE INSTALLATION** only in the sense of the table "Verified / not verified" below.
Nothing in this package changes the router, a server or Home Assistant by itself. Every active step needs a phrase typed by you.

## Contents of the release
* `tsem-<version>.tar.gz`: router package (`install.sh`, `uninstall.sh`, `src/`, `contrib/`, `native/`), the Mac acceptance tools (`tools/`),
  docs and tests, `MANIFEST.sha256` (every file), `VERSION`.
* `tsem-ha-<version>.tar.gz`: only the Home Assistant integration (`custom_components/tsem`) and `home-assistant-install.md`.
* `SHA256SUMS`. Build: see "Reproducible build" below.

## Reproducible build
Needs a checkout of the exact commit, `sh`, GNU tar >= 1.28 (`--sort`, `--mtime`), `gzip`, `sha256sum` (or `shasum`). No network access is needed.

    git clone <repo> && cd glinet-tailscale-exit-manager && git checkout <commit>
    git status --porcelain                                   # must print nothing: a package is only valid for a clean tree
    sh tools/build-release.sh --version rc5-$(git rev-parse --short HEAD) --out dist
    (cd dist && sha256sum -c SHA256SUMS)                     # both archives: OK
    sh tools/build-release.sh --version rc5-$(git rev-parse --short HEAD) --out dist2 && cmp dist/SHA256SUMS dist2/SHA256SUMS   # identical: reproducible

The builder copies `src contrib native tools tests docs homeassistant install.sh uninstall.sh README.md LICENSE`, refuses to pack anything
that looks like a credential, parse-checks the shell sources, writes `MANIFEST.sha256` and `VERSION` into the package and builds the
archives with sorted names, fixed mtime/owner and `gzip -n`. Check after extraction: `sha256sum -c MANIFEST.sha256` (no line other than OK).
Via CI instead of a local build: run the same commands in a job of `.gitea/workflows/test.yml` on the commit (the job already provides GNU tar);
the archives are only valid if `sha256sum -c` passes there as well.

## One installation procedure (on the Mac)
Requirements: ssh access to the router as `root` (key login), the router reachable over the LAN **and** over Tailscale (second way in).

    cd ~/Downloads && shasum -a 256 -c SHA256SUMS            # must print OK for both archives
    tar -xzf tsem-<version>.tar.gz && cd tsem-<version>
    sh tools/run-rc3-active-mac.sh --stage "$PWD" accept

What it does, in order (each active step waits for its phrase): read-only preflight (model GL-MT3000, firmware 4.11.0, tools, node
identity) → backup on the router and a verified copy on the Mac (`~/tsem-rc3-active/`) → independent recovery watchdog is armed and
tested → DIRECT return path is proven → journaled install of core, API and LuCI GUI (any failure restores the previous state) → active
tests t00..t08 (GERMAN, primary down, both down = BLOCKED, never WAN) → hardware switch → API/GUI check → report with the
PASS / FAIL / UNVERIFIED matrix. On any FAIL it runs the recovery and leaves the kill switch closed. Optional: `--native-gui`
(native GL.iNet GUI, adds files only), `--ha-url ... --ha-token-file ...` (read-only comparison with Home Assistant).
The installer never starts the service by itself and never touches firewall/masquerading settings outside the TSEM include.

## Hardware acceptance (what you confirm at the router)
1. Report shows every line PASS, no FAIL. Lines that say UNVERIFIED stay open and are not passes.
2. `tsem status` on the router: `mode=german`, state PRIMARY_ACTIVE, exit node `100.64.0.30`.
3. Egress from a LAN client is a German address; remote-site LAN routes still answer.
4. Primary node off (tailscale admin) → within the failover time the exit node is `100.64.0.31`; both off → BLOCKED, LAN client has **no** Internet.
5. Physical switch OFF = DIRECT, ON = GERMAN (the runner asks you to flip it).
6. Reboot the router: the saved mode returns, GERMAN comes back closed (BLOCKED) until a node works, never open.
7. GUI: LuCI (and native GUI if installed) show the same mode as `tsem status`; API without login is refused.
Only after all of this PR #7 may leave Draft.

## Home Assistant (optional, separate)
Follow `docs/home-assistant-install.md` (backup of the HA config, copy `custom_components/tsem`, restart, add integration, acceptance, rollback = delete the folder
and restart). Not covered by the router installer.

## Recovery (verified against the code and the netns/mock suites; not yet run on the router)
See `docs/emergency-recovery.md`. Short form, in an SSH shell on the router (`ssh root@10.20.0.1` from the LAN or over Tailscale):
`tsem status` (look) · `tsem set direct` (open the kill switch on purpose) · `sh install.sh --rollback --yes` (previous version) ·
from the Mac `sh tools/run-rc3-active-mac.sh --stage "$PWD" recover|rollback`. Recovery never opens the kill switch by itself.

## Verified / not verified
| area | state |
|---|---|
| controller, failover, BLOCKED never falls back to WAN, IPv6/DNS guard (mock + IPv4 netns) | tested automatically (see the report of the build) |
| installer: dry run, install, upgrade, rollback, interrupted install, `--root` sandbox | tested automatically |
| API (rpcd, ACL), LuCI/native GUI logic, Lua bridge, HA client and entity logic | tested automatically |
| IPv6 netns packet tests (`tests/netns/netns6_test.py`) | **written, never executed**: needs `tools/run-netns-vm.sh` on the VM `ht-dev` |
| installer/tests on the real GL-MT3000 | **hardware acceptance** |
| native GL.iNet GUI (undocumented interface) | **hardware acceptance**, optional |
| Home Assistant in a real instance | **hardware/HA acceptance** |
