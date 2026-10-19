# Konfiguration

> Stand: v0.4.0 · Der komplette ENV-Katalog steht in `lex --help`,
> der effektive Zustand in `lex --status`.

## Die vier Tiers

```
1. Defaults aus dem Skript          (_default_*, siehe Tabelle unten)
2. ~/.lex/settings.json             persönliche, maschinenweite Konfiguration
3. .lex/settings.json (CWD)         projektweise Konfiguration, gewinnt gegenüber 2
4. LEX_*-Umgebungsvariablen         gewinnt immer
```

Regeln:

- **ENV schlägt settings.json**, settings.json schlägt Defaults — es gibt
  keine weitere Konfigurationsquelle (keine rc-Datei, kein Flag-Dschungel).
- Ein **kaputtes `settings.json` ist kein stiller Ausfall**: der Syntaxfehler
  wird geloggt und die Defaults greifen (`log "settings: … ist kein gültiges
  JSON"`), fehlende Keys dagegen sind normal.
- Alle Werte laufen durch `_int_or`/`_float_or` — ein Textwert kann lex nie
  in einem `(( ))` abstürzen lassen.
- `lex --status` zeigt, was tatsächlich gilt (inkl. `htools`, `compact`,
  `ctx`, Session- und Memory-Zahlen).

### `settings.json` — unterstützte Keys

```json
{
  "api_url": "http://127.0.0.1:8080/v1/chat/completions",
  "api_key": "",
  "model": "/pfad/zum/modell.gguf",
  "max_tokens": 16384,
  "reasoning_budget_tokens": 2048,
  "reasoning_budget_followup": 768,
  "temperature": 0.7,
  "api_retries": 2,
  "max_turns": 200,
  "max_nudges": 4,
  "silent_turns": 12,
  "tool_timeout": 300,
  "tool_max_output": 50000,
  "log_dir": "/home/du/.lex/log",
  "ctx_limit": 180224,
  "compact": "on",
  "compact_keep": 15000,
  "compact_buffer": 20000,
  "auto_disable_thinking_with_tools": "off"
}
```

Alles andere (Hooks, Skills, MCP, Sicherheits-Gates, …) wird ausschließlich
über ENV gesetzt — bewusst, weil es sich um Laufzeit-Schalter handelt.

## ENV-Variablen

### Server & Modell

| Variable | Default | Bedeutung |
|---|---|---|
| `LEX_API_URL` | `http://127.0.0.1:8080/v1/chat/completions` | OpenAI-kompatibler Endpoint |
| `LEX_API_KEY` | leer | nur wenn der Server es verlangt |
| `LEX_MODEL` | `<übergeordnetes Verzeichnis>/model/Ternary-Bonsai-2-27B-PQ2_0.gguf` | Modell-Pfad/Name im Request-Body |
| `LEX_MAX_TOKENS` | `16384` | Antwortbudget pro Turn |
| `LEX_REASONING_BUDGET` | `2048` | Budget für den ersten Turn |
| `LEX_REASONING_BUDGET_FOLLOWUP` | `768` | Budget für Folge-Turns |
| `LEX_AUTO_DISABLE_THINKING_WITH_TOOLS` | `off` | Denken bei Tool-Calls abschalten |
| `LEX_TEMPERATURE` | `0.7` | Sampling |
| `LEX_API_TIMEOUT` | `1800` | Sekunden pro Request |
| `LEX_API_RETRIES` | `2` (max. 10) | Wiederholungen bei 429/5xx/curl-Fehlern, Backoff 0,8 → 8 s ± 25 % |

### Loop & Kontext

| Variable | Default | Bedeutung |
|---|---|---|
| `LEX_MAX_TURNS` | `200` | harte Obergrenze Turns je Aufgabe |
| `LEX_MAX_NUDGES` | `4` | Anstöße vor dem harten Abbruch |
| `LEX_SILENT_TURNS` | `12` | Stille-Wächter (`0` = aus) |
| `LEX_LOOP_GUARD` | `on` | Fail-Gedächtnis bei identischen Tool-Läufen |
| `LEX_CTX_LIMIT` | `180224` | angenommene Kontextgröße (HUD + Compaction) |
| `LEX_COMPACT` | `on` | Auto-Compaction |
| `LEX_COMPACT_KEEP` | `15000` | Tail-Budget (Bytes) |
| `LEX_COMPACT_BUFFER` | `20000` | Schwellen-Buffer |
| `LEX_MD_CELL_MAX` | `0` | Tabellenzellen-Kappe (`0` = aus) |

### Werkzeuge

| Variable | Default | Bedeutung |
|---|---|---|
| `LEX_TOOL_TIMEOUT` | `300` | Zeitlimit je Tool-Lauf (Kill-Baum greift) |
| `LEX_TOOL_MAX_OUTPUT` | `50000` | darüber wird ins Spill-File geschrieben statt gekürzt |
| `LEX_PARALLEL` | `on` | zustandslose Tools parallel im Batch |
| `LEX_AGENT_MAX_TURNS` | `15` | Turns eines Sub-Agenten |
| `LEX_TASK_MAX` | `5` | gleichzeitig laufende Hintergrund-Tasks |
| `LEX_TASK_TIMEOUT` | `0` | Sekunden je Task (`0` = ohne) |

### Sicherheit

| Variable | Default | Bedeutung |
|---|---|---|
| `LEX_APPROVE` | `0` | `1` = jede bash-Ausführung wird abgefragt (TTY nötig) |
| `LEX_SUDO` | `1` | `0` = sudo komplett gesperrt |
| `LEX_SUDO_APPROVE` | `1` | `0` = Sitzungs-Freigabefrage aus |
| `LEX_AUTOSUDO` | `0` | `1` = y/N-Freigaben automatisch bejahen (unbediente Läufe) |
| `LEX_TOR` | `1` | `0` = Tor-Stealth-Aufrufe am `/lexpen`-Wechsel aus |
| `LEX_SELFEDIT_GATES` | `full` | `fast`\|`off` nur mit **sichtbarer** Warnmeldung im Tool-Ergebnis |
| `LEX_SELFEDIT_TIMEOUT` | `300` | Sekunden je Gate (danach Fehlschlag) |
| `LEX_HOOKS` | `on` | `off` = Hooks ganz aus |
| `LEX_HOOK_TIMEOUT` | `5` | Sekunden je Hook-Lauf |

### Anzeige

| Variable | Default | Bedeutung |
|---|---|---|
| `LEX_TRACE` | leer | `1` = Trace/HUD/Spinner auch ohne Terminal |
| `LEX_TRACE_RESULT_MAX` | `0` | Tool-Rückgabe kürzen (`0` = vollständig) |
| `LEX_SHOW_REASONING` | `1` | `0` = Denk-Block aus |
| `LEX_REASONING_MAX` | `0` | Denk-Block kürzen (`0` = vollständig) |
| `LEX_REASONING_STORE_MAX` | `20000` | Obergrenze des **gespeicherten** Reasoning in der Session |

### Memory, Skills, Wiki

| Variable | Default | Bedeutung |
|---|---|---|
| `LEX_HOME` | `~/.lex` | Wurzel des gesamten Zustands |
| `LEX_MEM_DIR` | `~/.lex/mem` | Memory-Store |
| `LEX_MEM_PREF` | `on` | Präferenzen in den Prompt injizieren |
| `LEX_MEM_PREF_MAX` | `2000` | Zeichen je Präferenz |
| `LEX_MEM_PREF_TOTAL` | `6000` | Summe über alle Präferenzen |
| `LEX_SKILLS` | `on` | Skills in den Prompt injizieren |
| `LEX_SKILL_MAX` | `6000` | Zeichen je Skill-Datei |
| `LEX_SKILL_TOTAL` | `40000` | Summe über alle Skills |
| `LEX_WIKI_DIR` | `<übergeordnetes Verzeichnis>/wiki` | Wissens-Wurzel (`raw/` + `wiki/`) |
| `LEX_HTOOLS_DIR` | `$HOME/H-Tools` | Werkstatt-/Softwareverzeichnis |

### MCP & Websuche

| Variable | Default | Bedeutung |
|---|---|---|
| `LEX_MCP` | `1` | `0` = MCP-Tools abschalten |
| `LEX_MCP_TIMEOUT` | `60` | Sekunden je MCP-Aufruf |
| `LEX_SEARCH_URL` | `https://html.duckduckgo.com/html/` | Suchendpunkt (Tests setzen einen lokalen) |
| `LEX_SEARCH_TIMEOUT` | `20` | Sekunden je Suche |

### Sessions & Tests

| Variable | Default | Bedeutung |
|---|---|---|
| `LEX_SESSION` | `1` | Session-JSONL schreiben |
| `LEX_LOG_DIR` | `~/.lex/log` | Log, Spans, Spill |
| `LEX_MOCK` | leer | `done` = statische Mock-Antwort (Tests, **nie** Port 8080) |
| `LEX_MOCK_FILE` | leer | JSONL-Sequenz als Antwortfolge (Quelldatei bleibt unversehrt) |

## Typische Setups

```bash
# 1. Ohne eigenen Server ausprobieren
echo "Sag Hallo" | LEX_MOCK=done ./lex --oneshot

# 2. Eigenen Endpoint ansprechen
export LEX_API_URL=http://127.0.0.1:8081/v1/chat/completions
export LEX_MODEL=/mnt/modele/mein-modell.gguf
export LEX_CTX_LIMIT=131072

# 3. Unbedient / CI-fest: keine Nachfragen, keine Farben, kein Denk-Block
LEX_APPROVE=0 LEX_SUDO=0 NO_COLOR=1 LEX_SHOW_REASONING=0 ./lex --oneshot < prompt.txt

# 4. Isolierter Zustand (Tests, Experimente)
LEX_HOME=/tmp/lex-test ./lex --status
```

## Siehe auch

- [docs/ARCHITEKTUR.md](ARCHITEKTUR.md) — wo die Werte verarbeitet werden
- [README.md](../README.md) · [README.de.md](../README.de.md) — Start, Tools, Sicherheit
- `lex --help` — vollständige ENV-Liste, Modi, Slash-Befehle
