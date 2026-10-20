# Changelog

Alle bemerkenswerten Änderungen, neueste zuerst. Datum = Tag.
Ältere Releases sind als Git-Tags referenzierbar (`git tag -l`).

## v0.5.1 — 2026-10-20

- **Fix der REPL-Eingabe bei schmalen Fenstern** — nach den
  Prompt-Optimierungen brach die Eingabezeile bei unzureichend breiten
  Terminals nicht mehr um und überschrieb sich je nach Fenstergröße.
  Ursache: readline zählt Farbescapes im `read -p`-Prompt als sichtbare
  Zeichen (+12), rechnet Prompt-Breite 17 statt 5 und zeichnet die Zeile
  mit falschem Offset neu (gleiche Offset-Klasse wie der Prompt-Bug vom
  2026-10-08; bewiesen per gerendertem tmux-Bild, nicht per Byte-Stream).
  Das Prompt-Label ist wieder schlicht `lex> ` — **fett neon-grün bleibt
  auf der eingegebenen Zeile nach ENTER**, wo es keine Breitenrechnung
  gibt und genau dort, wo die Eingabe dauerhaft im Verlauf stehen soll.

## v0.5.0 — 2026-10-20

Fristen gehören ins Werkzeug, Pipes dürfen nicht kürzen, und die REPL
färbt sich. Alle Zahlen stammen aus einem grünen Lauf der Suite
(`bash test/run_all.sh` → **15 Läufer, 1077 [PASS], 0 FAIL**).

### Geändert

- **Private Datenbank-Anbindung vollständig aus dem öffentlichen Baum entfernt**
  — sie war Teil der MCP-Default-Vorlage (`_mcp_config`), eines Prompt-Bullets
  (Server + Zielpfad), der `mcp`-Beispielliste und beider READMEs. Jetzt
  liegen in der Vorlage **4 Server** (defuddle, context7, playwright, desktop);
  eine eigene Anbindung konfiguriert jeder selbst unter `~/.lex/mcp.json`. Eine
  Nadel erzwingt den Zustand: kein Datenbank-Eintrag in der Default-Config.
- **`tool_bash` nimmt pro Lauf eine Frist** (`timeout`, Sekunden) — die
  Laufzeit eines Recon-Laufs ist unschätzbar, deshalb gehört die Frist ins
  Werkzeug (`-maxtime`, `--host-timeout`), wo der Lauf selbst sauber abbricht;
  der globale Default bleibt Sicherheitsnetz gegen echte Hänger.
- **Prompt lehrt kein Pipe-Kürzen mehr** — `head` in einer Pipe bricht unter
  `pipefail` mit rc 141 ab (der folgende Befehl läuft nie) und lässt
  puffernde Tools auf EPIPE hängen; Kürzen erledigt der Spill.
- **Frist-Hinweis in `_run_limited` repariert** — die Prüfung lief nach `rm`
  und prüfte `-s` (toter Code), der Hinweis kam nie an; jetzt davor, `-e`,
  und der Werkzeug-Output bleibt bei Ablauf erhalten statt überschrieben.
- **Reasoning wird nie mehr mitten im Satz abgeschnitten** — die Budget-
  Kappung ist zurückgenommen.
- **REPL-Eingabe fett neon-grün und dauerhaft im Verlauf** — nach ENTER
  wird die eingegebene Zeile vor der Turn-Ausgabe fest ausgegeben (fett
  bright green), sodass sie Spinner/Reasoning nicht verliert; Pipes,
  `--oneshot` und die Suite behalten byte-identische Ausgabe. Dabei kam
  auch der farbige `lex>`-Prompt-Label zum Vorschein: er war seit
  Einführung nie angekommen, weil `_prompt` in `$(_prompt)` läuft, deren
  stdout immer eine Pipe ist — die TTY-Entscheidung wird jetzt beim Start
  gepuffert.

## v0.4.0 — 2026-10-19

Das deutsche Original ist jetzt die Basis dieser Repository, und die Doku ist
komplett neu. Alle Zahlen stammen aus einem grünen Lauf der Suite
(`bash test/run_all.sh` → **15 Läufer, 1055 [PASS], 0 FAIL**).

### Neu

- **README neu** — zweisprachig: [README.md](README.md) (EN) und
  [README.de.md](README.de.md) (DE), mit Schnellstart, Security-, Test- und
  Strukturabschnitt
- **[docs/ARCHITEKTUR.md](docs/ARCHITEKTUR.md)** — Schichten, Loop, Guards,
  Zustandsverzeichnis, Erweiterungspunkte, Testpyramide
- **[docs/KONFIGURATION.md](docs/KONFIGURATION.md)** — vier Tiers,
  `settings.json`-Keys, komplette ENV-Tabelle mit Defaults
- **Over-Shoot-Guard in `run_turn`**: ein `done` schließt **alle** offenen
  Tool-Paare (kein offen gebliebenes Paar mehr nach dem Abbruch)
- **Fail-Streak**: ≥ 3 aufeinanderfolgende `bash`-Aufrufe mit rc ≠ 0 ohne
  einen einzigen Erfolg → Anstoß „Methode wechseln" (Gate `LEX_LOOP_GUARD`)
- **`tools/amnesie_test_setup.sh`** — isolierter Amnesie-/Kontaminations-Test
  (frisches `LEX_HOME`, keine alten Notizen im Prompt)
- **`tools/ctx_bench.sh`** — Kontext-/Decode-Benchmark-Helfer
- Prompt-Regeln: „Fehlertexte sind Zitate, keine Diagnosen" inkl.
  Repro-Negativkontrolle, **Widerlegungs-Regel** für Memory-Notizen
  (`Widerlegt YYYY-MM-DD: <Befund>`), **Frust-Bruch-Regel** (3× abgelehnt →
  Stopp statt Quellcode-Grab), Werkstatt-/Zentral-venv-Regel,
  Pfad-Wahrheit („das Projekt liegt ausschließlich im Repo-Verzeichnis")

### Geändert

- **Kontext-Default 262 144 → 180 224** — Compaction-Schwelle damit
  160 224 statt 242 144; HUD, `/status` und die betroffenen Tests sind
  mitgezogen
- **`_run_limited` hat jetzt eine eigene Frist** bei `secs`: der Kill-Baum
  tötet die Kindkette tiefste-zuerst, auch **Enkelprozesse** (früher lief ein
  Enkel nach rc 124 stundenlang weiter); GNU `timeout` ist nur noch der
  Rückfall
- **MCP-Default-Konfiguration** ohne `~/.lex/mcp.json` (`_mcp_config`-Fallback:
  defuddle, context7, playwright, desktop) plus Discovery-Cache
- **`export -a`-Fehler im Aufbau der Umgebung korrigiert** (Fund: `-a`
  exportierte die falsche Menge)
- **Private Datenbank-Anbindung raus aus der Default-Vorlage** — echte
  Konfiguration liegt immer in `~/.lex/mcp.json`, nie im Baum
- `test_limits.sh` isoliert: Compaction ist dort kein Testgegenstand mehr
  (`LEX_COMPACT=off`), damit der Läufer unabhängig vom ctx-Default bleibt

### Behoben

- Offene Tool-Paare nach `done` (Over-Shoot), überlebende Enkelprozesse nach
  Timeouts, fehlende MCP-Default-Server ohne `mcp.json`

### Entfernt

- **`/lexlurk` (Lurk-Wächter) und `tools/lurk_watch.sh`** — war in v0.3.0 im
  Repo, gehört nicht zum Kernprodukt und wird hier nicht mehr mitgeliefert
- **`soul.md`** (`~/.lex/soul.md`) — lag nur auf `main` nach v0.3.0, nie
  getagt; die Persona-Datei `~/.lex/prompts/lexpen.md` (`/lexpen`) bleibt das
  unterstützte Erweiterungsdokument

### Bereinigt

- Keine fest eingetragenen Home-Verzeichnisse mehr (Defaults laufen über
  `$HOME/…`), keine Bezüge zu Drittvorgängen in Code, Kommentaren und Tests

## v0.3.0 — 2026-10-10

- Fix am Ticker des Lurk-Modus: die Job-Meldung „Terminated sleep" beim `/off`
  wird umgeleitet (stderr-Redirect des Ticker-Subshells)
- Test-Fix: der `_lurk_tick`-Test feuert keine echten `notify-send`-Desktop-
  Meldungen mehr
- Zwischen v0.3.0 und v0.4.0 lagen außerdem auf `main` (ohne eigenen Tag):
  `soul.md` (dynamische Persönlichkeitsdatei `~/.lex/soul.md`) und die
  Synchronisation mit dem Arbeitsstand vom 2026-10-12 (sudo-Kontext-Split,
  `/lexpen`-Ticket nur einmal, Graceful-End bei Fail-Serien, `pipefail` in der
  Task-Shell, Plan-Pflicht, Ops-Bullets). Beides ist in v0.4.0 **nicht**
  enthalten — siehe „Entfernt".

## v0.2.1 — 2026-10-08

- Fix der Eingabe des Lurk-Modus: kein `read -t` mehr im REPL-Loop,
  Hintergrund-Ticker + pending-Flush → 912 [PASS], 899 Einzelf-Prüfungen,
  4969 Zeilen

## v0.2.0 — 2026-10-08

- adaptives Reasoning-Budget + HUD-Metrik
- **Stille-Wächter** (`LEX_SILENT_TURNS`) gegen ziellose Langläufer
- Wiederholungs-/Loop-Erkennung mit Nudge-Kette
- Prompt-Nadeln („denken hat ein Ende", „belegen oder Lücke nennen")
- Debug-Proxy-Vollausbau, Fake-Server nur noch an 127.0.0.1
- `tools/werkstatt_index.sh` (Versions-Block im Werkstatt-Index)
- Bash ≥ 4 als harte Anforderung (`coproc`)
- 890 Prüfungen, `lex` 4914 Zeilen

## v0.1.0 — 2026-09-30

- **Erste öffentliche Freigabe**: reines-Bash-LLM-Terminalagent für einen
  lokalen `llama-server` (OpenAI-kompatibel), MIT-Lizenz, CI auf GitHub
  Actions (`bash -n` → `shellcheck` → `test/run_all.sh` → Installer →
  Hygiene-Check)
- 19 Tools, Session-JSONL, Memory als Markdown, Markdown-Licht, Trace/HUD,
  sudo-Gate, harte Deny-Liste, `--approve`, Fake-Server-Tests ohne Netzwerk
