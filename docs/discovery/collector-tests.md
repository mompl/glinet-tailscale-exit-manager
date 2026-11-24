# Collector: Testprotokoll (v4)

`sh tools/test-collect.sh` ergibt **401 bestanden, 0 fehlgeschlagen** (dash, bash und BusyBox-ash-Shell; zusätzlich `bash --posix` für die Syntax).

## Abgedeckt

- **Read-only (statisch):** keine mutierenden oder Netzwerk-Befehle, kein `eval`, genau ein `exec </dev/null`, nur drei `rm -f` (nur `$OUT`/`$CAP`), Schreibumleitungen nur nach `$OUT`/`$CAP`, keine State-Dateien, kein `opkg update`, keine Init-Skript-Aufrufe.
- **Datenschutz:** kein `ps`, `cmdline` nur für die tailscaled-Allowlist, `logread` nur über `tcap`, `uci` nie roh, nur Allowlist-/Firewall-Zugriffe. Redaktions-Fixture (Keys, tskey, PEM, Bearer, URL-Credentials, SSID, MAC, E-Mail, ts.net, glddns). E2E mit Stubs: Log-Passwörter, procd-Kommandozeilen und -Umgebung, Tailscale-Auth-URL, WLAN-SSID/-Key, DHCP-Hostnamen, WireGuard-Key, GL-Cloud-Token, UCI-Auth-Key, Hostname tauchen nicht im Bericht auf. `script_view`: Befehlszeilen sichtbar, Secret-Zeilen unterdrückt und gezählt, Volltext nur für Schalter-Verzeichnisse mit `--full-scripts`. `/proc`-Fixture: nur Namen, tailscaled ohne `--auth-key`.
- **Fehlererkennung:** fehlschlagender Befehl erzeugt `!! failed`, Abschnitt `partial`, `completeness=partial`; fehlendes Tool `!! n/a` (gezählt, kein Fehler); Kürzung (`TSEM_LIMIT=3`) wird gemeldet und macht `partial`; Abschnitt ohne Status ergibt `completeness=incomplete`; Marker hinter dem Zeilenlimit werden mitgezählt.
- **Integrität:** END-Zeilenzahl und SHA-256 stimmen mit der Datei überein. `run-collector.sh` akzeptiert vollständig (Exit 0), speichert partiell mit Exit 4 und Liste, verwirft `incomplete`, beschädigten Inhalt (Hash), abgeschnittenen Stream, ein END allein, meldet fehlenden Router-Hash als Warnung, Leak-Treffer mit Exit 3, reicht `--full-scripts` weiter und lehnt unbekannte Argumente ab.
- **`sh -s` und `exec </dev/null`:** vollständiger Lauf per stdin (alle Abschnitte, letzter Abschnitt läuft), ein Stub, der stdin liest, sieht EOF (Skript wird nicht verbraucht), stückweise gesendetes Skript (langsame Verbindung) läuft komplett, ein abgeschnittenes Skript führt nichts aus.
- **Leak-Block:** ohne Redaktion wird der Bericht gelöscht (Exit 3), stdout leer, stderr nur Zähler.

## Mutationstests (müssen Testfehler erzeugen)

`ps w`, unbegrenztes `find /`, rohes `uci show`, entferntes `exec </dev/null` (Test hängt, durch Timeout erkannt, zusätzlich statischer Test), rohes `logread`, zusätzliches `rm -f`. Frühere Läufe: `iptables -F`, `tailscale set`, `uci commit`, `curl`.

## OFFEN (nicht getestet)

- **BusyBox-Applets:** Die verfügbare Nix-BusyBox (1.36.1) enthält nur die Shell `ash`. `sed`, `awk`, `grep`, `find`, `xargs`, `nice`, `timeout`, `flock`, `sort`, `uniq` liefen mit den GNU-Versionen des Testrechners. Verhalten unter BusyBox ca. 1.33 (OpenWrt 21.02) ist ungeprüft. Bewusst vermieden: `grep -I`, `grep -r`, `xargs -r`, `find -printf`, `head -c`, `stat`. Abschnitt 04c des Berichts prüft die benötigten Fähigkeiten auf dem Gerät.
- **Echtlauf auf GL-MT3000 und GL-MG1300:** nicht möglich (kein SSH-Zugriff). Laufzeit, Speicherbedarf und die tatsächliche Allowlist-Trefferquote (z. B. ob die GL-spezifischen Skripte relevante Zeilen liefern) sind unbekannt; ein zweiter Lauf mit `--full-scripts` kann nötig werden.
- Die Allowlists für GL-eigene UCI-Configs (glconfig, wireguard) sind Schätzungen; der Bericht listet dort zusätzlich alle Schlüsselnamen, damit sie nachgeschärft werden können.
