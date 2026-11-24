# 01 – Bestandsaufnahme

Stand: 2026-11-14. Status: **vorläufig – Gerätedaten fehlen noch**.

## Was geprüft wurde

| Bereich | Ergebnis |
|---|---|
| Repository-Zugriff | Ein Repository konnte angelegt werden (privat, Branch `main`). |
| Gitea-Rechte | Repo-, Branch-, Issue-, PR-Tools verfügbar. Branch Protection, Org-/Rechteänderungen wurden **nicht** angefasst. |
| Router-Zugriff | **Keiner.** Die Entwicklungsumgebung hat keinen Netzwerkzugang zu den Routern (kein SSH, kein Tailscale). Es wurde nichts an produktiven Geräten gelesen oder verändert. |
| Prototypen | `/etc/gl-switch.d/tailscale-de.sh` (MT3000) und der `procd`-Monitor (MG1300) liegen auf den Routern und sind mir **nicht bekannt**. Es wird nichts über deren Inhalt angenommen. |
| myip.wtf | Seite ist aus der Sandbox nicht abrufbar; Nutzungsbedingungen **ungeprüft**. Deshalb von Anfang an Provider-Abstraktion (siehe Architektur). |

## Annahmen, die vor Implementierung verifiziert werden müssen

Diese Punkte beeinflussen die Architektur direkt. Sie sind aus allgemeinem Wissen über GL.iNet/OpenWrt abgeleitet, **nicht** am Gerät bestätigt:

1. **Firewall-Backend.** GL.iNet-4.x-Firmware basiert je nach Modell/Version auf OpenWrt 21.02 (fw3/iptables) oder 23.05 (fw4/nftables). Das entscheidet über die Kill-Switch-Implementierung. Der Entwurf kapselt das Backend deshalb (nft primär, iptables-Fallback).
2. **GL.iNet-eigene Tailscale-Verwaltung.** GL.iNet liefert eigene Skripte/Init-Dienste und eine Web-UI-Integration für Tailscale mit. Ob diese bei `tailscale set` oder Firewall-Änderungen gegensteuert (z. B. Zone `tailscale`, Masquerading, Exit-Node-Auswahl in der UI), ist offen.
3. **Tailscale-Verhalten.** Exit-Node-Routing läuft über Policy-Routing (eigene Routing-Tabelle, ip rules) und `tailscale0`; Tailscales eigener Verkehr ist per fwmark markiert, damit er den Tunnel umgeht. Exakte Mark-Werte/Prioritäten sind versionsabhängig und werden aus Version 1.92.x am Gerät ausgelesen.
4. **Schalter-API.** MT3000: Hotplug-Events unter `/etc/gl-switch.d/`. MG1300: laut Auftrag Polling. Ob es dort eine Event-Alternative gibt, ist offen.
5. **Speicher/Flash.** Verfügbarer Platz für Pakete und Schreibzyklen-Budget für Zustandsdateien sind unbekannt.
6. **Paketformat.** OpenWrt 21.02/23.05 nutzen `opkg` (.ipk); ab 24.10 `apk`. GL.iNet 4.x sollte `opkg` sein – zu bestätigen.

## Fehlende Informationen / Zugriff

Dafür liegt `tools/discovery.sh` bei: ein **rein lesendes** Skript, das auf jedem Router ausgeführt wird und einen Bericht nach `/tmp` schreibt (keine Änderungen, keine Secrets). Bitte pro Router ausführen und den Bericht bereitstellen (siehe `docs/phase1/06-offene-entscheidungen.md`).
