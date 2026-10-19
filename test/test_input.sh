#!/usr/bin/env bash
#
# lex/test/test_input.sh — CLI-Modi: version, help, oneshot, unbekanntes Kommando.
# Alle Tests laufen mit LEX_MOCK / LEX_MOCK_FILE — NIE an 127.0.0.1:8080.
#
set -u
set -o pipefail

# ---------------------------------------------------------------------------
# Hintergrund-Erbgut-Sperre (Fund 2026-10-10) — VOR allem Weitere.
# Bash setzt für Hintergrund-Jobs SIGINT auf „ignorieren“. Wer die Suite aus
# einem Hintergrund-Job startet, vererbt das an ALLE Kinder — und genau das
# tut lex, wenn es Tests startet (tool_bash → `_run_limited … &`):
#   SigIgn im Kind = 0x06 (SIGHUP+SIGINT)
# Die getestete REPL erbt dasselbe; ein trap auf ein geerbt-ignore-Signal ist
# wirkungslos → ^C erreicht sie nicht → die drei Strg+C-Nadeln fielen OHNE
# echten Defekt rot (aus der lex-REPL heraus „immer FAIL", direkt grün).
# Reproduktion ohne lex:  bash -c 'bash test/test_input.sh' &   → 3× FAIL
# Reset: nur wenn INT tatsächlich geerbt-ignore ist (Bit 2), damit die
# Endlosschleife nach dem Reset entfällt (Bit ist danach weg).
_sigign="$(awk '/^SigIgn:/{print $2}' /proc/$$/status 2>/dev/null || true)"
if [[ -n "${_sigign:-}" ]] && command -v env >/dev/null 2>&1 \
   && env --help 2>/dev/null | grep -q -- '--default-signal' \
   && (( (16#$_sigign >> 1) & 1 )); then
  exec env --default-signal=INT bash "${BASH_SOURCE[0]}" "$@"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEX_DIR="$(dirname "$SCRIPT_DIR")"
LEX_BIN="$LEX_DIR/lex"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAIL=0

assert() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    printf '  [PASS] %s\n' "$desc"
  else
    printf '  [FAIL] %s\n' "$desc" >&2
    printf '         erwartet: %q\n' "$expected" >&2
    printf '         ist:      %q\n' "$actual" >&2
    FAIL=1
  fi
}

# Skript laden/isolieren: LEX_HOME zeigt in den TMP, sonst schreibt der
# Test Sessions und Mock-Schatten ins echte ~/.lex (Isolationsfehler 2026-09-28).
export LEX_HOME="$TMP"

# 1. --version
assert "version" "lex 0.4.0" "$("$LEX_BIN" --version)"

# 2. --help
out="$("$LEX_BIN" --help 2>&1)"
if [[ "$out" == *"lex — eigener reines-Bash-basierter LLM-Terminal-Agent"* ]]; then
  printf '  [PASS] help\n'
else
  printf '  [FAIL] help\n' >&2
  FAIL=1
fi

# 3. Unbekanntes Kommando → Fehler auf stderr + Exit 1
out="$("$LEX_BIN" --falsch 2>&1 1>/dev/null)"
rc=0
"$LEX_BIN" --falsch >/dev/null 2>&1
rc=$?
if [[ "$out" == *"Unbekanntes Kommando: --falsch"* ]]; then
  printf '  [PASS] unbekanntes Kommando (Fehlermeldung)\n'
else
  printf '  [FAIL] unbekanntes Kommando (Fehlermeldung): %q\n' "$out" >&2
  FAIL=1
fi
if (( rc == 1 )); then
  printf '  [PASS] unbekanntes Kommando (exit 1)\n'
else
  printf '  [FAIL] unbekanntes Kommando (exit %s)\n' "$rc" >&2
  FAIL=1
fi

# 4. --oneshot mit LEX_MOCK=done
out="$(echo 'Sag Hallo' | LEX_MOCK="done" "$LEX_BIN" --oneshot 2>/dev/null)"
assert "oneshot (mock)" "Taugt." "$out"

# 5. --oneshot mit leerer Eingabe → keine Ausgabe, exit 0
out="$(printf '' | LEX_MOCK="done" "$LEX_BIN" --oneshot 2>/dev/null)"
rc=0
printf '' | LEX_MOCK="done" "$LEX_BIN" --oneshot >/dev/null 2>&1
rc=$?
assert "oneshot (leere Eingabe)" "" "$out"
if (( rc == 0 )); then
  printf '  [PASS] oneshot (leere Eingabe, exit 0)\n'
else
  printf '  [FAIL] oneshot (leere Eingabe, exit %s)\n' "$rc" >&2
  FAIL=1
fi

# 5b. OHNE --oneshot, aber ohne TTY (Pipe): agent_loop wertet wie oneshot aus
# (P3, Review 2026-09-29) — sonst schluckt `echo … | lex` die Eingabe tatenlos.
out="$(echo 'Sag Hallo' | LEX_MOCK="done" "$LEX_BIN" 2>/dev/null)"
assert "pipe ohne Flag (non-TTY → oneshot)" "Taugt." "$out"
rc=0
printf '' | LEX_MOCK="done" "$LEX_BIN" >/dev/null 2>&1
rc=$?
if (( rc == 0 )); then
  printf '  [PASS] pipe ohne Flag (leere Eingabe, exit 0)\n'
else
  printf '  [FAIL] pipe ohne Flag (leere Eingabe, exit %s)\n' "$rc" >&2
  FAIL=1
fi

# 5c. /exit und /quit enden oneshot OHNE Modell-Call
# (Review-Fund 2026-10-01: /exit fiel bislang durch zu run_turn — die
# Eingabe kostete einen Request und die Antwort landete im Nichts.)
out="$(printf '/exit' | LEX_MOCK="done" "$LEX_BIN" --oneshot 2>/dev/null)"
assert "oneshot (/exit ohne Modell-Call)" "" "$out"
rc=0
printf '/exit' | LEX_MOCK="done" "$LEX_BIN" --oneshot >/dev/null 2>&1
rc=$?
if (( rc == 0 )); then
  printf '  [PASS] oneshot (/exit, exit 0)\n'
else
  printf '  [FAIL] oneshot (/exit, exit %s)\n' "$rc" >&2
  FAIL=1
fi
out="$(printf '/quit' | LEX_MOCK="done" "$LEX_BIN" --oneshot 2>/dev/null)"
assert "oneshot (/quit ohne Modell-Call)" "" "$out"
# Dasselbe über den Pipe-Pfad (agent_loop ohne TTY → oneshot)
out="$(printf '/exit' | LEX_MOCK="done" "$LEX_BIN" 2>/dev/null)"
assert "pipe ohne Flag (/exit ohne Modell-Call)" "" "$out"

# 5d. Echte REPL unter PTY: /exit beendet die Sitzung, ohne dass das
# Modell gefragt wird (Monitor: kein "Taugt." aus dem Mock, dafür Abschied).
repl_out="$(printf '/exit\n' | LEX_MOCK="done" LEX_HOME="$TMP" \
  timeout 30 script -qec "bash '$LEX_BIN'" /dev/null 2>&1 | tr -d '\r')"
if [[ "$repl_out" == *"Tschüss"* ]]; then
  printf '  [PASS] repl (/exit → Tschüss, Sitzung zu)\n'
else
  printf '  [FAIL] repl (/exit → Tschüss): %q\n' "$repl_out" >&2
  FAIL=1
fi
if [[ "$repl_out" != *"Taugt."* ]]; then
  printf '  [PASS] repl (/exit ohne Modell-Call)\n'
else
  printf '  [FAIL] repl (/exit ohne Modell-Call — Modell wurde gefragt)\n' >&2
  FAIL=1
fi

# 5e. Prompt-Garantie (Fund 2026-10-03, User-Report „nach Aufgaben nur
# blinkender Cursor"): leerer Enter darf den Prompt nicht schlucken.
# Drei leere/Text-Eingaben → mindestens 3 Prompt-Zeilen im PTY-Transkript
# (initial + je Eingabe). Vor dem Fix blieb es bei 2 (continue übersprang
# _prompt).
repl2_out="$(printf '\n\n/exit\n' | LEX_MOCK="done" LEX_HOME="$TMP" \
  timeout 30 script -qec "bash '$LEX_BIN'" /dev/null 2>&1 | tr -d '\r')"
n_prompts="$(printf '%s' "$repl2_out" | grep -o 'lex>' | wc -l | tr -d ' ')"
if (( n_prompts >= 3 )); then
  printf '  [PASS] repl (Prompt nach leerem Enter: %s× lex>)\n' "$n_prompts"
else
  printf '  [FAIL] repl (Prompt nach leerem Enter — nur %s× lex>)\n' "$n_prompts" >&2
  FAIL=1
fi
# Statische Anker: die Reparaturstellen müssen im Skript bleiben.
# Prompt-Garantie seit 2026-10-08: der Prompt kommt vom `read -p`
# (Argument für readline, löst zugleich den Umbruch-Überschreib-Bug),
# der continue-Pfad muss die Zeile also NICHT mehr selbst nachziehen —
# Anker prüft beide Seiten: continue-Pfad ohne _prompt UND read -p.
if grep -Fq '[[ -z "$input" ]] && { _spin_stop; continue; }' "$LEX_BIN" \
  && grep -Fq 'IFS= read -e -p "$(_prompt)" input' "$LEX_BIN"; then
  printf '  [PASS] repl (Anker: continue-Pfad + read -p Prompt)\n'
else
  printf '  [FAIL] repl (Anker: continue-Pfad + read -p Prompt)\n' >&2
  FAIL=1
fi
if grep -Fq 'while [[ -f "$_spin_flag" ]]; do' "$LEX_BIN"; then
  printf '  [PASS] repl (Anker: Spinner-Loop hat Flag-Gate)\n'
else
  printf '  [FAIL] repl (Anker: Spinner-Loop hat Flag-Gate)\n' >&2
  FAIL=1
fi

# Anker: der Hintergrund-SigInt-Reset muss in BEIDEN Einstiegen bleiben —
# sonst fallen die folgenden ^C-Nadeln aus der lex-REPL heraus ohne echten
# Defekt rot (Fund 2026-10-10).
if grep -Fq 'default-signal=INT' "$SCRIPT_DIR/test_input.sh" \
   && grep -Fq 'default-signal=INT' "$SCRIPT_DIR/run_all.sh"; then
  printf '  [PASS] repl (Anker: Hintergrund-SigInt-Reset steht)\n'
else
  printf '  [FAIL] repl (Anker: Hintergrund-SigInt-Reset fehlt)\n' >&2
  FAIL=1
fi

# 5f. Strg+C am Prompt (Schritt 51): lex darf NICHT sterben. Vor dem Fix
# gab es kein trap … INT — ein einziger Strg+C beendete den Prozess
# (Live-Fund 2026-10-05, Session 125104). Erster Druck verwirft nur die
# Zeile, /exit beendet sauber mit rc 0.
intlog="$TMP/int_prompt.log"
( sleep 2; printf '\003'; sleep 1; printf '/exit\n' ) | \
  LEX_MOCK="done" LEX_HOME="$TMP" timeout 30 script -qec "bash '$LEX_BIN'" /dev/null > "$intlog" 2>&1
rc=$?
out="$(tr -d '\r' < "$intlog")"
if (( rc == 0 )) && [[ "$out" == *"Tschüss"* ]]; then
  printf '  [PASS] repl (Strg+C am Prompt: REPL lebt, /exit rc 0)\n'
else
  printf '  [FAIL] repl (Strg+C am Prompt: rc=%s Tschüss=%s)\n' \
    "$rc" "$([[ "$out" == *Tschüss* ]] && echo ja || echo nein)" >&2
  printf '         Ausgabe: %q\n' "$out" >&2
  FAIL=1
fi
if [[ "$out" == *"^C"* ]]; then
  printf '  [PASS] repl (Strg+C am Prompt: ^C im Transkript)\n'
else
  printf '  [FAIL] repl (Strg+C am Prompt: kein ^C im Transkript)\n' >&2
  FAIL=1
fi

# 5g. Strg+C während des Tool-Laufs (Schritt 51): Turn abgebrochen, Kind tot
# (timeout --foreground, sonst lief sleep bis zum tool_timeout weiter: 20 s
# gemessen), Session protokoll-konsistent (tool_call bekommt eine Antwort),
# REPL lebt. Regression ohne Fix: rc=124 über timeout 30 (Kind läuft 60 s).
smock="$TMP/int_turn.json"
printf '%s\n' \
  '{"choices":[{"index":0,"message":{"role":"assistant","content":"","tool_calls":[{"id":"tcI","type":"function","function":{"name":"bash","arguments":"{\"command\":\"sleep 60\"}"}}]}}]}' \
  '{"choices":[{"index":0,"message":{"role":"assistant","content":"Fertig.","tool_calls":[]}}]}' > "$smock"
t0=$SECONDS
( sleep 1; printf 'start\n'; sleep 2; printf '\003'; sleep 1; printf '/exit\n' ) | \
  LEX_MOCK_FILE="$smock" LEX_HOME="$TMP" timeout 30 script -qec "bash '$LEX_BIN'" /dev/null > "$intlog" 2>&1
rc=$?
dauer=$((SECONDS - t0))
out="$(tr -d '\r' < "$intlog")"
if (( rc == 0 )) && [[ "$out" == *"Turn abgebrochen"* ]] && [[ "$out" == *"Tschüss"* ]]; then
  printf '  [PASS] repl (Strg+C im Turn: abgebrochen, REPL lebt, rc 0, %ss)\n' "$dauer"
else
  printf '  [FAIL] repl (Strg+C im Turn: rc=%s dauer=%ss)\n' "$rc" "$dauer" >&2
  printf '         Ausgabe: %q\n' "$out" >&2
  FAIL=1
fi
if (( dauer < 25 )); then
  printf '  [PASS] repl (Strg+C im Turn: Kind sofort tot — %ss << 60s sleep)\n' "$dauer"
else
  printf '  [FAIL] repl (Strg+C im Turn: Kind lief weiter (%ss — timeout ohne --foreground?)\n' "$dauer" >&2
  FAIL=1
fi
int_sess="$(ls -t "$TMP"/sessions/*/session.jsonl 2>/dev/null | head -1)"
if [[ -n "$int_sess" ]] && grep -q 'Turn mit Strg+C abgebrochen' "$int_sess"; then
  printf '  [PASS] repl (Strg+C im Turn: tool-Antwort-Markierung in der Session)\n'
else
  printf '  [FAIL] repl (Strg+C im Turn: Markierung fehlt in der Session)\n' >&2
  FAIL=1
fi

# 5h. Sitzungs-Freigabe (Schritt 52): beim ersten sudo EINE y/N-Frage auf
# der TTY, danach läuft sudo in derselben Sitzung ohne Nachfrage (kein y
# pro Befehl — User-Entscheidung 2026-10-05). Fake-sudo im PATH
# protokolliert die Calls: genau 1× "Sitzung freigeben" im Transkript,
# beide sudo-Kommandos ausgeführt (zweiter Lauf OHNE zweite Frage).
fakebin="$TMP/fakebin"
mkdir -p "$fakebin"
cat > "$fakebin/sudo" <<'FAKESUDO'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_SUDO_LOG:?}"
if [[ "${1:-}" == "-n" && "${2:-}" == "true" ]]; then exit 0; fi
echo "SUDO-AUSGEFUEHRT"
exit 0
FAKESUDO
chmod 755 "$fakebin/sudo"
glog="$TMP/fakesudo.log"
: > "$glog"
gmock="$TMP/grant.json"
printf '%s\n' \
  '{"choices":[{"index":0,"message":{"role":"assistant","content":"","tool_calls":[{"id":"tcG","type":"function","function":{"name":"bash","arguments":"{\"command\":\"sudo -n echo SUDO-LIEF\"}"}}]}}]}' \
  '{"choices":[{"index":0,"message":{"role":"assistant","content":"Erste fertig.","tool_calls":[]}}]}' \
  '{"choices":[{"index":0,"message":{"role":"assistant","content":"","tool_calls":[{"id":"tcH","type":"function","function":{"name":"bash","arguments":"{\"command\":\"sudo -n echo NOCHMAL\"}"}}]}}]}' \
  '{"choices":[{"index":0,"message":{"role":"assistant","content":"Zweite fertig.","tool_calls":[]}}]}' > "$gmock"
( sleep 1; printf 'start\n'; sleep 3; printf 'y\n'; sleep 3; printf 'nochmal\n'; sleep 3; printf '/exit\n' ) | \
  PATH="$fakebin:$PATH" FAKE_SUDO_LOG="$glog" LEX_MOCK_FILE="$gmock" LEX_HOME="$TMP" \
  timeout 40 script -qec "bash '$LEX_BIN'" /dev/null > "$intlog" 2>&1
rc=$?
out="$(tr -d '\r' < "$intlog")"
if (( rc == 0 )) && [[ "$out" == *"Tschüss"* ]]; then
  printf '  [PASS] grant (Sitzung: y → beide sudo-Läufe, rc 0)\n'
else
  printf '  [FAIL] grant: rc=%s Tschüss=%s\n' \
    "$rc" "$([[ "$out" == *Tschüss* ]] && echo ja || echo nein)" >&2
  printf '         Ausgabe: %q\n' "$out" >&2
  FAIL=1
fi
n_grant="$(printf '%s' "$out" | grep -o 'Sitzung freigeben' | wc -l | tr -d ' ')"
if (( n_grant == 1 )); then
  printf '  [PASS] grant (genau EINE Sitzungsfrage — kein y/N pro Befehl)\n'
else
  printf '  [FAIL] grant: %sx \"Sitzung freigeben\" im Transkript (erwartet 1)\n' "$n_grant" >&2
  FAIL=1
fi
if grep -q 'echo SUDO-LIEF' "$glog" && grep -q 'echo NOCHMAL' "$glog"; then
  printf '  [PASS] grant (zweiter sudo ohne Rückfrage ausgeführt)\n'
else
  printf '  [FAIL] grant (fake-sudo log unvollständig): %s\n' "$(tr '\n' ';' < "$glog")" >&2
  FAIL=1
fi
if [[ "$out" == *"Erste fertig."* ]] && [[ "$out" == *"Zweite fertig."* ]]; then
  printf '  [PASS] grant (beide Turns im REPL sichtbar)\n'
else
  printf '  [FAIL] grant (Turns fehlen im Transkript)\n' >&2
  FAIL=1
fi

# 6. LEX_MOCK_FILE: erste Zeile wird ausgegeben
mock="$TMP/mock.json"
printf '%s\n' '{"choices":[{"index":0,"message":{"role":"assistant","content":"Aus Datei."}}]}' > "$mock"
out="$(echo 'Test' | LEX_MOCK_FILE="$mock" "$LEX_BIN" --oneshot 2>/dev/null)"
assert "mock-file (erste Zeile)" "Aus Datei." "$out"

# 7. LEX_MOCK_FILE wird aufgebraucht: jede Zeile = ein API-Antwort
printf '%s\n%s\n' \
  '{"choices":[{"index":0,"message":{"role":"assistant","content":"Erste."}}]}' \
  '{"choices":[{"index":0,"message":{"role":"assistant","content":"Zweite."}}]}' > "$mock"
out="$(echo 'Test' | LEX_MOCK_FILE="$mock" "$LEX_BIN" --oneshot 2>/dev/null)"
assert "mock-file (1. Antwort)" "Erste." "$out"
out="$(echo 'Test' | LEX_MOCK_FILE="$mock" "$LEX_BIN" --oneshot 2>/dev/null)"
assert "mock-file (2. Antwort)" "Zweite." "$out"

if (( FAIL > 0 )); then
  echo "FEHLSCHLAG: $FAIL Test(s) in test_input.sh" >&2
  exit 1
fi
echo "test_input.sh grün. ✓"
exit 0
