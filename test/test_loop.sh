#!/usr/bin/env bash
#
# lex/test/test_loop.sh — run_turn / setup_messages / max-turns.
# Skript wird per source geladen (stdin=/dev/null → REPL-Pfad bricht sofort ab).
# LEX_MOCK=done für den einfachen Pfad, LEX_MOCK_FILE für Multi-Turn.
# Kein Port 8080, kein echtes HTTP.
#
# shellcheck disable=SC2154  # _messages/_mock_file stammen aus dem geloadenen lex
set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEX_DIR="$(dirname "$SCRIPT_DIR")"

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

# Skript laden: LEX_HOME isoliert, LEX_MODEL fiktiv, Mock aktiv, stdin=/dev/null
export LEX_HOME="$TMP"
export LEX_MODEL="$TMP/model.gguf"
export LEX_MOCK="done"
source "$LEX_DIR/lex" < /dev/null > /dev/null 2>&1 || {
  echo "FEHLSCHLAG: $LEX_DIR/lex nicht ladbar (Syntax-/Bash-Fehler)" >&2
  exit 1
}

# 1. setup_messages: System-Prompt als erstes Element
setup_messages
role="$(jq -r '.[0].role' <<< "$_messages")"
content="$(jq -r '.[0].content' <<< "$_messages")"
if [[ "$role" == "system" ]] && [[ "$content" == *"Du bist Lex"* ]]; then
  printf '  [PASS] setup_messages\n'
else
  printf '  [FAIL] setup_messages (role=%s)\n' "$role" >&2
  FAIL=1
fi

# 2. run_turn mit LEX_MOCK=done → Modellantwort wird ausgeben
out="$(run_turn "Test" 2>/dev/null)"
assert "run_turn (mock)" "Taugt." "$out"

# 3. Multi-Turn über LEX_MOCK_FILE: Tool-Call → Tool-Result → finale Antwort
mock="$TMP/loop_mock.json"
printf '%s\n' \
  '{"choices":[{"index":0,"message":{"role":"assistant","content":"","tool_calls":[{"id":"tc1","type":"function","function":{"name":"read_file","arguments":"{\"path\":\"'$TMP'/loop.txt\"}"}}]}}]}' \
  '{"choices":[{"index":0,"message":{"role":"assistant","content":"Fertig.","tool_calls":[]}}]}' > "$mock"
printf 'Inhalt\n' > "$TMP/loop.txt"
_mock_file="$mock"
out="$(run_turn "Lesen" 2>/dev/null)"
assert "loop (tool + finale Antwort)" "Fertig." "$out"

# 4. Tool-Call-Argumente werden korrekt parsert (read_file über dispatch)
out="$(cat "$TMP/loop.txt")"
assert "loop (Tool-Output)" "Inhalt" "$out"

# 5. Max-Turns: _max_turns=2, 2 Tool-Antworten → Abbruch (exit 1)
printf '%s\n%s\n' \
  '{"choices":[{"index":0,"message":{"role":"assistant","content":"","tool_calls":[{"id":"t1","type":"function","function":{"name":"bash","arguments":"{\"command\":\"echo a\"}"}}]}}]}' \
  '{"choices":[{"index":0,"message":{"role":"assistant","content":"","tool_calls":[{"id":"t2","type":"function","function":{"name":"bash","arguments":"{\"command\":\"echo b\"}"}}]}}]}' > "$mock"
_max_turns=2
run_turn "Max" >/dev/null 2>&1
rc=$?
if (( rc != 0 )); then
  printf '  [PASS] run_turn (max turns)\n'
else
  printf '  [FAIL] run_turn (max turns, exit %s)\n' "$rc" >&2
  FAIL=1
fi

# 6. finish_reason=length (Text): Nudge-Pfad → Loop wird fortgesetzt
mock="$TMP/length_mock.json"
printf '%s\n%s\n' \
  '{"choices":[{"index":0,"message":{"role":"assistant","content":"Das ist ein l","tool_calls":[]},"finish_reason":"length"}]}' \
  '{"choices":[{"index":0,"message":{"role":"assistant","content":"angeschnitten.","tool_calls":[]},"finish_reason":"stop"}]}' > "$mock"
_mock_file="$mock"
run_turn "Test" > "$TMP/out.txt" 2> "$TMP/err.txt"
out="$(cat "$TMP/out.txt")"
assert "length (Text, finale Antwort)" "angeschnitten." "$out"
if [[ "$(cat "$TMP/err.txt")" == *"abgeschnitten"* ]]; then
  printf '  [PASS] length (Warnung auf stderr)\n'
else
  printf '  [FAIL] length (keine Warnung auf stderr): %q\n' "$(cat "$TMP/err.txt")" >&2
  FAIL=1
fi

# 7. finish_reason=length (Tool-Calls): Tools werden NICHT ausgeführt, Nudge
printf '%s\n%s\n' \
  '{"choices":[{"index":0,"message":{"role":"assistant","content":"","tool_calls":[{"id":"tc1","type":"function","function":{"name":"read_file","arguments":"{\"path\":\"'$TMP'/tool_len.txt\"}"}}]},"finish_reason":"length"}]}' \
  '{"choices":[{"index":0,"message":{"role":"assistant","content":"OK.","tool_calls":[]},"finish_reason":"stop"}]}' > "$mock"
printf 'Geheim\n' > "$TMP/tool_len.txt"
run_turn "Tool" > "$TMP/out.txt" 2> "$TMP/err.txt"
out="$(cat "$TMP/out.txt")"
assert "length (Tool-Call, finale Antwort)" "OK." "$out"
if [[ "$(cat "$TMP/err.txt")" == *"Tool-Calls wurden abgeschnitten"* ]]; then
  printf '  [PASS] length (Tool-Calls, Warnung)\n'
else
  printf '  [FAIL] length (Tool-Calls, Warnung): %q\n' "$(cat "$TMP/err.txt")" >&2
  FAIL=1
fi

# 8. Rette-Logik: mehrfaches length MIT Inhalt → nach 2 Nudges wird der
#    Teiltext gerendert (rc 0), statt mit rc 1 im Nichts zu enden
#    (Grenze hier hart 2: die mock-Datei hat genau 3 length-Einträge)
_max_nudges=2
printf '%s\n%s\n%s\n' \
  '{"choices":[{"index":0,"message":{"role":"assistant","content":"Das ist der Anfang der","tool_calls":[]},"finish_reason":"length"}]}' \
  '{"choices":[{"index":0,"message":{"role":"assistant","content":"Antwort und hier kommt der","tool_calls":[]},"finish_reason":"length"}]}' \
  '{"choices":[{"index":0,"message":{"role":"assistant","content":"letzte Teil des Satzes.","tool_calls":[]},"finish_reason":"length"}]}' > "$mock"
_mock_file="$mock"
_max_turns=4
run_turn "Test" > "$TMP/out.txt" 2> "$TMP/err.txt"
rc=$?
out="$(cat "$TMP/out.txt")"
assert "rette (Teiltext gerendert)" "letzte Teil des Satzes." "$out"
if (( rc == 0 )) && [[ "$(cat "$TMP/err.txt")" == *"zeige den Teiltext"* ]]; then
  printf '  [PASS] rette (rc 0 + Hinweis auf stderr)\n'
else
  printf '  [FAIL] rette (rc=%s, stderr: %q)\n' "$rc" "$(cat "$TMP/err.txt")" >&2
  FAIL=1
fi

# 9. Max-Turns-Abbruch rendert den vorhandenen Teiltext (Rette-Logik)
printf '%s\n' \
  '{"choices":[{"index":0,"message":{"role":"assistant","content":"Halbfertige Antwort.","tool_calls":[]},"finish_reason":"length"}]}' > "$mock"
_mock_file="$mock"
_max_turns=1
run_turn "Test" > "$TMP/out.txt" 2> "$TMP/err.txt"
rc=$?
out="$(cat "$TMP/out.txt")"
assert "max-re (Teiltext gerendert)" "Halbfertige Antwort." "$out"
if (( rc == 0 )) && [[ "$(cat "$TMP/err.txt")" == *"Max Turns erreicht"* ]]; then
  printf '  [PASS] max-re (rc 0 + Hinweis auf stderr)\n'
else
  printf '  [FAIL] max-re (rc=%s, stderr: %q)\n' "$rc" "$(cat "$TMP/err.txt")" >&2
  FAIL=1
fi

# 10. _max_nudges-Hebel (Default 4, LEX_MAX_NUDGES): Grenze 1 → schon nach
#     einem Nudge greift der Rette-Pfad, die zweite length-Antwort wird
#     als Teiltext gerendert (rc 0), ohne dass die mock-Datei erschöpft
#     wird.
printf '%s\n%s\n' \
  '{"choices":[{"index":0,"message":{"role":"assistant","content":"Teil Eins ","tool_calls":[]},"finish_reason":"length"}]}' \
  '{"choices":[{"index":0,"message":{"role":"assistant","content":"Teil Zwei.","tool_calls":[]},"finish_reason":"length"}]}' > "$mock"
_mock_file="$mock"
_max_turns=4
_max_nudges=1
run_turn "Nudge1" > "$TMP/out.txt" 2> "$TMP/err.txt"
rc=$?
out="$(cat "$TMP/out.txt")"
assert "nudge-grenze1 (Teiltext nach einem Nudge)" "Teil Zwei." "$out"
if (( rc == 0 )) && [[ "$(cat "$TMP/err.txt")" == *"zeige den Teiltext"* ]]; then
  printf '  [PASS] nudge-grenze1 (rc 0 + Hinweis)\n'
else
  printf '  [FAIL] nudge-grenze1 (rc=%s, stderr: %q)\n' "$rc" "$(cat "$TMP/err.txt")" >&2
  FAIL=1
fi
_max_nudges=4

# 11. Fail-Gedächtnis / Loop-Guard (Schritt 54, §6 #38): dasselbe
#     Toolaufruf-Pärchen dreimal hintereinander (Argumente UND Ergebnis
#     identisch) → weicher Anstoß, beim zweiten Mal harter Stopp.
#     Werkzeug: bash echo fixiert — Ergebnis ist byte-identisch.
same() {
  printf '%s\n' \
    '{"choices":[{"index":0,"message":{"role":"assistant","content":"","tool_calls":[{"id":"'$1'","type":"function","function":{"name":"bash","arguments":"{\"command\":\"echo fixiert\"}"}}]}}]}'
}
mock="$TMP/loop_guard.json"
same t1 > "$mock"; same t2 >> "$mock"; same t3 >> "$mock"
printf '%s\n' '{"choices":[{"index":0,"message":{"role":"assistant","content":"Fertig.","tool_calls":[]}}]}' >> "$mock"
_mock_file="$mock"
_max_turns=10
run_turn "immer dasselbe" > "$TMP/out.txt" 2> "$TMP/err.txt"
rc=$?
out="$(cat "$TMP/out.txt")"
err="$(cat "$TMP/err.txt")"
assert "loop-guard (weiche Stufe: Turn läuft weiter)" "0" "$rc"
assert "loop-guard (finale Antwort kommt an)" "Fertig." "$out"
assert "loop-guard (Anstoß auf stderr)" "1" "$([[ "$err" == *"Fail-Gedächtnis"* ]] && echo 1 || echo 0)"
assert "loop-guard (Wortlaut dreimal identisch)" "1" "$([[ "$err" == *"dreimal identisch"* ]] && echo 1 || echo 0)"
# N2 (Audit 2026-10-08): der Reset lief vor log/Session-Record → jeder
# nudge-Record enthielt "run":0 statt der tatsächlichen Trefferzahl.
assert "N2 (loop_guard nudge-Record nennt den Zähler)" "3" \
  "$(jq -r 'select(.type=="loop_guard" and .action=="nudge") | .run' \
    "$LEX_HOME"/sessions/*/session.jsonl 2>/dev/null | tail -1)"

# hart: sechs identische Batches → Anstoß, dann erzwungene Abschluss-Runde
#      OHNE Werkzeuge (Graceful-End, Fund 2026-10-12). Vorher: totes rc 1
#      ohne eine Antwortzeile. Jetzt: Mock-Queue erschöpft → „Taugt.".
same t1 > "$mock"; same t2 >> "$mock"; same t3 >> "$mock"
same t4 >> "$mock"; same t5 >> "$mock"; same t6 >> "$mock"
_mock_file="$mock"
run_turn "sechsmal dasselbe" > "$TMP/out2.txt" 2> "$TMP/err2.txt"
rc=$?
err2="$(cat "$TMP/err2.txt")"
assert "loop-guard hart (rc=0 statt totem Abbruch)" "0" "$rc"
assert "loop-guard hart (Abschluss-Antwort kommt an)" "Taugt." "$(cat "$TMP/out2.txt")"
assert "loop-guard hart (Meldung nennt den erzwungenen Abschluss)" "1" \
  "$([[ "$err2" == *"erneut identisch"* && "$err2" == *"erzwinge Abschluss-Antwort"* ]] && echo 1 || echo 0)"
assert "loop-guard hart (Session-Record action=final)" "final" \
  "$(jq -r 'select(.type=="loop_guard" and .action=="final") | .action' \
    "$LEX_HOME"/sessions/*/session.jsonl 2>/dev/null | tail -1)"
# Werkzeuge-Reset am Turn-START: der Final-Rundlauf darf die Abschaltung
# nicht in die nächste Runde tragen (sonst meldet das Modell tool_calls,
# die still verworfen werden — bis max_turns). Ohne Reset steht hier 1.
_mock_file="$mock"
run_turn "Reset-Check" >/dev/null 2>&1
assert "loop-guard (Werkzeuge-Reset am Turn-Start)" "0" \
  "$([[ -z "${_tools_off:-}" ]] && echo 0 || echo 1)"
# Sicherheitsnetz statisch: zweiter harter Treffer verlässt mit break und
# rendert danach den Teiltext — nie wieder ein blankes rc 1-Paar.
assert "loop-guard (Sicherheitsnetz: Grund-Variable)" "1" \
  "$(grep -c '_guard_reason="Fail-Gedächtnis hart"' "$LEX_DIR/lex")"
assert "loop-guard (Sicherheitsnetz: kein return 1 mehr im hart-Zweig)" "0" \
  "$(awk '/erzwinge Abschluss-Antwort ohne Werkzeuge/,/^    fi$/' "$LEX_DIR/lex" | grep -c 'return 1')"

# 11b. Silent-Turn-Guard (2026-10-07, §7 #62): 12 Tool-Turns in Folge
#      OHNE sichtbare Zwischenaussage → Anstoß, beim zweiten Mal Abbruch.
#      Args variieren (echo nr N), damit das Fail-Gedächtnis NICHT auslöst —
#      genau der adwt-B2-Fall (195 verschiedene Args, 200 Turns bis max).
silent() {
  printf '%s\n' '{"choices":[{"index":0,"message":{"role":"assistant","content":"","tool_calls":[{"id":"s'$1'","type":"function","function":{"name":"bash","arguments":"{\"command\":\"echo nr '$1'\"}"}}]}}]}'
}
silent_final() {
  printf '%s\n' '{"choices":[{"index":0,"message":{"role":"assistant","content":"Fertig.","tool_calls":[]}}]}'
}
mock="$TMP/silent.json"
for i in $(seq 1 12); do silent "t$i" >> "$mock"; done
silent_final >> "$mock"
_mock_file="$mock"
_max_turns=30
run_turn "zwölf stille Turns" > "$TMP/out_s.txt" 2> "$TMP/err_s.txt"
rc=$?
assert "silent-guard (weiche Stufe: rc=0)" "0" "$rc"
assert "silent-guard (finale Antwort kommt an)" "Fertig." "$(cat "$TMP/out_s.txt")"
err_s="$(cat "$TMP/err_s.txt")"
assert "silent-guard (Anstoß auf stderr)" "1" "$([[ "$err_s" == *"Silent-Guard"* ]] && echo 1 || echo 0)"
assert "silent-guard (nicht Fail-Gedächtnis)" "0" "$([[ "$err_s" == *"Fail-Gedächtnis"* ]] && echo 1 || echo 0)"
# Session-Record prüfen (letztes silent_guard)
_srec="$(jq -r 'select(.type=="silent_guard") | .action' "$LEX_HOME"/sessions/*/session.jsonl 2>/dev/null | tail -1)"
assert "silent-guard (Session-Record nudge)" "nudge" "$_srec"

# hart: nach dem Anstoß erneut 12 stille Turns → erzwungene Abschluss-Runde
#       (Graceful-End) statt totem rc 1; Mock-Queue erschöpft → „Taugt.".
mock="$TMP/silent2.json"
for i in $(seq 1 24); do silent "h$i" >> "$mock"; done
_mock_file="$mock"
run_turn "vierundzwanzig stille Turns" > "$TMP/out_s2.txt" 2> "$TMP/err_s2.txt"
rc=$?
assert "silent-guard hart (rc=0 statt totem Abbruch)" "0" "$rc"
assert "silent-guard hart (Abschluss-Antwort kommt an)" "Taugt." "$(cat "$TMP/out_s2.txt")"
assert "silent-guard hart (Meldung nennt den erzwungenen Abschluss)" "1" \
  "$([[ "$(cat "$TMP/err_s2.txt")" == *"Silent-Guard: erneut"* && "$(cat "$TMP/err_s2.txt")" == *"erzwinge Abschluss-Antwort"* ]] && echo 1 || echo 0)"
assert "silent-guard (Session-Record action=final)" "final" \
  "$(jq -r 'select(.type=="silent_guard") | .action' "$LEX_HOME"/sessions/*/session.jsonl 2>/dev/null | tail -1)"

# Reset: ein Turn MIT sichtbarem Text (neben den Tools) setzt die Streak auf 0
mock="$TMP/silent3.json"
for i in $(seq 1 10); do silent "r$i" >> "$mock"; done
printf '%s\n' '{"choices":[{"index":0,"message":{"role":"assistant","content":"Zwischenstand: halb fertig.","tool_calls":[{"id":"rz","type":"function","function":{"name":"bash","arguments":"{\"command\":\"echo weiter\"}"}}]}}]}' >> "$mock"
for i in $(seq 11 20); do silent "r$i" >> "$mock"; done
silent_final >> "$mock"
_mock_file="$mock"
run_turn "streak-reset" > "$TMP/out_s3.txt" 2> "$TMP/err_s3.txt"
rc=$?
assert "silent-guard (Reset: rc=0)" "0" "$rc"
assert "silent-guard (Reset: kein Anstoß)" "0" "$([[ "$(cat "$TMP/err_s3.txt")" == *"Silent-Guard"* ]] && echo 1 || echo 0)"
assert "silent-guard (Reset: finale Antwort)" "Fertig." "$(cat "$TMP/out_s3.txt")"

# Fehler-Serie (Fund 2026-10-12): sechs bash-Fails IN FOLGE mit wechselnden
# Args — der exakte Wiederholungs-Guard bleibt dabei unauffällig (Args
# unterscheiden sich), die Serie zählt trotzdem: „andere Zahl, dieselbe
# falsche Methode" → weicher Anstoß, kein Abbruch.
mock="$TMP/fail_streak.json"
for i in 1 2 3 4 5 6; do
  printf '%s\n' '{"choices":[{"index":0,"message":{"role":"assistant","content":"","tool_calls":[{"id":"fs'$i'","type":"function","function":{"name":"bash","arguments":"{\"command\":\"false # '$i'\"}"}}]}}]}' >> "$mock"
done
printf '%s\n' '{"choices":[{"index":0,"message":{"role":"assistant","content":"Neuer Ansatz gefunden.","tool_calls":[]}}]}' >> "$mock"
_mock_file="$mock"
_max_turns=12
run_turn "sechs Fehlschläge in Folge" > "$TMP/out_fs.txt" 2> "$TMP/err_fs.txt"
rc=$?
assert "fail-streak (rc=0, Anstoß statt Abbruch)" "0" "$rc"
assert "fail-streak (Antwort nach dem Anstoß)" "Neuer Ansatz gefunden." "$(cat "$TMP/out_fs.txt")"
assert "fail-streak (Meldung nennt rc≠0)" "1" \
  "$([[ "$(cat "$TMP/err_fs.txt")" == *"Fehler-Serie"* ]] && echo 1 || echo 0)"
assert "fail-streak (Session-Record)" "nudge" \
  "$(jq -r 'select(.type=="fail_streak") | .action' "$LEX_HOME"/sessions/*/session.jsonl 2>/dev/null | tail -1)"
_max_turns=20

# Schwelle 6 → 3 (§9/8, User-Auftrag 2026-10-17): Drei Fehlschläge in Folge
# reichen jetzt für den Anstoß, ZWEI noch nicht. Beide Richtungen belegt,
# damit die Grenze nicht verrutscht.
mock="$TMP/fail_streak3.json"
for i in 1 2 3; do
  printf '%s\n' '{"choices":[{"index":0,"message":{"role":"assistant","content":"","tool_calls":[{"id":"f3'$i'","type":"function","function":{"name":"bash","arguments":"{\"command\":\"false # 3'$i'\"}"}}]}}]}' >> "$mock"
done
printf '%s\n' '{"choices":[{"index":0,"message":{"role":"assistant","content":"Anderer Weg gefunden.","tool_calls":[]}}]}' >> "$mock"
_mock_file="$mock"
_max_turns=8
run_turn "drei Fehlschläge in Folge" > "$TMP/out_fs3.txt" 2> "$TMP/err_fs3.txt"
rc=$?
assert "fail-streak(3) (rc=0, Anstoß statt Abbruch)" "0" "$rc"
assert "fail-streak(3) (Antwort nach dem Anstoß)" "Anderer Weg gefunden." "$(cat "$TMP/out_fs3.txt")"
assert "fail-streak(3) (Meldung nach DREI Fehlern)" "1" \
  "$([[ "$(cat "$TMP/err_fs3.txt")" == *"Fehler-Serie"* ]] && echo 1 || echo 0)"

mock="$TMP/fail_streak2.json"
for i in 1 2; do
  printf '%s\n' '{"choices":[{"index":0,"message":{"role":"assistant","content":"","tool_calls":[{"id":"f2'$i'","type":"function","function":{"name":"bash","arguments":"{\"command\":\"false # 2'$i'\"}"}}]}}]}' >> "$mock"
done
printf '%s\n' '{"choices":[{"index":0,"message":{"role":"assistant","content":"Zwei reichen nicht.","tool_calls":[]}}]}' >> "$mock"
_mock_file="$mock"
run_turn "zwei Fehlschläge in Folge" > "$TMP/out_fs2.txt" 2> "$TMP/err_fs2.txt"
rc=$?
assert "fail-streak(2) (kein Anstoß bei ZWEI Fehlern)" "0" \
  "$([[ "$(cat "$TMP/err_fs2.txt")" == *"Fehler-Serie"* ]] && echo 1 || echo 0)"
_max_turns=20

# LEX_LOOP_GUARD=off: Guard aus, Turn läuft bis zur finalen Antwort durch
export LEX_LOOP_GUARD=off
same t1 > "$mock"; same t2 >> "$mock"; same t3 >> "$mock"
printf '%s\n' '{"choices":[{"index":0,"message":{"role":"assistant","content":"Weiter so.","tool_calls":[]}}]}' >> "$mock"
_mock_file="$mock"
run_turn "ohne Guard" > "$TMP/out3.txt" 2> "$TMP/err3.txt"
rc=$?
out="$(cat "$TMP/out3.txt")"
err3="$(cat "$TMP/err3.txt")"
assert "loop-guard off (finale Antwort)" "Weiter so." "$out"
assert "loop-guard off (kein Anstoß)" "0" "$([[ "$err3" == *"Fail-Gedächtnis"* ]] && echo 1 || echo 0)"
assert "loop-guard off (rc=0)" "0" "$rc"
unset LEX_LOOP_GUARD
_max_turns=20

if (( FAIL > 0 )); then
  echo "FEHLSCHLAG: $FAIL Test(s) in test_loop.sh" >&2
  exit 1
fi
echo "test_loop.sh grün. ✓"
exit 0
