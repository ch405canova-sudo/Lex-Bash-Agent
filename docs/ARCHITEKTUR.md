# Architektur

> Stand: v0.4.0 · Ergänzt [README.md](../README.md) (englisch) /
> [README.de.md](../README.de.md) (deutsch) — dort steht, *was* lex kann,
> hier *wie* es aufgebaut ist.

`lex` ist **eine einzige Datei** (~6240 Zeilen Pure Bash, `set -u` +
`set -o pipefail`, bewusst **kein** `set -e`) plus `jq` für JSON und `curl`
für HTTP. Alles, was folgt, sind Funktionen in dieser einen Datei — keine
Plugins, keine Klassen, kein Build-Schritt.

```
                 ┌──────────────────────────────────────────────┐
   Eingabe ────► │ agent_loop() / oneshot()      (REPL, Slashes)│
                 └───────────────┬──────────────────────────────┘
                                 ▼
                 ┌──────────────────────────────────────────────┐
                 │ run_turn()   DER LOOP (wird nie umgeschrieben)│
                 │  1. Kontextpflege (compaction, Warnung 85 %)  │
                 │  2. call_api() ──► SSE-Stream / JSON           │
                 │  3. parse: content oder tool_calls (fusioniert)│
                 │  4. dispatch_tool() je Call ──► weiter, bis     │
                 │     die Antwort ohne Tool-Call kommt           │
                 │  Guards: Fail-Gedächtnis, Fail-Streak,          │
                 │     Stille-Wächter, Wiederholungs-Erkennung     │
                 └───────────────┬──────────────────────────────┘
                                 ▼
                 ┌──────────────────────────────────────────────┐
                 │ display: Markdown-Licht, HUD, Trace ──► stderr│
                 │ Antwort ──► stdout (nur sie)                   │
                 └──────────────────────────────────────────────┘
```

## Schichten (von unten nach oben)

### 1. Konfiguration — vier Tiers

`load_config()` setzt Defaults (`_default_*`), dann
`~/.lex/settings.json`, dann `.lex/settings.json` im aktuellen Verzeichnis,
dann `LEX_*`-Umgebungsvariablen. Jeder Wert läuft durch `_int_or`/`_float_or`
— Nutzereingaben sind nie ungeprüft in `(( ))`. Details:
[docs/KONFIGURATION.md](KONFIGURATION.md).

### 2. Prompt-Aufbau — `setup_messages()` + `build_tools()`

Slot 0 ist der System-Prompt und **exklusiv**: ein Moduswechsel
(`/lexpen`, `_swap_slot0()`) ersetzt nur Slot 0, Verlauf und Wiki-Stand bleiben.
Der Prompt besteht aus

- Persona/Grundregeln (Slot 0),
- Ops-Bullets (Prüf-Regeln, Werkstatt-Verfahren, Scope-Regeln),
- Skills (`~/.lex/skills/<name>/SKILL.md`, Gates `LEX_SKILLS`, Budgets
  `LEX_SKILL_MAX`/`LEX_SKILL_TOTAL`),
- Präferenzen aus dem Memory (`_mem_pref_ex()`, `type: preference`, neueste
  zuerst, direkt hinter dem System-Prompt),
- Wiki-Stand (`_wiki_ex()`, optional, `LEX_WIKI_DIR`).

`_build_tools()` erzeugt das JSON-Schema der 19 nativen Tools; dazu kommen
ggf. MCP-Tools aus dem Discovery-Cache (`~/.lex/mcp.cache.json`, `mcp__Server__Tool`).

### 3. API — `call_api()`

`curl` gegen den OpenAI-kompatiblen Endpoint, optional als SSE-Stream:

- **Retries** bei 429/5xx und curl-Fehlern (`LEX_API_RETRIES`, Standard 2,
  max. 10, Backoff 0,8 → 8 s ± 25 % Jitter),
- `tool_calls` werden über **alle** Deltas fusioniert (Index/ID/Argument-Stücke),
- `usage` kommt aus dem Stream; fehlendes `[DONE]` wird ausdrücklich gewarnt,
- HTTP-Status **und** curl-Rückgabecode werden geprüft, Fehlerdetails als
  Snippet (400 B) mit `parse_error`-Hinweis.

### 4. Werkzeuge — `dispatch_tool()`

Vor jedem Lauf: Deny-Liste (immer aktiv) → `safe_path` → Approval-Gate
(`--approve`) → sudo-Gate → Hooks (`pre_tool` blockiert bei rc ≠ 0,
`post_tool` beobachtet). Danach:

- Ausführung unter `_run_limited()`: eigene Frist bei `secs`, Watchdog
  tötet die Kindkette tiefste-zuerst (`_kill_tree()`), GNU `timeout` nur als
  Rückfall — auch Enkelprozesse sterben (Test: §6-O7-Nadeln),
- **parallele Batches** für zustandslose Tools (`LEX_PARALLEL=off` schaltet
  das komplett ab), Ergebnisse in Original-Reihenfolge,
- **Spill statt Kappung**: Ergebnisse > `LEX_TOOL_MAX_OUTPUT` (50 000) kommen
  als Kopf + Ablagepfad in den Kontext, die volle Ausgabe liegt redigiert
  unter `~/.lex/log/tool_spill/` (Modus 600),
- **Self-Edit-Sandbox**: Edits auf `lex` selbst laufen auf einer Kopie durch
  `tools/selfcheck_lex.sh` **und** die volle Testsuite, erst bei rc 0 atomar
  ins Original (Sicherungskopie davor).

`span_log()` schreibt je Aufruf eine Zeile nach
`~/.lex/log/spans.jsonl` (`ts`, `name`, `args_hash`, `duration_ms`, `ok`) —
Argumente als Prüfsumme, nie als Payload. Auswertung: `lex --eval`.

### 5. Guards in `run_turn()`

| Wächter | Auslöser | Wirkung |
|---|---|---|
| Fail-Gedächtnis | 3× identische `cksum(name\|args\|result)` | weicher Nudge mit Antwortpflicht, dann Graceful-End (Abschlussrunde ohne Werkzeuge) |
| Fail-Streak | ≥ 6 bash-Fehler rc ≠ 0 in Folge | Anstoß „Methode wechseln" (`LEX_SILENT_TURNS` unberührt) |
| Stille-Wächter | ≥ 12 Turns ohne sichtbaren Text | Nudge, dann hart rc 1 (`LEX_SILENT_TURNS=0` aus) |
| Wiederholungs-Erkennung | `_rep_detect()` sieht Satz-Wiederholung | Nudge → Truncation, `LEX_LOOP_GUARD=off` schaltet die Klasse ab |
| Max Turns | `LEX_MAX_TURNS` (200) | Abbruch |
| Strg+C | `_sigint()` | laufender Turn abgebrochen, offene `tool_call`-IDs sauber beantwortet |

Alle Session-Ereignisse landen als Records in der JSONL-Session
(`{type:loop_guard|fail_streak|silent_guard|repetition|compaction|…}`).

## Kontextverwaltung

- **Schätzung**: `wc -c / 3` über den Nachrichten (live kalibriert),
- **Compaction**: `_compact_run()` greift ab
  `ctx − max(max_tokens, buffer)` (v0.4.0: 160 224 von 180 224), fasst ältere
  Einheiten zusammen (`_compact_units` gruppiert Assistant-Tool-Calls mit
  folgendem Tool-Result), behält den Tail, Marker `<!--lex-compact-->` in
  Slot 1; **Gate G0–G8** — kommt das Summary leer zurück, bleibt `_messages`
  byte-identisch (Fail-safe),
- **Warnung** ab 85 % unabhängig von `LEX_COMPACT`,
- **HUD**: `tokens X/Y (Z%) prompt + …` vor der Antwort.

## Zustand auf der Platte

```
~/.lex/
├── settings.json      Konfiguration (Tier 2)
├── mcp.json           MCP-Server-Standorte (überschreibt die Defaults)
├── mcp.cache.json     Discovery-Cache (argv + Tool-Liste)
├── log/               lex.log, spans.jsonl, tool_spill/
├── sessions/<id>/     session.jsonl (append-only, redigiert)
├── mem/               Markdown mit YAML-Frontmatter (memory/fact/preference/note)
├── prompts/           lexpen.md (frei editierbar)
├── skills/<name>/     SKILL.md je Skill
├── hooks/pre_tool/    ausführbar? rc ≠ 0 blockiert den Tool-Aufruf
├── hooks/post_tool/   ausführbar? beobachtet jeden Lauf
└── tasks/<id>/        Hintergrund-Tasks (eigene Sitzung, rc-Datei)
```

Nichts wird außerhalb von `$HOME` geschrieben. `LEX_HOME` verschiebt das
ganze Verzeichnis (die Tests nutzen das für Isolation).

## Eingabe-/Ausgabe-Vertrag

- **stdout**: nur die finale Antwort des Modells,
- **stderr**: Prompt, Trace, Denk-Block, Spinner, HUD, Warnungen — und nur bei
  einem Terminal (oder `LEX_TRACE=1`),
- **Redigierung** (`_redact`) greift in `lex.log`, `session.jsonl`, Anzeige
  und Wiki-Schreibpfaden — Modellkontext und das Schreiben von Configs/
  Scripts bleiben bewusst unredigiert (das Modell braucht das Literal).

Damit bleiben Pipes, Dateien und Tests roh und unveränderlich.

## Erweiterungspunkte

| Punkt | Datei/Weg | Wirkung |
|---|---|---|
| Hooks | `~/.lex/hooks/{pre,post}_tool/` | blockieren bzw. beobachten jeden Tool-Aufruf |
| Skills | `~/.lex/skills/<name>/SKILL.md` | gehen in den System-Prompt |
| Persona | `~/.lex/prompts/lexpen.md` | `/lexpen` tauscht Slot 0 |
| MCP | `~/.lex/mcp.json` | eigene stdio-Server, `mcp(server, tool)` |
| Config | `settings.json` + `LEX_*` | vier Tiers, ENV gewinnt |
| Modell-Endpunkt | `LEX_API_URL` | beliebiger OpenAI-kompatibler Server |

## Testpyramide

15 Läufer (`testboden` + `syntax` + 13 Testdateien), 1055 Einzelf-Prüfungen,
alle offline:

| Läufer | Gegenstand |
|---|---|
| `testboden` | verhindert, dass Testdateien verschwinden, gelöscht oder uneingebunden bleiben |
| `syntax` | `bash -n` über `lex`, `tools/*.sh`, `test/*.sh` |
| `test_input.sh` | Eingabe-/Readline-Pfad, Strg+C, Env-Isolation |
| `test_tools.sh` | Werkzeug-Schema, `dispatch_tool` |
| `test_selfedit.sh` | Sandbox + die zwei Gates |
| `test_loop.sh` | Guards in `run_turn` (Fail-Gedächtnis, Fail-Streak, Stille-Wächter) |
| `test_http.sh` | HTTP-Pfad gegen einen echten Fake-Server (`ncat`) |
| `test_features.sh` | die große Nadel-Sammlung (Prompt-Anker, Gates, Limits, Pfad-Wahrheit) |
| `test_mem_pref.sh` | Präferenz-Injektion |
| `test_proxy.sh` | Debug-Proxy `tools/llama-proxy.sh` |
| `test_sse.sh` | Streaming inkl. **Performance-Budget** (3000 Chunks < 2 s) |
| `test_eval.sh` | Spans + `lex --eval` |
| `test_limits.sh` | nichts wird an der lex↔llama-Grenze abgeschnitten |
| `test_compaction.sh` | Schwelle, Gates G0–G8, HUD, Recompact |
| `test_repetition.sh` | Wiederholungs-/Loop-Erkennung |

Regeln: nie Port 8080, immer Mock oder Fake-Server, Fixture-Tests müssen den
Pfad auch brechen können, `shellcheck -S warning` muss sauber bleiben.
