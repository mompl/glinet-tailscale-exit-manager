# Discovery-Collector (rein lesend)

Sammelt in **einem Durchgang** alle Fakten, die für `glinet-tailscale-exit-manager` gebraucht werden (Firewall, Tailscale, Schalter, Tools, Boot, Routing, WAN-Sperren, GL.iNet-Konflikte, Home-Assistant-Voraussetzungen, Kill-Switch-Fakten). Gedacht für GL-MT3000 und GL-MG1300.

## Einzige Vorgehensweise (pro Router, auf dem Mac)

```sh
git clone <repo> && cd glinet-tailscale-exit-manager   # bzw. Branch feat/discovery-collector auschecken
sh tools/run-collector.sh root@<ROUTER-IP> mt3000      # danach: ... root@<IP> mg1300
# optional, nur wenn die Schalter-Skripte im Volltext gebraucht werden:
# sh tools/run-collector.sh root@<ROUTER-IP> mt3000 --full-scripts
```

Ergebnis: `~/glinet-discovery/<name>-<zeit>.txt` (Modus 600, Ordner 700). Das Skript fragt ggf. nach dem SSH-Passwort. Es installiert **nichts** auf dem Router: `collect.sh` wird per `ssh … 'sh -s' < collect.sh` über stdin ausgeführt, der Bericht kommt über stdout zurück (kein scp/SFTP nötig, Dropbear genügt).

**Vor dem ersten Lauf bitte `tools/collect.sh` lesen** (ca. 700 Zeilen, nur lesende Befehle). Die SHA-256 des Collectors wird beim Start ausgegeben.

## Sicherheitsgarantien (durch Tests abgesichert, `tools/test-collect.sh`)

**Rein lesend:** kein `iptables -A/-F/…`, kein `uci set/commit`, kein `tailscale up/set`, kein `ip … add/del`, keine Init-Skript-Aufrufe, kein `opkg install/update`, kein Netzwerkverkehr (kein ping/curl), keine Tailscale-State-Dateien.

**Datenschutz: Allowlist zuerst, Maskierung nur als Sicherheitsnetz.**

- Prozesse: nur Namen (aus `/proc/*/comm`), nie Argumente; `tailscaled` nur Allowlist-Flags (`--state`, `--socket`, `--port`, `--tun` …), nie `--auth-key`.
- Systemlog: kein Rohlog, nur Ereignistypen (netifd up/down, Firewall-Reload, procd Start/Stop) und bei Tailscale Zeit/Programm ohne Meldungstext.
- procd-Dienste: nur Name und running/stopped (keine Kommandozeilen, keine Umgebungsvariablen).
- Skripte (init.d, hotplug, firewall.user, rc.local, cron, gl-switch.d): Metadaten (Größe, Zeilen, SHA-256) plus Zeilen mit relevanten Befehlen; Zeilen mit Wörtern wie pass/token/key/auth/user werden unterdrückt und gezählt. Volltext nur für `/etc/gl-switch.d`, `/etc/hotplug.d/button|switch`, `/etc/rc.button` und nur mit `--full-scripts` (dann weiterhin maskiert).
- `uci`: Schlüssel-Allowlists für network, wireless (keine SSIDs/Keys), dhcp (keine statischen Leases), system, tailscale; GL-Configs nur Schlüsselnamen plus Allowlist-Werte.
- Nachbartabelle: nur Zustandszähler, keine Client-Adressen. dnsmasq: nur Direktiven-Allowlist.
- Maskierung zusätzlich: `tskey-…`, Private/Node-Keys, PEM-Blöcke, Bearer/Authorization, URL-Credentials, Base64-Schlüssel, MACs, E-Mails, `*.ts.net`, `*.glddns.com`, SSIDs.
- Leak-Check auf dem Router **und** auf dem Mac (nur Zähler auf stderr, nie Inhalte); bei Treffer wird der Bericht gelöscht (Exit 3).
- Beides ist **keine Sicherheitsgarantie.** Bitte den Bericht vor dem Weitergeben einmal lesen. Interne IPs, Hostnamen und Tailscale-IPs bleiben absichtlich sichtbar.

**Fehlererkennung / Vollständigkeit.**

- Fehlgeschlagene Diagnosebefehle erscheinen im Bericht als `!! failed rc=N: <befehl>` (inkl. Fehlertext), fehlende Werkzeuge als `!! n/a: <tool>`.
- Jeder Abschnitt endet mit `# [ID] status=ok|partial issues=… na=… lines=… truncated=…`. Gekürzte Abschnitte (Zeilenlimit) sind `partial`.
- `## SUMMARY` nennt `completeness=complete|partial|incomplete` und listet alle Abschnitte mit Problemen. `incomplete` heißt: ein Abschnitt hat keinen Status (z. B. Abbruch).
- `## END lines=N sha256=H`: Zeilenzahl und Hash des Berichts. `run-collector.sh` prüft beides, die Abschnittszahlen und die SUMMARY. Ein END-Marker allein reicht nicht.
- Exit-Codes von `run-collector.sh`: 0 vollständig, **4 gespeichert, aber partiell** (betroffene Abschnitte werden ausgegeben), 1 unvollständig/beschädigt (nichts gespeichert), 3 Leak-Treffer, 2 Aufruf.
- Hat der Router kein `sha256sum`, warnt das Skript, dass die Übertragung nicht verifiziert ist.

**Ressourcenbegrenzung (GL-MT3000, GL-MG1300).**

- Kein rekursives `grep`; Suchläufe nur über `find` in relevanten Verzeichnissen (`/etc/init.d`, `/etc/hotplug.d`, `/etc/gl-switch.d`, `/etc/firewall.d`, `/etc/rc.button`, `/lib/firewall`, `/usr/share/firewall`, `gl*` in `/usr/bin|sbin`), nur reguläre Dateien unter 64 KB, höchstens 500 Dateien, höchstens 100 Treffer.
- Externe Befehle laufen mit `nice -n 19` und `timeout 30` (soweit vorhanden; `timeout SECS` und `timeout -t SECS` werden erkannt). Zeilenlimits pro Abschnitt. Scratch-Datei nur im tmpfs, Modus 600, wird per Trap gelöscht.
- Der Lauf dauert auf dem Testrechner unter 1 s; auf dem Router bitte die Dauer notieren.

**stdin / `sh -s`.** `main` ist der letzte Befehl des Skripts und setzt als Erstes `exec </dev/null`. Ein abgeschnittenes Skript führt nichts aus; kein Werkzeug kann Skripttext von stdin lesen. Getestet mit dash, bash und BusyBox ash, auch mit langsamem, stückweise gesendetem Skript.

## Berichtsformat

Abschnitte `## [ID] Titel` mit Statuszeile, am Ende `## SUMMARY`, `## INDEX` und `## END lines=N sha256=H`. Zeilenlimits pro Abschnitt (300, Firewall 1200) sind markiert (`[... truncated ...]`).

| ID | Inhalt |
|---|---|
| 00 | Modell, Firmware, OpenWrt, Architektur, Ressourcen |
| 01a–k | Netfilter-Tools, `iptables-save -c` v4/v6 (filter/nat/mangle/raw), Kettenübersicht und Reihenfolge, fw3-Config, Includes/Hooks, ipset/conntrack, sysctl, Module/Kernel-Config |
| 02a–g | Tailscale: Prozesse, Status, Exit-Nodes, Prefs, DNS, Interface, Init-Skript, Aufrufer von `tailscale set` |
| 03a–d | `/etc/gl-switch.d` (Prototyp), Button-Hotplug, GPIO/Input, ubus |
| 04a–d | Befehlsverfügbarkeit (flock, ipset, *-restore …), BusyBox-Applets, Feature-Proben, opkg |
| 05a–g | Boot-Reihenfolge (rc.d, START/STOP), Init-Skripte, rc.local/cron, Hotplug, procd, Boot-Log |
| 06a–j | Interfaces, Adressen, Routen aller Tabellen, Policy-Routing, Route-Lookups, Bridges, netifd, uci, DNS |
| 07a–c | Regeln für Einzelgeräte (MAC/ipset/REJECT), GL-Zugriffskontrolle |
| 08a–d | GL-Weboberfläche/RPC, VPN-Configs (nur Schlüsselnamen), Tunnel |
| 09a–e | Dienste/Ports, MQTT/TLS-Voraussetzungen, Zeit, Speicher |
| 10 | Abgeleitete Fakten für den Fail-closed-Kill-Switch (nur Fakten) |

## Danach

Beide Berichte hochladen/einfügen (nach dem Lesen). Daraus werden D1–D11 mit echten Gerätedaten bewertet. Es werden keine produktiven Firewall-Regeln implementiert oder angewendet.

## Teststatus

Siehe `docs/discovery/collector-tests.md`.
