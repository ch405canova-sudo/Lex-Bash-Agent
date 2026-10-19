# lex

[![lex CI](https://github.com/ch405canova-sudo/Lex-Bash-Agent/actions/workflows/ci.yml/badge.svg)](https://github.com/ch405canova-sudo/Lex-Bash-Agent/actions)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
![version](https://img.shields.io/badge/version-0.4.0-blue)
![tests](https://img.shields.io/badge/tests-15%20L%C3%A4ufer%20%C2%B7%201055%20Pr%C3%BCfungen-brightgreen)

**Ein Terminal-Agent für lokale LLMs, in purem Bash geschrieben.** Eine
ausführbare Datei, kein Runtime, kein Framework, kein Docker: `bash`, `jq` und
`curl` sind die einzigen harten Abhängigkeiten. lex spricht das OpenAI-Chat-
Protokoll gegen einen lokalen `llama-server`, führt Werkzeuge auf deiner
Maschine aus, pflegt sein eigenes Gedächtnis — und verlässt nie den Endpoint,
den du konfigurierst.

- **19 Tools** (Dateien, Shell, Suche, Web, Browser, MCP, Sub-Agenten, Hintergrund-Tasks)
- **15 Testläufer / 1055 Prüfungen**, alle offline — Mocks plus Fake-HTTP-Server, nie Port 8080
- **Zustand liegt in `~/.lex/`** — nichts wird außerhalb von `$HOME` geschrieben
- **Sicherheit eingebaut**: harte Deny-Liste, sudo-Gate, opt-in Approval-Modus, Hooks, Self-Edit-Sandbox
- Sprache: lex antwortet selbst **deutsch** (bewusste Entscheidung), Doku zweisprachig

**Dokumentation:** [docs/ARCHITEKTUR.md](docs/ARCHITEKTUR.md) ·
[docs/KONFIGURATION.md](docs/KONFIGURATION.md) · [CHANGELOG.md](CHANGELOG.md)
· english: [README.md](README.md)

---

## Schnellstart

```bash
git clone https://github.com/ch405canova-sudo/Lex-Bash-Agent.git
cd Lex-Bash-Agent

./install.sh      # interaktiv: Abhängigkeiten prüfen, ~/.lex/ anlegen, `lex` und `ai` verlinken
./ai.sh start     # lokalen llama-server starten (Port 8080) — oder deinen eigenen
lex               # REPL
```

Jeder Befehl geht auch ohne Interaktion:

```bash
./lex --oneshot       # ein Prompt von stdin, Antwort nach stdout
./lex --status        # Konfigurations- und Laufzeitstatus
./lex --approve       # REPL, jede Shell-Ausführung wird abgefragt (TTY nötig)
./lex --eval          # Auswertung aus dem Span-Log (spans.jsonl)
./lex --install       # ~/.lex/ anlegen (log/, sessions/, mem/, …)
./lex --version       # lex 0.4.0
./lex --help          # Modi, Slash-Befehle, ENV-Liste
```

Vorkonfiguriert sein muss nichts: lex zielt standardmäßig auf
`http://127.0.0.1:8080/v1/chat/completions` und fällt im Mock-Modus
(`LEX_MOCK=done`) komplett ohne Server aus.

## Voraussetzungen

| Werkzeug | Zweck | Fehlt? |
|---|---|---|
| Bash ≥ 4 | das Skript selbst (`coproc`; getestet mit 5.2 — macOS-Systembash 3.2 reicht nicht: `brew install bash`) | harte Anforderung |
| jq | JSON für das OpenAI-Protokoll | harte Anforderung |
| curl | HTTP an den Server | harte Anforderung |
| `timeout`, `realpath`, `readlink -f` | Zeitlimit/Pfad-Normalisierung | **Fallbacks eingebaut** (`command -v`-Guard) |
| ncat | Fake-Server für `test_http.sh` | nur für Tests |
| shellcheck | Lint | nur für CI/Entwicklung |
| python3 | HTML-/Such-Fixtures in `test_features.sh`, JSON-Helfer in `test_proxy.sh` | nur für Tests |
| node (v20) + MCP-Server | `web_fetch`, `context7`, `browser`, `mcp` | nur diese Tools — ohne sie kommt eine klare Fehlermeldung |

## REPL-Slash-Befehle

Genau wie `lex --help` sie ausgibt:

| Befehl | Wirkung |
|---|---|
| `/status` | dasselbe wie `--status` |
| `/server` | Server-/Port-Status |
| `/compact` | Kontext jetzt komprimieren (Summary + Tail bleiben) |
| `/plan` | aktuellen Plan (todo-Liste) anzeigen |
| `/lexpen` | System-Prompt auf die Lex-Persona (Senior-Engineer-Stil) |
| `/lex` | zurück zum Original-Prompt |
| `/autosudo` | y/N-Freigaben im sudo-Gate automatisch beantworten (`on`/`aus`, jede andere Eingabe zeigt den Status) |
| `/help` | diese Hilfe |
| `/exit`, `/quit` | REPL beenden (auch Ctrl-D) |

Der Prompt-Marker zeigt den aktiven Modus (`lex>` bzw. `lex*>`); Slot 0 des
Kontexts ist exklusiv — einer verdrängt den anderen.

## Tools (19)

`read_file`, `write_file`, `edit_file` (mit `all` für alle Vorkommen),
`append_file`, `bash`, `list_files` (+ `pattern`, `recursive`), `search`,
`fetch` (Rohquelle nach `<wiki>/raw/<topic>/`), `todo` (Planung),
`mem_add`, `mem_list`, `mem_search`, dazu:

- **`web_search(query)`** — Websuche **ohne API-Key** (DuckDuckGo): Titel,
  URL und Ausschnitt, Redirects (`uddg=`) und HTML-Entities aufgelöst;
  `LEX_SEARCH_URL` tauscht den Endpunkt (die Tests nutzen das, damit **kein
  Test ins Netz geht**)
- **`web_fetch(url, max_length?)`** — eine bekannte Seite als Klartext per
  **Crawler** (MCP defuddle), ohne Ablage — für Quellen mit Ablage weiter
  `fetch(url, topic)`
- **`context7(query, library?)`** — **aktuelle** Bibliotheken-Doku (MCP
  context7), der Gegenpol zum trainierten Modellwissen
- **`browser(action, …)`** — echter Browser über MCP playwright: navigate →
  snapshot lesen → nach ref klicken/tippen; der Snapshot ist Text, kein
  Screenshot
- **`mcp(server, tool?, arguments?)`** — generischer Zugriff, zuerst
  `__tools` als Discovery-Liste
- **`agent(task, mode)`** — Sub-Agent mit **frischem Kontext**
  (explore/plan/review/summarize), Tiefen-Gate, Ergebnis ist reine Textausgabe
- **`task(action, …)`** — **Hintergrund-Tasks** (`start/list/status/result/kill`)
  unter `~/.lex/tasks/<id>/`, eigene Sitzung, nach Ende von lex lesbar

### Memory und Sessions

Memory liegt als Markdown mit YAML-Frontmatter unter `~/.lex/mem/` (Typen
`memory`, `fact`, `preference`, `note`). `type: preference` wird **direkt
hinter** den System-Prompt injiziert (neuester Eintrag gewinnt, Gates
`LEX_MEM_PREF=off`, Budgets `LEX_MEM_PREF_MAX`/`LEX_MEM_PREF_TOTAL`).

Jede Konversation wird append-only als JSONL unter
`~/.lex/sessions/<id>/session.jsonl` gespeichert — inklusive
`reasoning_content`, das bewusst **nicht** in den Modell-Kontext geschrieben
wird (Kontextschutz). `session_write` redigiert jede Zeile vor dem Anhängen,
damit kein Secret auf der Platte landet.

## Oberfläche (CLI mit TUI-Gefühl)

Kein curses-TUI — strukturierte Ausgabe über ANSI, ohne neue Abhängigkeiten:

- `lex>`-Prompt (blau/fett, nur bei TTY; `NO_COLOR` und `TERM=dumb` schalten
  alle Farben ab), **Readline**-Eingabe: Pfeiltasten, Ctrl-A/E/W/U, **Tab =
  Pfadvervollständigung**, History unter `~/.lex/history`
- `⚙ denken:` — was das Modell gedacht hat (`reasoning_content`): Header
  dim-magenta, Inhalt **grau und eingerückt** auf **stderr**, aus mit
  `LEX_SHOW_REASONING=0`
- `⏳ denke …`-Spinner ab 250 ms, `⚙ tool args` für laufende Werkzeuge,
  `↳ tool` mit eingerückter Rückgabe
- `⏱ 3,2s · turn 2/50 · tokens 1409/180224 (1%) prompt + 69 completion` —
  Timing und Kontextauslastung erscheinen **vor** der Antwort, damit sie das
  Letzte auf dem Bildschirm sind
- Markdown-Licht für die Antwort: H1 fett+unterstrichen, H2 fett cyan,
  Tabellen sauber gesetzt, `[[wikilinks]]`, Warnung orange, Fehler rot, `✓` grün
- **Nur die Antwort steht auf stdout** — alles andere läuft auf **stderr** und
  nur bei einem Terminal (bzw. mit `LEX_TRACE=1`), damit Pipes, Dateien und
  Tests roh bleiben

## Context-Compaction

lex schätzt den Prompt (`Bytes ÷ 3`, live gegen `prompt_tokens` kalibriert)
und fasst ältere Nachrichten zusammen, sobald `ctx − max(max_tokens, buffer)`
(Default **160224** von **180224**) erreicht ist (Marker `<!--lex-compact-->`,
Kontext-Integrität als Gate — kommt das Summary leer zurück, ändert sich
nichts). `/compact` erzwingt den Lauf, `LEX_COMPACT=0` schaltet ihn ab,
`LEX_COMPACT_KEEP`/`LEX_COMPACT_BUFFER` justieren Tail/Schwelle,
`LEX_CTX_LIMIT` setzt die angenommene Kontextgröße. Eine Warnung ab 85 %
läuft unabhängig von dem Schalter.

## MCP & Websuche

Zwei eingebundene MCP-Server laufen über **stdio** (JSON-RPC 2.0), eine
Session pro Aufruf:

| Server | Tool(s) | Startkommando (Default) |
|---|---|---|
| `defuddle` | `web_fetch` | `node ~/.mcp/node_modules/defuddle-stdio-mcp/index.js` |
| `context7` | `context7` | `~/.local/bin/context7-mcp` |

Die Standorte liegen in **`~/.lex/mcp.json`** (ohne Datei gelten die obigen
Defaults, dazu `playwright`, `desktop` und `postgres`). `LEX_MCP=0` schaltet
beide Tools ab, `LEX_MCP_TIMEOUT` (Standard 60 s) begrenzt jeden Aufruf.
Discovery-Ergebnisse werden in `~/.lex/mcp.cache.json` gecacht, damit
`--status` den vollen nativen Tool-Satz zeigen kann.

## Sicherheit

- **`tool_bash` hat eine harte Deny-Liste, die immer aktiv ist**, und zerlegt
  das Kommando in Segmente (`&&`, `||`, `|`, `;`, Zeilenumbruch):
  - `rm` auf Root/Home/`.` — auch `rm -rf -- /`, `sudo rm -rf /`, `xargs rm -rf /`
  - Download in eine Shell — auch `curl … | sh | cat`
  - `su` als Kommando-Wort, Blockgeräte (`mkfs`, `of=/dev/`, `dd … of=/dev/…`),
    Fork-Bomben, Neustart/Herunterfahren, Systemprozesse killen, `history -c`
- **sudo ist kein Verbot, sondern ein Gate**: ohne gültiges Ticket zeigt lex
  **genau eine** Aufforderung auf dem TTY mit dem Kommando — das Passwort läuft
  direkt an sudo und nie durch lex (keine Variable, kein Log). Mit gültigem
  Ticket fragt lex **einmal pro Sitzung**
  (`sudo für diese ganze Sitzung freigeben? (y/N)`). Ohne controlling TTY keine
  sudo-Ausführung. `LEX_SUDO=0` sperrt sudo komplett,
  `LEX_SUDO_APPROVE=0` lässt die Sitzungsfrage weg.
- **Opt-in Approval für jede Shell-Ausführung**: nur mit `--approve` oder
  `LEX_APPROVE=1` **und** controlling TTY — ohne Flag läuft lex prompt-frei
  (Tests bleiben deterministisch).
- **`safe_path`** erlaubt nur Pfade außerhalb von `/etc`, `/usr`, `/bin`,
  `/sbin`, `/boot`, `/dev`, `/proc`, `/sys`, `/var`, `/lib`, `/lib64`, `/root` —
  auch die nackten Wurzeln, und Symlink-Ziele werden aufgelöst und geprüft.
- **Hooks**: ausführbare Dateien in `~/.lex/hooks/pre_tool/` (rc ≠ 0 blockiert
  den Tool-Aufruf) und `~/.lex/hooks/post_tool/` (beobachtet), `LEX_HOOKS=off`,
  `LEX_HOOK_TIMEOUT`, je Lauf `LEX_HOOK_EVENT/TOOL/ARGS/RC`.
- **Self-Edit-Sandbox**: ein Edit, dessen Ziel das `lex`-Skript selbst ist,
  läuft auf einer Kopie und muss **zwei Gates** bestehen
  (`tools/selfcheck_lex.sh`, danach volle `test/run_all.sh`), bevor er atomar
  übernommen wird; ein rotes Gate lässt das Original byte-identisch.
- **Redigierung**: `_redact` maskiert Zugangsdaten in Log, Session, Anzeige
  und Wiki-Schreibpfaden; übergroße Tool-Ausgaben landen im Spill auf der
  Platte (`~/.lex/log/tool_spill/`, Modus 600), statt still gekürzt zu werden.

## Konfiguration (4-Tier)

```
Defaults → ~/.lex/settings.json → .lex/settings.json (CWD) → ENV
```

Wichtige ENV-Variablen: `LEX_API_URL`, `LEX_MODEL`, `LEX_API_KEY`,
`LEX_MAX_TOKENS`, `LEX_REASONING_BUDGET`, `LEX_TEMPERATURE`, `LEX_MAX_TURNS`,
`LEX_TOOL_TIMEOUT`, `LEX_TOOL_MAX_OUTPUT`, `LEX_LOG_DIR`, `LEX_MOCK`,
`LEX_MOCK_FILE`, `LEX_APPROVE`, `LEX_SUDO`, `LEX_SUDO_APPROVE`, `LEX_SESSION`,
`LEX_MEM_DIR`, `LEX_WIKI_DIR`, `LEX_HTOOLS_DIR`, `LEX_TRACE`,
`LEX_SHOW_REASONING`, `LEX_REASONING_MAX`, `LEX_MCP`, `LEX_MCP_TIMEOUT`,
`LEX_SEARCH_URL`, `LEX_SEARCH_TIMEOUT`, `LEX_CTX_LIMIT`, `LEX_COMPACT`,
`LEX_COMPACT_KEEP`, `LEX_COMPACT_BUFFER`, `LEX_API_RETRIES`, `LEX_LOOP_GUARD`,
`LEX_SELFEDIT_GATES` — vollständige Liste in `lex --help`, Details in
[docs/KONFIGURATION.md](docs/KONFIGURATION.md).

## Tests

```bash
./test/run_all.sh          # 15 Läufer / 1055 [PASS], Exit 0 nur wenn alles grün
shellcheck -S warning lex ai.sh install.sh test/*.sh tools/*.sh
```

Der erste Läufer ist **`testboden`**: er bricht ab, wenn eine Testdatei
gelöscht, als Runner referenziert aber nicht vorhanden oder vorhanden aber nicht
eingebunden ist. Tests sind assert-basiert (`[ "$out" = "erwartet" ]`), geben
auf stdout aus und beenden mit Exit 1 bei Fehlschlag.

Regeln der Suite:

- **Kein Netzwerk, kein Server** — `LEX_MOCK=done` (statisch), `LEX_MOCK_FILE`
  (Sequenz, Quelldatei bleibt unversehrt) oder der mitgelieferte Fake-Server
  (`test/fake_server.sh` über `ncat`). Ein echter Request an
  `127.0.0.1:8080` findet nie statt.
- Der **HTTP-Pfad wird mitgetestet**: `test/test_http.sh` fährt einen echten
  Fake-Server hoch; `test/test_sse.sh` deckt Streaming ab (Delta-Fusion,
  `data:` ohne Leerzeichen, fehlendes `[DONE]`, Server weg, HTTP-Fehler) —
  inklusive **Performance-Budget** (3000 Chunks < 2 s mit Inhaltsprüfung; es
  dauerte früher 29 s).
- Fixture-Tests müssen den Pfad auch **brechen können**: rote Läufe gehören
  zur Definition of Done, nicht nur grüne.

## Auswertung (Observability)

Jeder `dispatch_tool`-Aufruf schreibt einen Span nach
`~/.lex/log/spans.jsonl` (`ts`, `name`, `args_hash`, `duration_ms`, `ok` — die
Argumente landen als Prüfsumme in der Zeile, nicht als Payload):

```bash
./lex --eval                  # aktuelle Session
./lex --eval /pfad/spans.jsonl
```

Der Bericht liefert ein Verdict, eine Pro-Tool-Sektion und die letzten Spans.

Der API-Pfad ist gegen Streaming **und** klassische JSON-Antworten
abgesichert: curl-Rückgabecode **und** HTTP-Status werden geprüft, `tool_calls`
über alle Deltas fusioniert, `usage` kommt aus dem Stream, ein fehlendes
`[DONE]` wird ausdrücklich gewarnt. 429/5xx und curl-Fehler werden wiederholt
(`LEX_API_RETRIES`, Standard 2, max. 10, Backoff 0,8 → 8 s mit Jitter).

## Debug-Proxy (Traffic mitlesen)

```bash
LEX_PROXY_UPSTREAM=http://127.0.0.1:8080 ./tools/llama-proxy.sh start 24480
LEX_API_URL=http://127.0.0.1:24480/v1/chat/completions ./lex --oneshot
./tools/llama-proxy.sh show 1     # n-ter Request UND Response, roh + eingerückt
./tools/llama-proxy.sh tail 20    # traffic.log
./tools/llama-proxy.sh status | stop
```

Er protokolliert nach `.proxy/` (gitignore), lauscht **nur auf 127.0.0.1** und
lehnt Port 8080 ab.

## Repository-Struktur

```
lex                 der Agent — eine Datei (6242 Zeilen, 19 Tools)
install.sh          interaktives Setup (~/.lex/ + Links nach ~/.local/bin)
ai.sh               llama-server-Launcher (start/stop/status, per Env konfigurierbar)
test/               run_all.sh + 13 Testdateien + fake_server.sh + fake_mcp.sh (15 Läufer)
tools/              selfcheck_lex.sh, llama-proxy.sh, pentest_mcp.sh,
                    ctx_bench.sh, werkstatt_index.sh, amnesie_test_setup.sh
docs/               ARCHITEKTUR.md, KONFIGURATION.md
.github/workflows/  CI: bash -n → shellcheck → run_all → Installer → Hygiene-Check
```

## Lizenz

[MIT](LICENSE) — Copyright (c) 2026 ch405canova-sudo.
