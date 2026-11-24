# 04 – Teststrategie

## Ebenen

1. **Statisch:** `shellcheck`, `nft -c -f` (Syntaxprüfung der Regeln), UCI-Schema-Validierung.
2. **Unit (bats):** Zustandsautomat, Hysterese, Sequenz-/Lock-Logik, Intent-Parser – mit gemocktem `tailscale`, `nft`, Zeit.
3. **Integration in Linux-Netzwerk-Namespaces (`ip netns`, nft):** Topologie `client – router – wan – exit-node-A/B`. Router-Rolle läuft mit echten nft-Regeln und `tsemd`; Exit Nodes sind Namespaces mit Forwarding. Tailscale selbst wird durch einen **Stub** ersetzt, der `tailscale set/status/ping` nachbildet und Routen/Interfaces schaltet.
4. **System (OpenWrt-Image):** OpenWrt-x86-Rootfs (Container oder QEMU) mit echter `procd`-/Init-/Paketumgebung; Test von Install, Upgrade, Remove und Boot-Reihenfolge. Läuft auf einer separaten Testinfrastruktur.
5. **Gerätetest (nur nach Freigabe):** read-only Verifikation, dann gestufter Rollout auf ein Gerät mit Rückfallplan.

## Testfälle (Zuordnung zum Auftrag)

| Auftrag | Prüfung | Ebene |
|---|---|---|
| DIRECT → GERMAN | Sperre gesetzt *bevor* Exit Node aktiv; kein Paket ins WAN während Wechsel (Capture auf WAN-NS) | 3 |
| GERMAN → DIRECT | Exit Node entfernt, WAN-Forwarding erst danach offen; Subnetze erreichbar | 3 |
| Primär fällt aus | Failover nach N Fehlern, Datenpfad über sekundär, 0 Pakete ins WAN | 3 |
| Sekundär fällt aus | Bleibt auf primär, kein Wechsel | 2/3 |
| Beide fallen aus | BLOCKED, Clients ohne Internet, Tailscale-Control bleibt erreichbar | 3 |
| Wiederherstellung | Rückkehr nur nach Hysterese, kein Flapping bei Wackelverbindung | 2/3 |
| Neustart je Modus | Guard vor Netzwerk geladen; Capture im Bootfenster; Intent unverändert | 4 |
| Tailscale-Neustart / Absturz (`kill -9`) | Guard bleibt; Clients ohne Internet bis Wiederkehr | 3/4 |
| WAN-Ausfall | Kein Leak, Recovery nach Rückkehr, korrekter Status (HA-Sensoren) | 3 |
| DNS-Leak | Client-DNS an 8.8.8.8 / DoT Port 853 wird nicht ins WAN geleitet; dnsmasq-Upstream nur Tunnel | 3 |
| IPv6-Leak | v6-Client, RA, Exit Node ohne v6 → 0 v6-Pakete im WAN | 3 |
| Gleichzeitige Aktionen | N parallele `tsem set` → deterministischer Endzustand, Sequenz lückenlos | 2/3 |
| Veralteter Schalter | Retained-Command, Neustart, Status-Sync schreiben nie Intent | 2 |
| Upgrade / Deinstall | Guard durchgehend aktiv beim Upgrade; Remove hinterlässt definierten Zustand; Rollback | 4 |
| Daemon-Ausfall | `kill -9 tsemd` → Guard unverändert, procd startet neu, Zustand konsistent | 3/4 |

## Beweisführung

Jeder Netzwerktest erzeugt ein **Capture-Artefakt** (`tcpdump` am WAN-Namespace) und eine Zusammenfassung „Pakete mit Client-Quelladresse am WAN: 0". Ergebnisse werden in CI als Artefakt abgelegt und unter `docs/testing/` beschrieben.

## Grenzen

Der Tailscale-Stub bildet echtes Tailscale nicht vollständig ab (DERP, fwmark-Details). Deshalb Ebene 4/5 mit echtem `tailscaled` (Test-Tailnet, separater Auth-Key des Betreibers) – **nicht** in der Entwicklungsumgebung automatisch möglich. Kernel-/Netfilter-Version der Testumgebung unterscheidet sich von den Routern (5.4/5.15); Regeln werden bewusst auf konservative nft-Features beschränkt.
