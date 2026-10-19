#!/usr/bin/env bash
#
# lex/test/test_limits.sh — nichts an der lex↔llama-Grenze wird abgeschnitten.
#
# Fund 2026-09-30: Kappen bei 100 000 Bytes (append_message/append_tool_message/
# setup_messages, weil `jq --arg` an MAX_ARG_STRLEN scheitert) und 50 000 Bytes
# (Pro-Tool-Kappen) rissen Daten aus dem Protokoll, ohne dass das Modell es
# merkte. Der Pfad läuft jetzt über Dateien (--rawfile/--slurpfile), und
# übergroße Tool-Ergebnisse werden abgelegt statt weggeworfen.
#
# Was geprüft wird:
#   1. user-/tool-/assistant-Nachrichten in voller Länge in _messages
#   2. Session-JSONL mit derselben Länge
#   3. System-Prompt inklusive Wiki-Stand ungekürzt
#   4. tool_read_file liefert die ganze Datei
#   5. übergroßes Tool-Ergebnis → Kopf + Ablagepfad, Ablage vollständig
#   6. Antwort des Servers (llama→lex) ungekürzt im Kontext
#
# NUR hohe Ports — der echte llama-server (8080) wird nicht angerührt.
#
# shellcheck disable=SC2154  # _messages/_mock_file/_system_prompt stammen aus dem geloadenen lex
set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEX_DIR="$(dirname "$SCRIPT_DIR")"

TMP="$(mktemp -d)"
FAKE_PID=""
cleanup() {
  if [[ -n "${FAKE_PID:-}" ]]; then
    kill "$FAKE_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
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
    printf '  [FAIL] %s (nicht enthalten: %q)\n' "$desc" "$needle" >&2
    printf '         Text (Anfang): %q\n' "${hay:0:200}" >&2
    FAIL=1
  fi
}
check() {   # "desc" "1"|"0"
  if [[ "$2" == "1" ]]; then
    printf '  [PASS] %s\n' "$1"
  else
    printf '  [FAIL] %s\n' "$1" >&2
    FAIL=1
  fi
}
mkbig() {   # $1 = Anzahl Zeichen, mit Escaping-Stress (Quotes, Backslash, Tab, Zeilen)
  local n="$1"
  awk -v n="$n" 'BEGIN{
    s = "Zeile \"mit\" Anfuehrungszeichen und \\ Backslash und\tTab und\\nNewline ";
    while (length(out) < n) out = out s;
    printf "%s", substr(out, 1, n)
  }'
}

start_fake() {
  kill_fake
  local port
  for _ in $(seq 1 30); do
    port=$((20000 + RANDOM % 8000))
    nc -z 127.0.0.1 "$port" 2>/dev/null || break
    port=""
  done
  if [[ -z "${port:-}" ]]; then
    echo "FEHLSCHLAG: kein freier Port" >&2
    exit 1
  fi
  FAKE_PID="$(bash "$SCRIPT_DIR/fake_server.sh" "$port" "$1" 2>/dev/null)"
  if [[ -z "$FAKE_PID" ]]; then
    echo "FEHLSCHLAG: Fake-Server startet nicht" >&2
    exit 1
  fi
  local _
  for _ in $(seq 1 30); do
    nc -z 127.0.0.1 "$port" 2>/dev/null && break
    sleep 0.1
  done
  LEX_API_URL="http://127.0.0.1:$port/v1/chat/completions"
  export LEX_API_URL
}
kill_fake() {
  if [[ -n "${FAKE_PID:-}" ]]; then
    kill "$FAKE_PID" 2>/dev/null || true
    FAKE_PID=""
  fi
}

# ---------------------------------------------------------------------------
# lex sourceen: LEX_HOME isoliert, Mock aus (der HTTP-Pfad wird getestet).
# ---------------------------------------------------------------------------
export LEX_HOME="$TMP"
export LEX_MODEL="$TMP/model.gguf"
# Wiki isoliert: sonst hängt der echte Wiki-Stand am System-Prompt und die
# Längen-Aussagen unten treffen nicht mehr zu.
export LEX_WIKI_DIR="$TMP/wiki"
mkdir -p "$TMP/wiki"
unset LEX_MOCK
unset LEX_MOCK_FILE
# Isolation (2026-10-19, Fund-Beleg im wiki-Log): die Auto-Compaction ist hier
# KEIN Testgegenstand — der Aufbau dieses Tests legt absichtlich ~560 KB
# Kontext an (280 000 B user + 280 000 B tool, Schätzung ~208 000). Sobald die
# Compaction-Schwelle darunter liegt (ctx-Default 180224 → Schwelle 160224),
# feuert der Summary-Call VOR dem Spill-Block, verbraucht die Mock-Sequenz und
# der 60 000-B-bash-Call kommt nie mehr an — es fehlen Spill-Zeiger, Spill-Pfad
# und Ablage (3 FAILs, ohne dass lex defekt wäre: rc 0 mit LEX_COMPACT=off und
# mit LEX_CTX_LIMIT=262144, rc 1 nur mit dem neuen Default). Compaction selbst
# testet test_compaction.sh; dieser Läufer schaltet sie für sich ab.
export LEX_COMPACT=off
source "$LEX_DIR/lex" < /dev/null > /dev/null 2>&1 || {
  echo "FEHLSCHLAG: $LEX_DIR/lex nicht ladbar (Syntax-/Bash-Fehler)" >&2
  exit 1
}
setup_messages >/dev/null 2>&1 || true
session_file="${_session_file:-}"

# ===========================================================================
# 1. append_message: lange Nachricht kommt vollständig an
# ===========================================================================
printf '  [INFO] append_message (280 000 Zeichen)\n'
big="$(mkbig 280000)"
blen=${#big}
append_message "user" "$big"
got="$(jq -r '.[-1].content | length' <<< "$_messages" 2>/dev/null)"
assert "limits (user-Content vollständig)" "$blen" "$got"
not_contains "limits (user-Content ohne Kürzungs-Marker)" "gekürzt" \
  "$(jq -r '.[-1].content' <<< "$_messages" 2>/dev/null)"

# ===========================================================================
# 2. append_tool_message: langes Tool-Ergebnis kommt vollständig an
# ===========================================================================
printf '  [INFO] append_tool_message (280 000 Zeichen)\n'
append_tool_message "tc-limits" "$big"
got="$(jq -r '.[-1].content | length' <<< "$_messages" 2>/dev/null)"
assert "limits (tool-Content vollständig)" "$blen" "$got"
assert "limits (tool-Message mit id)" "tc-limits" \
  "$(jq -r '.[-1].tool_call_id // ""' <<< "$_messages" 2>/dev/null)"
assert "limits (rolle bleibt tool)" "tool" \
  "$(jq -r '.[-1].role' <<< "$_messages" 2>/dev/null)"

# ===========================================================================
# 3. Session: derselbe Datensatz steht vollständig in der JSONL
# ===========================================================================
printf '  [INFO] Session-JSONL\n'
if [[ -n "$session_file" && -f "$session_file" ]]; then
  rec="$(jq -r 'select(.type=="message") | .message.content | length' "$session_file" 2>/dev/null | tail -n 1)"
  assert "limits (Session enthält volle Länge)" "$blen" "$rec"
  check "limits (Session-JSONL ist gültig)" \
    "$([[ "$(jq -s '.' "$session_file" >/dev/null 2>&1; echo $?)" == "0" ]] && echo 1 || echo 0)"
else
  printf '  [FAIL] limits: Session-Datei fehlt (%s)\n' "${session_file:-leer}" >&2
  FAIL=1
fi

# ===========================================================================
# 4. tool_read_file: ganze Datei, keine eigene Kappe mehr
# ===========================================================================
printf '  [INFO] tool_read_file (60 000 Bytes)\n'
awk 'BEGIN{for(i=0;i<60000;i++)printf "r"}' > "$TMP/gross.txt"
out="$(tool_read_file "$TMP/gross.txt" 2>/dev/null)"
assert "limits (read_file: ganze Datei)" "60000" "${#out}"
not_contains "limits (read_file: kein Kürzungs-Marker)" "abgeschnitten" "$out"

# ===========================================================================
# 5. übergroßes Tool-Ergebnis → Kopf + Ablagepfad, Ablage vollständig
# ===========================================================================
printf '  [INFO] Spill (60 000 Bytes an das Modell)\n'
MOCK="$TMP/mock_spill.jsonl"
cmd="$(jq -cn --arg c "awk 'BEGIN{for(i=0;i<60000;i++)printf \"s\"}'" '{command:$c}')"
{
  jq -cn --argjson a "$cmd" \
    '{choices:[{index:0,message:{role:"assistant",content:"",reasoning_content:"",
      tool_calls:[{id:"tc-spill",type:"function",
        function:{name:"bash",arguments:($a|tostring)}}]}}],
      usage:{total_tokens:10}}'
  jq -cn '{choices:[{index:0,message:{role:"assistant",content:"fertig",
    reasoning_content:"",tool_calls:[]}}],usage:{total_tokens:10}}'
} > "$MOCK"
_mock_file="$MOCK"
run_turn "großes Ergebnis" < /dev/null > /dev/null 2>&1
_mock_file=""

toolmsg="$(jq -r '.[] | select(.role=="tool") | .content' <<< "$_messages" 2>/dev/null)"
contains "limits (Spill-Zeiger im Kontext)" "vollständige Ausgabe liegt unter" "$toolmsg"
contains "limits (Spill-Pfad im Kontext)" "$LEX_HOME/toolout/" "$toolmsg"
spill="$(ls -1 "$LEX_HOME/toolout/"*.txt 2>/dev/null | head -n 1)"
if [[ -n "$spill" ]]; then
  slen="$(wc -c < "$spill" | tr -d ' ')"
  check "limits (Ablage vollständig ≥ 60 000 Bytes)" "$([[ "$slen" -ge 60000 ]] && echo 1 || echo 0)"
  printf '         Ablage: %s (%s Bytes)\n' "$spill" "$slen"
else
  printf '  [FAIL] limits: keine Ablage unter %s/toolout\n' "$LEX_HOME" >&2
  FAIL=1
fi

# M1 (Audit 2026-10-08): der Spill liegt mit 600 und REDIGIERT auf Platte —
# vorher ging die rohe Tool-Ausgabe ungeschützt in toolout/.
m1="$(_tool_spill m1probe 'PASSWORD=hunter2 api_key=ghp_secret123')"
check "limits (M1: Spill angelegt)" "$([[ -n "$m1" && -f "$m1" ]] && echo 1 || echo 0)"
assert "limits (M1: Spill-Rechte 600)" "600" \
  "$(stat -c '%a' "$m1" 2>/dev/null || stat -f '%Lp' "$m1" 2>/dev/null)"
m1c="$(cat "$m1" 2>/dev/null)"
check "limits (M1: Geheimnis redigiert)" \
  "$([[ "$m1c" != *hunter2* && "$m1c" != *ghp_secret123* && "$m1c" == *REDACT* ]] && echo 1 || echo 0)"

# ===========================================================================
# 6. Antwort des Servers (llama→lex): 150 000 Zeichen ungekürzt im Kontext
# ===========================================================================
printf '  [INFO] Server-Antwort (150 000 Zeichen)\n'
mkbig 150000 > "$TMP/antwort.txt"
{
  printf 'data: '
  jq -cn --rawfile c "$TMP/antwort.txt" '{choices:[{index:0,delta:{content:$c}}]}'
  printf '\n'
  printf 'data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\n'
  printf 'data: [DONE]\n\n'
} > "$TMP/gross.sse"
start_fake "$TMP/gross.sse"
_mock_file=""
run_turn "lange Antwort" < /dev/null > /dev/null 2>&1
kill_fake
alen=150000
got="$(jq -r '.[-1].content | length' <<< "$_messages" 2>/dev/null)"
assert "limits (Server-Antwort vollständig)" "$alen" "$got"
assert "limits (Rolle assistant)" "assistant" \
  "$(jq -r '.[-1].role' <<< "$_messages" 2>/dev/null)"
not_contains "limits (Server-Antwort ohne Kürzungs-Marker)" "gekürzt" \
  "$(jq -r '.[-1].content' <<< "$_messages" 2>/dev/null)"

# ===========================================================================
# 7. System-Prompt inklusive Wiki-Stand: keine 100 000-Byte-Kappe
# ===========================================================================
printf '  [INFO] System-Prompt (250 000 Zeichen)\n'
orig_sys="$_system_prompt"
_system_prompt="$(mkbig 250000)"
setup_messages >/dev/null 2>&1
got="$(jq -r '.[0].content | length' <<< "$_messages" 2>/dev/null)"
assert "limits (System-Prompt vollständig)" "250000" "$got"
not_contains "limits (System-Prompt ohne Kürzungs-Marker)" "gekürzt" \
  "$(jq -r '.[0].content' <<< "$_messages" 2>/dev/null)"
_system_prompt="$orig_sys"
setup_messages >/dev/null 2>&1

echo ""
if (( FAIL > 0 )); then
  printf 'FEHLSCHLAG: %s Test(s) in test_limits.sh\n' "$FAIL" >&2
  exit 1
fi
echo "test_limits.sh grün. ✓"
exit 0
