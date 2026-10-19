#!/usr/bin/env bash
#
# lex/test/test_repetition.sh — Wiederholungs-/Loop-Erkennung (Konzept V1).
#
# Fund 2026-10-03 (Fehlerbericht 2026-10-03):
# das Modell lief in eine Satz-Wiederholungsschleife (finish=stop, Content
# nicht leer), die Nudge-Kette in run_turn fing das nicht ab, der Loop wurde
# unverändert gerendert. Gebaut: _rep_detect (A1 Trailing-Run, A2 Satz-Loop,
# A3 Rep-4) vor dem Render, Nudge B1/B2 gegen das bestehende _max_nudges-
# Budget, Truncation-Render danach, Session-Record type:repetition.
#
# Was geprüft wird:
#   1. Detektor-Unit-Tests: echter Realfall-Loop → A2, Wort-Loop → A1,
#      variierter 4-Gram-Loop → A3
#   2. False-Positive-Gates: lexpen-Tabelle, Codeblock, normale Prosa,
#      kurzer Satz ×3 — KEIN Fund
#   3. Integration run_turn über die Mock-Queue: weicher Nudge → harter
#      Nudge → Truncation nach Budget, _messages wächst, Session-Records
#   4. Statische Anker: Hook existiert, prüft NUR $content (nie reasoning),
#      Truncation-Render existiert
#
# NUR LEX_MOCK_FILE (Datei-Queue) — der echte llama-server (8080) wird
# nicht angerührt.
#
# shellcheck disable=SC2154  # _messages/_mock_file/_system_prompt stammen aus dem geloadenen lex
set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEX_DIR="$(dirname "$SCRIPT_DIR")"

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

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
contains() {
  local desc="$1" needle="$2" hay="$3"
  if [[ "$hay" == *"$needle"* ]]; then
    printf '  [PASS] %s\n' "$desc"
  else
    printf '  [FAIL] %s (suche: %q)\n' "$desc" "$needle" >&2
    printf '         Text (Anfang): %q\n' "${hay:0:200}" >&2
    FAIL=1
  fi
}
not_contains() {
  local desc="$1" needle="$2" hay="$3"
  if [[ "$hay" != *"$needle"* ]]; then
    printf '  [PASS] %s\n' "$desc"
  else
    printf '  [FAIL] %s (darf %q nicht enthalten)\n' "$desc" "$needle" >&2
    FAIL=1
  fi
}
check() {
  local desc="$1" ok="$2"
  if [[ "$ok" == "1" ]]; then
    printf '  [PASS] %s\n' "$desc"
  else
    printf '  [FAIL] %s\n' "$desc" >&2
    FAIL=1
  fi
}

# ===========================================================================
# Fixtures — der ECHTE Loop-Fall aus einer Live-Session (2912 Bytes,
# „Ich überlege nochmal" u.ä. ~15×; Inhalt des Assistenten-Turns vom
# 2026-10-03 16:53).
# ===========================================================================
FIXTURE_TXT="$TMP/loop.txt"
cat > "$FIXTURE_TXT" <<'FIXTURE'
Ich habe zu viel nachgedacht. Ich mache die Entscheidung klar und führe sie aus: bloodhound CE ist ein Web-App-Stack (Docker-Compose), kein CLI-Tool. Es ist ein Server-Dienst. Ich werde es als "installierbar" markieren (Java + Docker da), aber es ist ein Web-Stack. Ich installiere es per Docker-Compose.

Eigentlich — ich überlege nochmal. bloodhound ist ein Web-App-Stack. Es ist kein CLI-Tool. Ich werde es als Doku-only belassen, weil es nicht zum "CLI-Tool-Modell" von H-Tools passt.

NEIN. Das wäre nicht korrekt. Der Task ist klar: "arbeite NUR die dort als offen oder halb vermerkten Punkte ab". bloodhound ist offen. Java ist jetzt da. Also soll ich bloodhound installieren.

Ich überlege nochmal. Der Task ist klar: "arbeite NUR die dort als offen oder halb vermerkten Punkte ab". bloodhound ist offen. Java ist jetzt da. Also soll ich bloodhound installieren.

Aber bloodhound ist ein Web-App-Stack. Ich muss es als solchen installieren.

Ich überlege nochmal. Der Task ist klar: "arbeite NUR die dort als offen oder halb vermerkten Punkte ab". bloodhound ist offen. Java ist jetzt da. Also soll ich bloodhound installieren.

Aber bloodhound ist ein Web-App-Stack. Ich muss es als solchen installieren.

Ich überlege nochmal. Der Task ist klar: "arbeite NUR die dort als offen oder halb vermerkten Punkte ab". bloodhound ist offen. Java ist jetzt da. Also soll ich bloodhound installieren.

Aber bloodhound ist ein Web-App-Stack. Ich muss es als solchen installieren.

Ich überlege nochmal. Der Task ist klar: "arbeite NUR die dort als offen oder halb vermerkten Punkte ab". bloodhound ist offen. Java ist jetzt da. Also soll ich bloodhound installieren.

Aber bloodhound ist ein Web-App-Stack. Ich muss es als solchen installieren.

Ich überlege nochmal. Der Task ist klar: "arbeite NUR die dort als offen oder halb vermerkten Punkte ab". bloodhound ist offen. Java ist jetzt da. Also soll ich bloodhound installieren.

Aber bloodhound ist ein Web-App-Stack. Ich muss es als solchen installieren.

Ich überlege nochmal. Der Task ist klar: "arbeite NUR die dort als offen oder halb vermerkten Punkte ab". bloodhound ist offen. Java ist jetzt da. Also soll ich bloodhound installieren.

Aber bloodhound ist ein Web-App-Stack. Ich muss es als solchen installieren.

Ich überlege nochmal. Der Task ist klar: "arbeite NUR die dort als offen oder halb vermerkten Punkte ab". bloodhound ist offen. Java ist jetzt da. Also soll ich bloodhound installieren.

Aber bloodhound ist ein Web-App-Stack. Ich muss es als solchen installieren.
FIXTURE

# Mock-Queue:3× derselbe Loop-Turn (Budget LEX_MAX_NUDGES=2 →
# Nudge1, Nudge2, Truncation) — jede call_api zieht eine Zeile.
MOCK_QUEUE="$TMP/queue.jsonl"
loop_line="$(jq -c -n --rawfile c "$FIXTURE_TXT" \
  '{choices:[{index:0,message:{role:"assistant",content:$c,reasoning_content:"",tool_calls:[]},finish_reason:"stop"}],usage:{prompt_tokens:100,completion_tokens:200,total_tokens:300}}')"
printf '%s\n%s\n%s\n' "$loop_line" "$loop_line" "$loop_line" > "$MOCK_QUEUE"

# ===========================================================================
# lex sourceen: LEX_HOME isoliert, Mock-Queue SEHR VOR dem Source setzen
# (Schattenkopie entsteht beim Laden), Budget runter für einen kurzen Lauf.
# ===========================================================================
export LEX_HOME="$TMP"
export LEX_MODEL="$TMP/model.gguf"
export LEX_WIKI_DIR="$TMP/wiki"
mkdir -p "$TMP/wiki"
export LEX_MOCK_FILE="$MOCK_QUEUE"
export LEX_MAX_NUDGES=2
unset LEX_MOCK
source "$LEX_DIR/lex" < /dev/null > /dev/null 2>&1 || {
  echo "FEHLSCHLAG: $LEX_DIR/lex nicht ladbar (Syntax-/Bash-Fehler)" >&2
  exit 1
}
setup_messages >/dev/null 2>&1 || true

# ===========================================================================
# 1. Detektor-Unit-Tests
# ===========================================================================
printf '  [INFO] _rep_detect: Realfall → A2\n'
out="$(printf '%s' "$(cat "$FIXTURE_TXT")" | _rep_detect)"
assert "Realfall-Loop wird als A2 erkannt" "A2" "${out%%|*}"

printf '  [INFO] _rep_detect: Wort-Loop → A1\n'
out="$(printf 'data %.0s' {1..40} | _rep_detect)"
assert "Wort-Loop (data data …) wird als A1 erkannt" "A1" "${out%%|*}"

printf '  [INFO] _rep_detect: variierter 4-Gram-Loop → A3\n'
out="$({ for _ in $(seq 1 30); do printf 'the quick brown fox jumps over the lazy dog and runs away fast now '; done; echo; } | _rep_detect)"
assert "variierter Loop wird als A3 erkannt" "A3" "${out%%|*}"

# ===========================================================================
# 2. False-Positive-Gates
# ===========================================================================
printf '  [INFO] _rep_detect: False-Positive-Gates\n'
out="$(printf '│ exploit (3/1/—) │ sqlmap, metasploit (system), hashcat 7.1.2 │ hydra (Dual-Use) │\n│ scan (8/1/1) │ ffuf (v2.3.0), httpx, katana, naabu, nmap │ burp-suite │\n│ recon (1/2/—) │ subfinder │ bloodhound (Web-App-Stack Docker-Compose) │\n' | _rep_detect)"
assert "lexpen-Tabelle: kein Fund" "" "$out"

out="$(printf 'Beispiel:\n```bash\nwhile true; do echo hello; sleep 1; done\nwhile true; do echo hello; sleep 1; done\nwhile true; do echo hello; sleep 1; done\n```\nDie Schleife laeuft endlos und muss manuell beendet werden.\n' | _rep_detect)"
assert "Codeblock: kein Fund" "" "$out"

out="$(printf 'Der Server wurde gestern neu gestartet. Danach lief alles wieder stabil. Ein zweiter Neustart war nicht noetig. Wir beobachten das weiter und greifen nur bei erneuten Ausfaellen ein.\n' | _rep_detect)"
assert "normale Prosa: kein Fund" "" "$out"

out="$(printf 'Das ist ein kurzer Satz ohne Wert. Das ist ein kurzer Satz ohne Wert. Das ist ein kurzer Satz ohne Wert.\n' | _rep_detect)"
assert "kurzer Satz x3 (unter beiden Gates): kein Fund" "" "$out"

# ===========================================================================
# 3. Integration: run_turn über die Mock-Queue (3 identische Loop-Turns)
# ===========================================================================
printf '  [INFO] run_turn: Loop-Turn, Nudge weich → hart → Truncation\n'
# KEIN $(…)-Subshell: _messages muss im aktuellen Shell-Prozess wachsen
# (Fund im Test selbst, 2026-10-03) — stdout/stderr über Dateien abfangen.
run_turn "setze die Aufgabe fort" >"$TMP/out.txt" 2>"$TMP/err.txt"
rc=$?
out="$(cat "$TMP/out.txt")"
err="$(cat "$TMP/err.txt")"
assert "run_turn endet mit rc=0 (Truncation-Pfad)" "0" "$rc"

contains "1. Nudge: weicher Abbruch-Anstoß (Fund genannt)" "Wiederholungsschleife erkannt (A2" "$err"
contains "2. Nudge: harter Anstoß" "erneut erkannt" "$err"
contains "Budget erreicht: Truncation-Render" "zeige nur den Anfang" "$err"
contains "Render zeigt den Antwortanfang" "Ich habe zu viel nachgedacht" "$out"
out_len="${#out}"
check "Render ist gekürzt (${out_len} Zeichen, Fixture 2912)" \
  "$([[ "$out_len" -ge 1500 && "$out_len" -lt 2500 ]] && echo 1 || echo 0)"

user_msgs="$(jq '[.[] | select(.role=="user")] | length' <<< "$_messages" 2>/dev/null || echo "?")"
assert "_messages: user-Nachrichten = 1 Input + 2 Nudges" "3" "$user_msgs"

rep_recs="$(grep -c '"type":"repetition"' "${_session_file:-/dev/null}" 2>/dev/null || true)"
rep_recs="${rep_recs:-0}"
assert "Session-Records type:repetition = 2 Nudges + 1 Truncation" "3" "$rep_recs"

# ===========================================================================
# 4. Statische Anker (Festnagel-Prinzip)
# ===========================================================================
printf '  [INFO] statische Anker\n'
src="$(cat "$LEX_DIR/lex")"
check "Funktion _rep_detect definiert" \
  "$(grep -q '^_rep_detect()' "$LEX_DIR/lex" && echo 1 || echo 0)"
check "Hook prüft content, nicht reasoning (Scope deepseek #3480)" \
  "$(grep -q 'printf .%s. "\$content" | _rep_detect' "$LEX_DIR/lex" && ! grep -q '_rep_detect.*reasoning' "$LEX_DIR/lex" && echo 1 || echo 0)"
check "Truncation-Render (content:0:2000) vorhanden" \
  "$(grep -q 'content:0:2000' "$LEX_DIR/lex" && echo 1 || echo 0)"
check "Budget-Var rep_nudges in run_turn initialisiert" \
  "$(grep -q 'nudge_count=0 rep_nudges=0' "$LEX_DIR/lex" && echo 1 || echo 0)"
check "Session-Record type:repetition vorhanden" \
  "$(grep -q 'type:"repetition"' "$LEX_DIR/lex" && echo 1 || echo 0)"
# shellcheck disable=SC2034  # src nur der Vollständigkeit wegen
: "$src"

if (( FAIL > 0 )); then
  echo "test_repetition: $FAIL Fehlschläge" >&2
  exit 1
fi
echo "test_repetition grün. ✓"
exit 0
