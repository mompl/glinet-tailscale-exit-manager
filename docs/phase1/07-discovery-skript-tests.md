# 07 – discovery.sh: Änderungen und Tests

Stand: 2026-11-14. Das Skript ist **rein lesend**. Es wurde in dieser Umgebung gegen Attrappen getestet, **nicht** auf einem Router und **nicht** unter BusyBox.

## Änderungen gegenüber Version 1

| Anforderung | Umsetzung |
|---|---|
| `umask 077` direkt nach Shebang | Zeile 2 des Skripts |
| Bericht mit 600 | `mktemp /tmp/tsem-discovery-<host>.XXXXXX` (unvorhersehbarer Name, kein Symlink-Angriff über festen Namen) plus explizites `chmod 600` |
| Funktion `run` | entfernt |
| `eval` vermeiden | Jede Sektion ist ein normaler Funktionsaufruf mit Pipeline; keine dynamische Codeausführung |
| Konsequente Maskierung | `redact()` mit 15 Regeln: Schlüsselnamen mit pass/secret/token/key/auth/psk/cred/username (Groß-/Kleinschreibung egal, auch `option`/`list`-Zeilen), `tskey-…`, `--authkey X`, `privkey:`/`nodekey:`/`mkey:`…, WireGuard-Base64-Schlüssel (44 Zeichen), PEM-/Schlüsselblöcke, URL-Zugangsdaten, `Authorization:`-Header, Bearer-Tokens, Tailscale-Login-URLs, MAC-Adressen, E-Mail-Adressen, `*.ts.net`-Tailnet-Namen |
| Keine unkontrollierten Config-Dumps | `uci show` läuft zuerst durch `drop_secret_lines` (Zeilen mit geheimen Schlüsselnamen werden ausgelassen und gezählt), danach `redact()`. `glconfig` nur gefiltert (`tailscale\|switch\|button\|mode`). `tailscale debug prefs` nur als Allowlist einzelner Felder, nie vollständig (der vollständige Dump kann Node-Keys enthalten). Maximal 400 Zeilen je Sektion |
| Zusätzlicher Schutz | Nach dem Schreiben prüft `leak_check` den Bericht auf übrig gebliebene Schlüsselmuster. Bei Fund: Bericht wird gelöscht, Exit-Code 3 |
| Keine Änderungen | nur Lesebefehle; einzige Schreibzugriffe sind der Bericht und dessen Löschung bei Leckfund |
| BusyBox ash | keine Bashismen (`[[ ]]`, `local`, `echo -e`, Prozesssubstitution, `pipefail`); nur POSIX-Werkzeuge mit BusyBox-üblichen Optionen (`sed -E`, `awk`, `grep -E`, `mktemp`, `tr`, `command -v`) |

`tools/discovery.sh` wurde dabei in Teilen neu aufgebaut; die Abschnitte und die erfassten Daten entsprechen Version 1. Neu sind nur `flock`, `md5sum`, `mktemp` in der Werkzeugliste. Entfernt wurde das Auslesen des kompletten `tailscale debug prefs` zugunsten der Allowlist.

## Tests (`sh tools/test-discovery.sh`)

Ergebnis lokal: **121 bestanden, 0 fehlgeschlagen** (je Shell dash und bash; wiederholt ausgeführt, stabil).

| Gruppe | Prüfung |
|---|---|
| Statisch | Zeile 1 = Shebang, Zeile 2 = `umask 077`; kein `eval`/`exec`; keine Bashismen; keine verändernden Befehle (Muster für `uci set/commit`, `nft add/flush/-f`, `iptables -A/-I/-D/-F`, `tailscale up/set/down`, Init-Skript-Aktionen, `reboot`, `kill`, `mv`, `cp` …); genau ein `rm`, und das nur auf den eigenen Bericht |
| Syntax | `dash -n`, `bash -n`, `bash --posix -n` |
| Redaktion | 25 Geheimnismuster aus einer Fixture (WireGuard private/preshared Keys, PPPoE-Passwort/-Benutzer, WLAN-Schlüssel, `option`/`list`-Zeilen, `AuthKey`/`PrivateNodeKey`/`NodeKey` als JSON, `--authkey=`, `--auth-key X`, `--authkey X`, frei stehender `tskey-`, Bearer, Basic, Proxy-Authorization, URL-Zugangsdaten, Login-URL, `api_token=`, `secret:`, OpenVPN-/PEM-Blöcke, Base64-Key, E-Mail, Tailnet-Name, MAC) dürfen nicht in der Ausgabe vorkommen. Harmlose Konfigurationszeilen (IP, Netzmaske, Zonennamen, `ACCEPT`, Routen) bleiben **unverändert** |
| Hilfsfunktionen | `drop_secret_lines` lässt Geheimniszeilen weg, behält andere und meldet die Anzahl; `leak_check` erkennt ein übrig gebliebenes Muster und akzeptiert eine saubere Datei; `limit` kürzt mit Hinweis |
| Ende-zu-Ende | Attrappen für `tailscale`, `uci`, `logread` geben Geheimnisse aus. Der Bericht entsteht mit Modus `-rw-------` unter `/tmp/tsem-discovery-*`, enthält keines der 11 Geheimnisse, enthält die Allowlist-Felder (`ExitNodeID`), aber nicht den `Persist`-Block, filtert `glconfig` (Cloud-/Admin-Zeilen fehlen, `mode` bleibt) |
| Leck-Schutz | Mit absichtlich blind gemachter `redact()` und Geheimnissen in der Ausgabe: Exit-Code 3, Bericht gelöscht, Fehlermeldung ausgegeben |

### Gegenprüfung der Tests (Mutation)

- Entfernt man die `tskey-`-Regel, schlägt der Test für frei stehende Keys fehl (`leaked: barevalue`). Dabei wurde eine Lücke der ersten Fixture gefunden und geschlossen.
- `umask 022` in Zeile 2 und ein eingefügtes `eval` werden von den statischen Tests erkannt.
- Der erste Testlauf fand zwei **echte Fehler** in der Redaktion: `Authorization: Bearer <token>` und `Authorization: Basic <token>` wurden nur halb maskiert (der Token blieb stehen). Behoben durch eine eigene Regel für `Authorization`-Header vor der allgemeinen Schlüsselregel. Ein falscher Treffer im Bashismus-Test (`[[:space:]]`) wurde im Test korrigiert.
- Der Entfernungstest für `chmod 600` ist nicht unterscheidbar: `mktemp` legt die Datei bereits mit 600 an. Das `chmod` ist bewusst eine zweite Absicherung.

## Nicht getestet / Grenzen

- **BusyBox ash/sed/awk/grep standen hier nicht zur Verfügung.** Getestet wurde mit dash, bash, GNU sed und mawk. Syntax und Redaktion sollten einmal auf dem Router bestätigt werden, ohne etwas auszuführen:
  `sh -n tools/discovery.sh` (reine Syntaxprüfung). Danach der eigentliche Lauf.
  Optionen, die auf älterer BusyBox fehlen könnten: `grep -I` (nur der Dateinamen-Abschnitt betroffen; eine Fehlermeldung landet dann im Bericht), `mktemp` mit Vorlage.
- **Kein echter Router, kein echtes Tailscale**: `uci`, `tailscale`, `logread` wurden durch Attrappen ersetzt. Das echte Ausgabeformat von `tailscale debug prefs` und `uci show glconfig` ist unbekannt; die Allowlist könnte Felder verfehlen (dann fehlen Informationen, es gibt aber kein Leck).
- Die Maskierung ist **Best Effort**. Nicht maskiert werden IP-Adressen, Interface-/Hostnamen und Routen. Mehrwörtige Klartext-Passwörter in nicht erkannten Formaten könnten teilweise stehen bleiben; `leak_check` fängt nur Schlüssel-ähnliche Muster. Bericht deshalb vor dem Teilen durchsehen.
- `shellcheck` war nicht installiert.
