# 06 – Offene Entscheidungen und fehlende Informationen

## Benötigt von dir

1. **Discovery-Bericht** beider Router: `sh tools/discovery.sh` (rein lesend; schreibt `/tmp/tsem-discovery-<host>.XXXXXX` mit Modus 600). Den Bericht bitte *vor* dem Teilen auf Tailnet-/Personendaten prüfen; das Skript maskiert Schlüssel, Tokens, Passwörter, MAC-Adressen, E-Mail-Adressen und Tailnet-Namen (Best Effort, siehe `07-discovery-skript-tests.md`), nicht aber IP-Adressen, Interface- und Hostnamen.
2. **Prototyp-Skripte** (`/etc/gl-switch.d/tailscale-de.sh` und den `procd`-Monitor des MG1300) als Referenz.
3. **Testumgebung:** Wo laufen CI-Runner und Docker? Gibt es einen Runner mit `--privileged` bzw. `NET_ADMIN` für Netzwerk-Namespaces und QEMU?
4. **Test-Tailnet:** Darf ein separater Test-Auth-Key (oder Tailnet) für Integrationstests mit echtem Tailscale genutzt werden?

## Entscheidungen

| # | Frage | Vorschlag |
|---|---|---|
| D1 | Was ist „geschützt"? Nur `lan` oder auch Gast-/IoT-Netze, WLAN-Bridges, Repeater-Clients? | Standard `lan`; weitere per Konfiguration |
| D2 | Routereigener Verkehr: NTP, Paketmanager, GL.iNet-Cloud/DDNS in GERMAN erlaubt oder über Tunnel/geblockt? | Allowlist: Tailscale, DHCP, NTP; Rest geblockt |
| D3 | Standard ohne/mit defekter Intent-Datei: DIRECT oder BLOCKED? | BLOCKED (fail-closed), nur wenn Paket installiert & Guard aktiviert |
| D4 | Schalter bewegt, während Router aus war: wirkt die Schalterposition beim Boot als Aktion oder bleibt gespeicherter Zustand? | Gespeicherter Zustand bleibt; Schalter wirkt erst bei der nächsten Bewegung |
| D5 | Schalterbelegung: welche Position = GERMAN? Gibt es nur 2 Positionen? | Zwei Positionen, Zuordnung per UCI |
| D6 | Deinstallation: Guard entfernen (Zugang wieder offen) oder aktiv lassen? | Entfernen + Warnung + Backup |
| D7 | IP/Land-Provider: `myip.wtf` Default oder neutraler Default? ToS bitte prüfen | Neutral konfigurierbar, `myip.wtf` als wählbarer Provider |
| D8 | Home-Assistant-Anbindung: MQTT-Broker vorhanden (Mosquitto auf HAOS?) und erreichbar vom Router (über Tailscale oder LAN)? | MQTT Discovery |
| D9 | Failover-Parameter (Fehlerschwelle, Rückkehrzeit)? | 3×5 s Failover, 60 s stabil für Rückkehr |
| D10 | Lizenz | MIT oder Apache-2.0 (Gitea-Repo wurde vorläufig mit MIT initialisiert) |
| D11 | Remote-Lock-out-Schutz: Dead-man-Timer bei Erstaktivierung auf einem Router, der nur über Tailscale erreichbar ist? | Ja, Pflicht |
