# 02 – Architekturvorschlag

Oberstes Ziel: **Ein zuverlässiger Kill Switch ist wichtiger als schnelle Umschaltung oder Komfort.**

## Grundprinzip: Firewall entscheidet, Daemon steuert

Der Schutz liegt in einem **statischen Firewall-Regelwerk im Kernel**, nicht im Monitor-Prozess. Der Daemon (`tsemd`) wählt nur den Exit Node und schaltet zwischen zwei vorbereiteten Regelzuständen. Stirbt der Daemon, bleibt der zuletzt gesetzte Zustand erhalten. Stirbt Tailscale, gibt es keine erlaubte Route ins WAN.

```
            +-------------------+     +--------------------+
  HW-Schalter-->  tsem-switch   |     |  Home Assistant    |
  (Hotplug/Poll)   (nur Edge)   |     |  (MQTT Discovery)  |
            +---------+---------+     +----------+---------+
                      |                          |
                      v                          v
                +---------------------------------------+
                |  tsem (CLI)  --  einziger Schreibpfad  |
                |  flock + Sequenznummer + Quelle        |
                +-------------------+-------------------+
                                    v
                    /etc/tsem/intent  (Sollzustand, persistent)
                                    |
                  +-----------------+------------------+
                  v                                    v
          tsemd (procd) Reconciler            Firewall-Guard (nft/iptables)
   Health-Probes, Failover, Hysterese          statisch, fail-closed,
   tailscale set --exit-node=...               überlebt Daemon-/Tailscale-Ausfall
```

## Modi und Firewall-Zustände

| Modus | Exit Node | Forwarding geschützter Clients → WAN | → tailscale0 |
|---|---|---|---|
| DIRECT | keiner | erlaubt | erlaubt (Subnetze) |
| GERMAN (Node verfügbar) | primär/sekundär | **verboten** | erlaubt |
| BLOCKED (kein Node verfügbar) | keiner/zuletzt | **verboten** | verboten (außer Recovery) |

GERMAN und BLOCKED haben dieselbe WAN-Sperre; sie unterscheiden sich nur darin, ob der Pfad über `tailscale0` offen ist. Dadurch gibt es **keinen Zustand, in dem ein Moduswechsel die WAN-Sperre kurz öffnet**: Beim Wechsel DIRECT→GERMAN wird zuerst die Sperre gesetzt, dann der Exit Node.

## Firewall-Guard

- **Eigene nft-Tabelle** `inet tsem` (nicht `fw4`), Hook `forward` mit Priorität vor `fw4`. Ein `drop` in einer Tabelle ist endgültig, ein `accept` in `fw4` kann ihn nicht aufheben. `fw4 reload` und die GL.iNet-UI können sie nicht versehentlich leeren.
- **Zustandswechsel atomar** (`nft -f` mit einer Transaktion, ein Set `protected_ifaces`/`protected_nets`, zwei Chains, die per Jump-Regel gewählt werden).
- **Beim Boot früh geladen** (init `START` vor Netzwerk/Firewall), Standard = geschützt, wenn Intent `GERMAN` oder unbekannt/defekt. Offene Frage: Verhalten ohne Intent-Datei (siehe offene Entscheidungen).
- **iptables-Fallback (fw3):** eigene Chain `TSEM_FWD`, per `firewall.user`/Include und `-I FORWARD 1` eingehängt; Reapply-Hook bei `firewall reload`. Wird nur gebaut, wenn Discovery fw3 zeigt.
- **IPv4 und IPv6:** Die Guard-Regeln gelten für `inet` (beide Familien). IPv6 ins WAN ist in GERMAN/BLOCKED immer gesperrt, außer der Exit Node transportiert IPv6 nachweislich. Verhindert zudem RA/Prefix-Leaks nach außen.
- **Router-eigener Verkehr (`output`):** Standard geschützt sind DNS und Anwendungsverkehr der Clients. Tailscale-Kontrollverkehr (DERP, Control, WireGuard-UDP) wird über Tailscales fwmark bzw. UID **explizit** durchgelassen. Restlicher Router-Output ins WAN (NTP, Paketverwaltung, GL.iNet-Cloud) ist konfigurierbare Allowlist; Default: Allow nur für `tailscaled`, NTP, DHCP/ARP-Basis.
- **DNS:** Clients werden per DNAT/Redirect (Port 53, ggf. 853) auf den Router gezwungen. `dnsmasq` fragt in GERMAN ausschließlich über den Tunnel nach (Resolver hinter dem Exit Node); direkte Port-53/853-Pakete ins WAN werden im Guard verworfen. DoH-Umgehung durch Clients wird **nicht** gelöst (dokumentierte Grenze).
- **Geschützte Netze** sind konfigurierbar (UCI-Liste `protected_ifaces`), Default `lan`. Gastnetz/IoT-Netze: Entscheidung offen.

## Exit-Node-Steuerung (`tsemd`)

- Läuft unter `procd` mit Respawn, ist aber **nicht sicherheitskritisch**.
- Nutzt ausschließlich `tailscale set --exit-node=<ip>`; kein Neustart von `tailscaled`, bestehende Einstellungen (Subnetz-Routen, Accept-Routes, Hostname) bleiben unangetastet. Vor jedem Setzen wird der aktuelle Wert gelesen, nur Differenzen werden geschrieben.
- **Health-Probe** pro Kandidat, zweistufig: (1) `tailscale ping`/Peer-Status online, (2) **Datenpfad-Test** über den Tunnel (z. B. TCP/HTTPS-Probe mit Bindung an `tailscale0`/Routing-Mark). Nur Stufe 2 gilt als "verfügbar".
- **Failover:** N aufeinanderfolgende Fehlschläge (Default 3 × 5 s) → nächster Kandidat. Beide ausgefallen → BLOCKED.
- **Rückkehr zum primären Node:** erst nach M erfolgreichen Proben über Mindestzeit (Default ≥ 60 s stabil) und frühestens `min_dwell` s nach letztem Wechsel (Hysterese).
- Während jedes Wechsels bleibt die WAN-Sperre aktiv; Verlust ist ein Paketverlust, kein Leak.
- Probe-Ziele/Intervalle in UCI konfigurierbar; keine festen Adressen im Paket.

## Sollzustand und Konkurrenz („letzte Aktion gewinnt")

- **Ein Schreibpfad:** alle Oberflächen rufen `tsem set <mode> --source hw|ha|cli|api`. Unter `flock` wird eine **monoton steigende Sequenznummer** und Zeitstempel geschrieben und Intent atomar ersetzt (Write-temp + `rename`).
- **Nur echte Aktionen schreiben:**
  - HW-Schalter: nur auf **Flanke** (Hotplug-Event bzw. Positionswechsel gegenüber zuletzt gesehener Position), nie auf den bloßen Zustand. Beim Boot wird die Position nur *gelernt*, nicht als Aktion gewertet.
  - Home Assistant: nur auf Command-Topic-Nachricht (nicht retained!), niemals aus dem State-Topic. Status-Publishing schreibt nie in den Intent.
  - Neustart liest Intent, schreibt nichts.
- Flash-Schonung: Intent wird nur bei Änderung geschrieben; Laufzeitstatus liegt in `/var/run/tsem` (tmpfs).
- **Offen:** Zustand "Schalter bewegt, während Router aus war" (siehe Entscheidungen).

## Home Assistant

- **MQTT Discovery** gegen den lokalen Broker; Anbindung per `mosquitto_pub/sub` oder leichtem Publisher im Daemon. Zugangsdaten nur in UCI (Dateirechte 0600), nie im Paket.
- Entitäten gemäß Auftrag: Schalter *German Internet*, Sensoren (Modus, aktiver Node, IPv4, IPv6, Land, Node-Verfügbarkeit, letzte erfolgreiche Prüfung), Binary Sensors (*Kill Switch aktiv*, *Internet erreichbar*).
- LWT/Availability-Topic, damit HA „nicht verfügbar" statt veraltetem Zustand anzeigt.
- **Öffentliche IP/Land:** Abfrage **über den geprüften Ausgang** (Quell-Bindung bzw. Routing-Mark/Interface), Provider austauschbar (`myip.wtf` als ein Provider, Alternativen konfigurierbar, Ergebnis gecacht, Rate-Limit). Probes dürfen den Kill Switch nicht umgehen: im BLOCKED-Zustand schlagen sie fehl und werden so gemeldet.

## Lokale API/CLI

`tsem status [--json]`, `tsem set direct|german`, `tsem diag`, `tsem backup|restore`. Eine HTTP-/ubus-API ist nur dünne Schicht über der CLI (ubus mit ACL, nur LAN/Loopback). Keine eigene Authentifizierungslogik außer rpcd-ACL.

## Trennung Hardware vs. Logik

```
/usr/lib/tsem/core/        -- Zustand, Failover, Guard, Probes (geräteunabhängig)
/usr/lib/tsem/hw/<model>   -- Schalter-Adapter (mt3000-hotplug, mg1300-poll, none)
/usr/lib/tsem/fw/{nft,ipt} -- Firewall-Backend
```

Schalter-Adapter liefern nur Ereignisse `position_changed(name, value)`.

## Implementierungssprache

Vorschlag: **POSIX-sh + `jsonfilter`/`ubus`** für Kern und CLI (minimale Abhängigkeiten, läuft auf beiden Geräten ohne zusätzliche Pakete), Guard-Regeln als reine `nft`-Dateien. `ucode` wird nur genutzt, wenn Discovery es auf beiden Geräten zeigt. Logik, die Tests braucht, wird in kleine, mit `shellcheck`/`bats` testbare Funktionen zerlegt.

## Paketierung

OpenWrt-Feed-Struktur (`package/tsem/Makefile`), Abhängigkeiten `tailscale`, `nftables-json` oder `iptables` je Backend, optional `mosquitto-client`. Konfiguration in `/etc/config/tsem` (UCI), `sysupgrade.conf`-Eintrag für `/etc/config/tsem` und `/etc/tsem/intent`. Upgrade: Guard bleibt über das Update geladen (postinst lädt neu, bevor prerm/Stop den alten entfernt). Deinstallation fragt/dokumentiert, ob Guard entfernt wird (**Standard: Guard entfernen und Modus DIRECT, mit Warnung**; Alternative offen).
