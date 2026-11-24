# 05 – Implementierungsplan

## Meilensteine

| M | Inhalt | Ergebnis |
|---|---|---|
| M0 | Discovery abschließen (Gerätebericht, GL-Skripte, fw3/fw4) | ADR-0001 Firewall-Backend, ADR-0002 Koexistenz mit GL.iNet |
| M1 | Core: Intent/Lock/Sequenz, Guard (nft), `tsem` CLI, Stub-Testumgebung | Tests Ebene 1–3 grün für Moduswechsel und Kill Switch |
| M2 | `tsemd`: Probes, Failover, Hysterese, BLOCKED | Failover-/Flapping-Tests |
| M3 | HW-Adapter (MT3000 Hotplug, MG1300 Polling), HA-MQTT, lokale API | Konkurrenz-/Stale-State-Tests |
| M4 | Paketierung (`opkg`), init/procd, Backup/Rollback, Diagnose, CI-Build | Tests Ebene 4 (Install/Upgrade/Remove) |
| M5 | Doku (EN), Security Considerations, CONTRIBUTING, Lizenz, Release Notes | Release Candidate `v0.1.0-rc1` |

## Reihenfolge innerhalb M1 (sicherheitskritisch zuerst)

1. Guard-Regelwerk + Testharness mit Netzwerk-Namespaces (Leak-Tests zuerst, damit sie rot starten).
2. Intent-Speicher und `tsem set` (nur Zustand und Guard, noch ohne Tailscale).
3. Exit-Node-Setzen mit Tailscale-Stub.
4. Boot-/Upgrade-Verhalten.

## Arbeitsweise

- Ein Issue je Arbeitspaket, ein Branch je Issue (`feat/…`, `fix/…`, `docs/…`), PR auf `main`, CI (shellcheck, nft-Check, bats, Namespace-Tests) muss grün sein.
- Keine IPs, Domains, Tailnet-Namen oder Zugangsdaten im Repo; Beispielwerte nur aus Dokumentationsbereichen (RFC 5737/3849, `100.64.0.0/10` generisch als Platzhalter `<EXIT_NODE_IP>`).
- Repo bleibt **privat**; Öffentlichschalten nur nach Freigabe.
- Keine Aktion an produktiven Routern.

## Nächste konkrete Schritte

1. Der Betreiber führt `tools/discovery.sh` auf beiden Routern aus (read-only) und stellt die Berichte bereit.
2. Entscheidungen aus Dokument 06 beantworten.
3. Danach M1 starten (Issues sind angelegt).
