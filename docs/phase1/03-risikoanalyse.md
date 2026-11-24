# 03 – Risikoanalyse

Bewertung: Auswirkung (A) × Wahrscheinlichkeit (W), jeweils hoch/mittel/niedrig.

| # | Risiko | A | W | Gegenmaßnahme |
|---|---|---|---|---|
| R1 | **Leak im Bootfenster:** LAN/Forwarding aktiv, bevor Guard geladen ist | hoch | mittel | Guard sehr früh laden (vor `network`/`firewall`), Standard geschützt; Test: Paketmitschnitt während Boot |
| R2 | `fw4 reload`/GL.iNet-UI leert Regeln | hoch | mittel | Eigene nft-Tabelle; Watchdog `tsem diag` prüft Guard-Existenz; fw3: Reapply-Hook |
| R3 | GL.iNet-Skripte setzen Exit Node/Zonen zurück oder konkurrieren | mittel | hoch | Discovery der GL-Skripte; Konfliktmatrix; bei Konflikt dokumentierte Koexistenz (Guard schützt unabhängig) |
| R4 | DNS-Leak (Router-dnsmasq, Client-DoH/DoT, hartkodierte Resolver) | hoch | hoch | DNS-Redirect, Guard blockt 53/853 ins WAN, dnsmasq upstream nur über Tunnel; DoH-Umgehung = dokumentierte Restgrenze |
| R5 | IPv6-Leak (RA, GUA, Exit Node ohne v6) | hoch | mittel | Guard `inet`, v6 ins WAN immer gesperrt in GERMAN/BLOCKED; Tests mit v6-Clients |
| R6 | Ausgehender Router-Verkehr leakt Identität (NTP, Cloud) | mittel | hoch | Router-Output-Allowlist; Entscheidung, was „geschützt" heißt |
| R7 | Exit Node „online", Datenpfad tot (Blackhole) | mittel | mittel | Datenpfad-Probe statt nur Peer-Status; Traffic läuft dennoch nie ins WAN (Fail-closed) |
| R8 | Flapping | niedrig | mittel | Fehlerschwelle, Rückkehr-Hysterese, `min_dwell` |
| R9 | Veralteter Schalterzustand überschreibt neuere Aktion | mittel | hoch | Flanken-basiert, Sequenznummer unter `flock`, retained-Command verboten, Boot lernt nur |
| R10 | Zwei gleichzeitige Aktionen / Race | mittel | mittel | Einziger Schreibpfad mit Lock, deterministische Reihenfolge nach Lock-Erwerb; Test mit parallelen Aufrufen |
| R11 | Beschädigte/fehlende Intent-Datei | hoch | niedrig | Atomares Schreiben, Prüfsumme, bei Fehler → geschützt (BLOCKED) statt DIRECT |
| R12 | Upgrade-/Deinstall-Lücke (Guard kurz weg oder dauerhaft hängen) | hoch | mittel | Reihenfolge in Install-Skripten, Rollback-Backup, Test Upgrade/Remove, klare Doku |
| R13 | Lock-out: Router aus der Ferne unerreichbar (Guard sperrt Management) | hoch | mittel | Management-Pfade (LAN-Admin, Tailscale-Control, SSH über Tailscale) explizit erlaubt; Notfall-`tsem panic-open` lokal + Dead-man-Timer bei Erstinstallation |
| R14 | Tailscale-Versions-/Mark-Änderung bricht Allow-Regeln | mittel | mittel | Versions-Check in `diag`, Tests gegen mehrere Tailscale-Versionen, Fallback über UID statt Mark |
| R15 | IP-Provider-ToS/Datenschutz | niedrig | mittel | Provider konfigurierbar, Caching, Default dokumentiert; keine Zugangsdaten im Repo |
| R16 | Flash-Verschleiß | niedrig | niedrig | Intent nur bei Änderung, Status in tmpfs, Logs in RAM |
| R17 | Prototyp-Annahmen ungeprüft übernommen | mittel | mittel | Prototypen nur als Referenz; Review nach Discovery |
| R18 | Firmware-Update ersetzt Pakete/Konfiguration | mittel | mittel | `sysupgrade.conf`, Re-Install-Skript, Dokumentation |

## Bewusst akzeptierte Restrisiken (zu bestätigen)

- DoH/DoT in Client-Apps kann DNS-Redirect umgehen, der Verkehr bleibt aber im Tunnel (kein Leak ins WAN, nur ein anderer Resolver).
- Nicht geschützt sind Netze, die nicht als `protected` konfiguriert sind.
- Ein Angreifer mit Root auf dem Router kann den Guard entfernen.
