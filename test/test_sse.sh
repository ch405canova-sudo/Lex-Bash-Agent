#!/usr/bin/env bash
#
# lex/test/test_sse.sh — Streaming-Pfad in call_api() über Fake-SSE-Server.
#
# Regressionen, die der Streaming-Umbau (2026-09-30) brachte, und die dieser
# Test festnagelt:
#   1. curl-rc und HTTP-Code werden ECHT gemessen (Server weg / HTTP-Fehler
#      → echte Fehlermeldung, nicht „Antwort war leer" als Nudge).
#   2. tool_calls werden über mehrere Deltas zusammengeführt (vorher überlebte
#      nur das letzte Delta → Name None, Argumente ein Fragment wie "}").
#   3. data:-Prefix funktioniert auch ohne Leerzeichen.
#   4. abgebrochener Stream (kein [DONE]) wird ausdrücklich gewarnt.
#
# NUR hohe Ports — der echte llama-server (8080) wird nicht angerührt.
#
set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEX_DIR="$(dirname "$SCRIPT_DIR")"

TMP="$(mktemp -d)"
FAKE_PID=""
FAKE_PORT=""
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
    printf '         Text: %q\n' "$hay" >&2
    FAIL=1
  fi
}
not_contains() {
  local desc="$1" needle="$2" hay="$3"
  if [[ "$hay" != *"$needle"* ]]; then
    printf '  [PASS] %s\n' "$desc"
  else
    printf '  [FAIL] %s (nicht enthalten: %q)\n' "$desc" "$needle" >&2
    printf '         Text: %q\n' "$hay" >&2
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

start_fake() {   # $1 = Script- oder SSE-Datei
  kill_fake
  FAKE_PORT=$((20000 + RANDOM % 8000))
  FAKE_PID="$(bash "$SCRIPT_DIR/fake_server.sh" "$FAKE_PORT" "$1" 2>/dev/null)"
  if [[ -z "$FAKE_PID" ]]; then
    echo "FEHLSCHLAG: Fake-Server startet nicht (Port $FAKE_PORT)" >&2
    exit 1
  fi
  local _
  for _ in $(seq 1 30); do
    nc -z 127.0.0.1 "$FAKE_PORT" 2>/dev/null && break
    sleep 0.1
  done
  export LEX_API_URL="http://127.0.0.1:$FAKE_PORT/v1/chat/completions"
}
kill_fake() {
  if [[ -n "${FAKE_PID:-}" ]]; then
    kill "$FAKE_PID" 2>/dev/null || true
    FAKE_PID=""
  fi
}
free_port() {   # Port, auf dem gar nichts lauscht
  local p
  for _ in $(seq 1 20); do
    p=$((20000 + RANDOM % 8000))
    nc -z 127.0.0.1 "$p" 2>/dev/null || { printf '%s' "$p"; return 0; }
  done
  echo "FEHLSCHLAG: kein freier Port gefunden" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# lex sourceen wie test_http.sh: Mock aus, LEX_HOME isoliert.
# (Beim Sourcen läuft main mit leerem Kommando → load_config.)
# ---------------------------------------------------------------------------
export LEX_HOME="$TMP"
export LEX_MODEL="$TMP/model.gguf"
unset LEX_MOCK
unset LEX_MOCK_FILE
source "$LEX_DIR/lex" < /dev/null > /dev/null 2>&1 || {
  echo "FEHLSCHLAG: $LEX_DIR/lex nicht ladbar (Syntax-/Bash-Fehler)" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# 1. Content über mehrere Deltas
# ---------------------------------------------------------------------------
printf '%s\n' \
  'data: {"choices":[{"index":0,"delta":{"content":"Hallo "}}]}' \
  '' \
  'data: {"choices":[{"index":0,"delta":{"content":"über SSE."}}]}' \
  '' \
  'data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}' \
  '' \
  'data: [DONE]' \
  '' > "$TMP/inhalt.sse"
start_fake "$TMP/inhalt.sse"
out="$(run_turn "Test" 2>/dev/null)"
assert "sse (Content über Deltas)" "Hallo über SSE." "$out"

# ---------------------------------------------------------------------------
# 2. tool_calls über mehrere Deltas (Name im ersten, Argumente verteilt)
# ---------------------------------------------------------------------------
printf 'Inhalt der Datei\n' > "$TMP/tool.txt"
printf '%s\n' \
  'data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"read_file","arguments":""}}]}}]}' \
  '' \
  'data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"path\":"}}]}}]}' \
  '' \
  "data: {\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"\\\"$TMP/tool.txt\\\"}\"}}]}}]}" \
  '' \
  'data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}' \
  '' \
  'data: [DONE]' \
  '' > "$TMP/toolcall.sse"
start_fake "$TMP/toolcall.sse"
resp="$(call_api 2>/dev/null)"
rc=$?
assert "sse (tool_calls: call_api rc)" "0" "$rc"
assert "sse (tool_calls: genau ein Eintrag)" "1" \
  "$(jq '.choices[0].message.tool_calls | length' <<< "$resp" 2>/dev/null)"
assert "sse (tool_calls: Name aus dem ersten Delta)" "read_file" \
  "$(jq -r '.choices[0].message.tool_calls[0].function.name' <<< "$resp" 2>/dev/null)"
assert "sse (tool_calls: Argumente zusammengesetzt)" "{\"path\":\"$TMP/tool.txt\"}" \
  "$(jq -r '.choices[0].message.tool_calls[0].function.arguments' <<< "$resp" 2>/dev/null)"
assert "sse (tool_calls: id aus dem ersten Delta)" "call_1" \
  "$(jq -r '.choices[0].message.tool_calls[0].id' <<< "$resp" 2>/dev/null)"

# ---------------------------------------------------------------------------
# 3. Server nicht erreichbar → ECHTER Fehler, kein Leer-Antwort-Nudge
# ---------------------------------------------------------------------------
LEX_API_URL="http://127.0.0.1:$(free_port)/v1/chat/completions"
export LEX_API_URL
rc=0
run_turn "Hallo" >"$TMP/out3.txt" 2>"$TMP/err3.txt" || rc=$?
err3="$(cat "$TMP/err3.txt")"
check "sse (Server weg → rc != 0)" "$([[ $rc -ne 0 ]] && echo 1 || echo 0)"
contains "sse (Server weg → Fehlermeldung)" "Anfrage fehlgeschlagen" "$err3"
contains "sse (Server weg → API-Fehler statt Stillschweigen)" "API-Fehler" "$err3"
not_contains "sse (Server weg → kein Leer-Antwort-Nudge)" "Antwort war leer" "$err3"

# ---------------------------------------------------------------------------
# 4. HTTP-Fehler (500) → echter Fehler mit Statuscode
# ---------------------------------------------------------------------------
# DREI 500-Zeilen: call_api versucht es standardmäßig dreimal (2 Wieder-
# holungen, Schritt 53) — nur wenn ALLE fehlschlagen, darf der Turn mit
# rc != 0 enden. Eine Erfolgszeile dazwischen wäre still grün gewesen.
statusfile="$TMP/status.json"
printf 'STATUS:500|{"error":"boom"}\n%.0s' 1 2 3 > "$statusfile"
start_fake "$statusfile"
rc=0
run_turn "Hallo" >"$TMP/out4.txt" 2>"$TMP/err4.txt" || rc=$?
err4="$(cat "$TMP/err4.txt")"
check "sse (HTTP 500 → rc != 0)" "$([[ $rc -ne 0 ]] && echo 1 || echo 0)"
contains "sse (HTTP 500 → Statuscode genannt)" "HTTP 500" "$err4"
contains "sse (HTTP 500 → alle Versuche erschöpft)" "nach 3 Versuch(en)" "$err4"
not_contains "sse (HTTP 500 → kein Nudge)" "Antwort war leer" "$err4"

# ---------------------------------------------------------------------------
# 5. data: ohne Leerzeichen (SSE-konform)
# ---------------------------------------------------------------------------
printf '%s\n' \
  'data:{"choices":[{"index":0,"delta":{"content":"Ohne Leerzeichen."}}]}' \
  '' \
  'data:{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}' \
  '' \
  'data:[DONE]' \
  '' > "$TMP/praesix.sse"
start_fake "$TMP/praesix.sse"
out="$(run_turn "Test" 2>/dev/null)"
assert "sse (data: ohne Leerzeichen)" "Ohne Leerzeichen." "$out"

# ---------------------------------------------------------------------------
# 6. Stream endet ohne [DONE] → Warnung, Text wird trotzdem genutzt
# ---------------------------------------------------------------------------
printf '%s\n' \
  'data: {"choices":[{"index":0,"delta":{"content":"Teiltext."}}]}' \
  '' \
  'data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}' \
  '' > "$TMP/kein_done.sse"
start_fake "$TMP/kein_done.sse"
rc=0
out="$(run_turn "Test" 2>"$TMP/err6.txt")" || rc=$?
assert "sse (Teiltext wird genutzt)" "Teiltext." "$out"
check "sse (ohne [DONE] → rc 0)" "$([[ $rc -eq 0 ]] && echo 1 || echo 0)"
contains "sse (ohne [DONE] → ausdrückliche Warnung)" "ohne [DONE]" "$(cat "$TMP/err6.txt")"

# ---------------------------------------------------------------------------
# 7. Body ohne data:-Event → auswertbarer Fehler, keine leere „Antwort"
# ---------------------------------------------------------------------------
printf 'das ist kein Stream\n' > "$TMP/kein_stream.sse"
start_fake "$TMP/kein_stream.sse"
rc=0
run_turn "Test" >"$TMP/out7.txt" 2>"$TMP/err7.txt" || rc=$?
check "sse (Body ohne data:-Event → rc != 0)" "$([[ $rc -ne 0 ]] && echo 1 || echo 0)"
contains "sse (Body ohne data:-Event → Fehlermeldung)" "nicht auswertbar" "$(cat "$TMP/err7.txt")"

# ---------------------------------------------------------------------------
# 8. Performance-Budget (Regression vom 2026-09-30: ~4 jq-Forks pro SSE-Zeile
#    → 3000 Chunks kosteten 29 s). Budget: unter 2 s, und der Inhalt darf
#    vollständig ankommen (sonst wäre „schnell" nur eine abgeschnittene Antwort).
# ---------------------------------------------------------------------------
{
  for _ in $(seq 1 3000); do
    printf 'data: {"choices":[{"index":0,"delta":{"content":"x"}}]}\n\n'
  done
  printf 'data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\n'
  printf 'data: [DONE]\n\n'
} > "$TMP/3000.sse"
start_fake "$TMP/3000.sse"
t0="$(_ms_now)"
rc=0
resp="$(call_api 2>/dev/null)" || rc=$?
t1="$(_ms_now)"
ms=$(( t1 - t0 ))
check "sse (Budget: 3000 Chunks → rc 0)" "$([[ $rc -eq 0 ]] && echo 1 || echo 0)"
assert "sse (Budget: Inhalt vollständig, keine Stille Kürzung)" "3000" \
  "$(jq -r '.choices[0].message.content | length' <<< "$resp" 2>/dev/null)"
if (( ms < 2000 )); then
  printf '  [PASS] sse (Budget: 3000 Chunks unter 2000 ms — %d ms)\n' "$ms"
else
  printf '  [FAIL] sse (Budget: 3000 Chunks unter 2000 ms — waren %d ms)\n' "$ms" >&2
  FAIL=1
fi

# ---------------------------------------------------------------------------
# 9. Request-Body fordert die Usage an (Review-Fund 2026-10-01: ohne
#    stream_options.include_usage liefert llama-server im Stream KEINE usage —
#    das HUD fragt statt Nullen zu erfinden). Der Body wird über
#    FAKE_BODY_LOG vom Fake-Server mitgeschrieben.
# ---------------------------------------------------------------------------
export FAKE_BODY_LOG="$TMP/body.log"
printf '%s\n' \
  'data: {"choices":[{"index":0,"delta":{"content":"Body."}}]}' \
  '' \
  'data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}' \
  '' \
  'data: [DONE]' \
  '' > "$TMP/body.sse"
start_fake "$TMP/body.sse"
rc=0
call_api >/dev/null 2>"$TMP/err9.txt" || rc=$?
body9="$(cat "$FAKE_BODY_LOG" 2>/dev/null)"
check "sse (Body-Log angelegt)" "$([[ -s "$FAKE_BODY_LOG" ]] && echo 1 || echo 0)"
assert "sse (Body: stream true)" "true" \
  "$(jq -r '.stream // "fehlt"' <<< "$body9" 2>/dev/null)"
assert "sse (Body: stream_options.include_usage)" "true" \
  "$(jq -r '.stream_options.include_usage // "fehlt"' <<< "$body9" 2>/dev/null)"
# Hebel 2 (2026-10-07): chat_template_kwargs muss IMMER mit — false ist der
# Template-Default (unverändertes Verhalten), true schaltet Thinking bei
# Tool-Requests ab. Achtung jq: `false // "fehlt"` liefert "fehlt" — der
# Wert wird daher über einen null-Vergleich geprüft, nicht über //.
_adwt_of() {
  jq -r '.chat_template_kwargs.auto_disable_thinking_with_tools
    | if . == null then "fehlt" elif type == "boolean" then tostring else "kaputt" end' \
    <<< "$1" 2>/dev/null
}
assert "sse (Body: adwt default false)" "false" "$(_adwt_of "$body9")"
# Der laufende Fake-Server behält sein ENV (FAKE_BODY_LOG-Pfad) — daher
# dasselbe Log leeren statt einen neuen Pfad zu exportieren.
: > "$FAKE_BODY_LOG"
_adwt_on_save="${_auto_disable_thinking_with_tools:-}"
_auto_disable_thinking_with_tools=on
call_api >/dev/null 2>"$TMP/err9b.txt" || rc=$?
body9b="$(cat "$FAKE_BODY_LOG" 2>/dev/null)"
assert "sse (Body: adwt bei on = true)" "true" "$(_adwt_of "$body9b")"
_auto_disable_thinking_with_tools="${_adwt_on_save}"
unset FAKE_BODY_LOG

# ---------------------------------------------------------------------------
# 10. Usage-Pfad: echte Zahlen im HUD, wenn der Server liefert — und
#     „?" statt erfundener Nullen, wenn nicht (Regression 2026-10-01).
# ---------------------------------------------------------------------------
export LEX_TRACE=1
printf '%s\n' \
  'data: {"choices":[{"index":0,"delta":{"content":"Mit Usage."}}]}' \
  '' \
  'data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}' \
  '' \
  'data: {"choices":[],"usage":{"prompt_tokens":1409,"completion_tokens":69,"total_tokens":1478}}' \
  '' \
  'data: [DONE]' \
  '' > "$TMP/mit_usage.sse"
start_fake "$TMP/mit_usage.sse"
rc=0
run_turn "Test" >"$TMP/out10.txt" 2>"$TMP/err10.txt" || rc=$?
contains "sse (usage im Stream → Antwort)" "Mit Usage." "$(cat "$TMP/out10.txt")"
# Schritt 42: HUD-Format mit Kontext-Limit (tokens X/Y (Z%))
contains "sse (usage im HUD)" "tokens 1409/180224 (0%) prompt + 69 completion" "$(cat "$TMP/err10.txt")"

printf '%s\n' \
  'data: {"choices":[{"index":0,"delta":{"content":"Ohne Usage."}}]}' \
  '' \
  'data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}' \
  '' \
  'data: [DONE]' \
  '' > "$TMP/ohne_usage.sse"
start_fake "$TMP/ohne_usage.sse"
rc=0
run_turn "Test" >"$TMP/out11.txt" 2>"$TMP/err11.txt" || rc=$?
hud11="$(cat "$TMP/err11.txt")"
contains "sse (keine usage → HUD fragt statt zu lügen)" "tokens ?/180224 prompt + ? completion" "$hud11"
not_contains "sse (keine usage → keine erfundenen Nullen)" "tokens 0/180224 (0%) prompt + 0 completion" "$hud11"
unset LEX_TRACE

echo ""
if (( FAIL > 0 )); then
  printf 'FEHLSCHLAG: %s Test(s) in test_sse.sh\n' "$FAIL" >&2
  exit 1
fi
echo "test_sse.sh grün. ✓"
exit 0
