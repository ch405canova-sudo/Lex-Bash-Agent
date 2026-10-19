#!/usr/bin/env bash
#
# lex/test/test_http.sh — Echter curl-Pfad in call_api() über Fake-OpenAI-Server.
# Startet fake_server.sh auf einem hohen Port, zeigt LEX_API_URL darauf,
# und testet den echten HTTP-Body-Construction (jq -n + curl), OHNE den
# llama-server (Port 8080) anzurühren.
#
set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEX_DIR="$(dirname "$SCRIPT_DIR")"

TMP="$(mktemp -d)"
FAKE_PID=""
cleanup() {
  # Erst den Server töten, dann aufräumen: Handler/Lock liegen im TMP
  # und werden von ncat pro Verbindung erst noch gebraucht.
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

# 1. Fake-Server-Response-Datei (eine JSON-Response pro Zeile)
resp="$TMP/responses.json"
printf '%s\n%s\n' \
  '{"choices":[{"index":0,"message":{"role":"assistant","content":"Hallo über HTTP!","reasoning_content":"","tool_calls":[]},"finish_reason":"stop"}],"usage":{"total_tokens":10}}' \
  '{"choices":[{"index":0,"message":{"role":"assistant","content":"Fertig.","reasoning_content":"","tool_calls":[]},"finish_reason":"stop"}],"usage":{"total_tokens":10}}' > "$resp"

contains() {
  local desc="$1" needle="$2" hay="$3"
  if [[ "$hay" == *"$needle"* ]]; then
    printf '  [PASS] %s\n' "$desc"
  else
    printf '  [FAIL] %s (suchte: %q)\n' "$desc" "$needle" >&2
    printf '         Text: %q\n' "$hay" >&2
    FAIL=1
  fi
}

# 1b. Bind-Nachweis (Audit-Fund M11): Wer den Port belegt hält, bekommt
#     KEINE „erfolgreiche" Startmeldung. Vorher prüfte fake_server.sh nur
#     `nc -z` — das trifft auch den Fremd-Listener, wenn unser ncat nicht
#     binden konnte → die Tests hätten mit dem falschen Server geredet.
BIND_PORT=$((20000 + RANDOM % 8000))
ncat --listen 127.0.0.1 "$BIND_PORT" -k </dev/null >/dev/null 2>&1 &
FOREIGN_PID=$!
for _ in $(seq 1 30); do
  nc -z 127.0.0.1 "$BIND_PORT" 2>/dev/null && break
  sleep 0.1
done
bind_rc=0
bind_out="$(bash "$SCRIPT_DIR/fake_server.sh" "$BIND_PORT" "$resp" 2>"$TMP/bind_err.txt")" || bind_rc=$?
assert "fake_server (fremder Listener → rc != 0)" "1" "$([[ $bind_rc -ne 0 ]] && echo 1 || echo 0)"
assert "fake_server (fremder Listener → keine PID ausgegeben)" "0" "$([[ -n "$bind_out" ]] && echo 1 || echo 0)"
assert "fake_server (fremder Listener → Fehlermeldung)" "1" \
  "$([[ "$(cat "$TMP/bind_err.txt" 2>/dev/null)" == *"Fehler: Fake-Server"* ]] && echo 1 || echo 0)"

# M12 (Audit 2026-10-08): fake_server meldet den belegten Port auch im
# Wortlaut. Der zweite Lauf muss VOR dem kill passieren — danach ist der Port
# frei, fake_server startete erfolgreich, legte einen zweiten, nicht
# aufgeräumten Listener an und meldete nie „belegt“. contains sucht LITERAL,
# die alte Needle war grep-Syntax (\|).
bind2_out="$(bash "$SCRIPT_DIR/fake_server.sh" "$BIND_PORT" "$resp" 2>&1)" || true
contains "fake_server (Port belegt meldet)" "belegt" "$bind2_out"

kill "$FOREIGN_PID" 2>/dev/null || true
wait "$FOREIGN_PID" 2>/dev/null || true

# 2. Fake-Server auf einem hohen Port starten
FAKE_PORT=$((20000 + RANDOM % 8000))
FAKE_PID="$(bash "$SCRIPT_DIR/fake_server.sh" "$FAKE_PORT" "$resp")"
if [[ -z "$FAKE_PID" ]]; then
  echo "FEHLSCHLAG: Fake-Server konnte auf Port $FAKE_PORT nicht gestartet werden" >&2
  exit 1
fi

# Port-Wait (Fake-Server wartet intern, aber sicherheitshalber nochmal)
for _ in $(seq 1 30); do
  if nc -z 127.0.0.1 "$FAKE_PORT" 2>/dev/null; then
    break
  fi
  sleep 0.1
done

# 3. lex sourceen mit echtem HTTP-Pfad (Mock aus, API-URL auf Fake-Server)
export LEX_HOME="$TMP"
export LEX_MODEL="$TMP/model.gguf"
export LEX_API_URL="http://127.0.0.1:$FAKE_PORT/v1/chat/completions"
unset LEX_MOCK
unset LEX_MOCK_FILE
source "$LEX_DIR/lex" < /dev/null > /dev/null 2>&1 || {
  echo "FEHLSCHLAG: $LEX_DIR/lex nicht ladbar (Syntax-/Bash-Fehler)" >&2
  exit 1
}

# 4. Test: finale Antwort über echten HTTP-Pfad
out="$(run_turn "Test über HTTP" 2>/dev/null)"
assert "http (finale Antwort)" "Hallo über HTTP!" "$out"

# 5. Test: Multi-Turn (2. Antwort kommt vom Server, 1. war Tool-Call)
resp2="$TMP/responses2.json"
printf '%s\n%s\n' \
  '{"choices":[{"index":0,"message":{"role":"assistant","content":"","tool_calls":[{"id":"tc1","type":"function","function":{"name":"read_file","arguments":"{\"path\":\"'$TMP'/http.txt\"}"}}]},"finish_reason":"stop"}]}' \
  '{"choices":[{"index":0,"message":{"role":"assistant","content":"Lesen fertig.","reasoning_content":"","tool_calls":[]},"finish_reason":"stop"}]}' > "$resp2"

# Fake-Server neu starten mit neuer Response-Datei (alter ist aufgebraucht)
kill "$FAKE_PID" 2>/dev/null || true
FAKE_PID=""
FAKE_PORT=$((20000 + RANDOM % 8000))
FAKE_PID="$(bash "$SCRIPT_DIR/fake_server.sh" "$FAKE_PORT" "$resp2")"
if [[ -z "$FAKE_PID" ]]; then
  echo "FEHLSCHLAG: Fake-Server (2. Start) konnte auf Port $FAKE_PORT nicht gestartet werden" >&2
  exit 1
fi
for _ in $(seq 1 30); do
  if nc -z 127.0.0.1 "$FAKE_PORT" 2>/dev/null; then
    break
  fi
  sleep 0.1
done
export LEX_API_URL="http://127.0.0.1:$FAKE_PORT/v1/chat/completions"
printf 'Inhalt\n' > "$TMP/http.txt"
out="$(run_turn "Lesen" 2>/dev/null)"
assert "http (Multi-Turn mit Tool)" "Lesen fertig." "$out"

#6. Body > 128 KiB: exec-Argument-Limit (E2BIG) — curl bekommt @file statt
#   argv-String (Fund 2026-09-29: Mehrfach-Turns schieben die Historie
#   über die Kernel-Grenze; ohne Fix: „Argumentliste zu lang").
resp3="$TMP/responses3.json"
printf '%s\n' '{"choices":[{"index":0,"message":{"role":"assistant","content":"Großer Body ok.","reasoning_content":"","tool_calls":[]}}],"usage":{"total_tokens":1}}' > "$resp3"
kill "$FAKE_PID" 2>/dev/null || true
FAKE_PID=""
FAKE_PORT=$((20000 + RANDOM % 8000))
FAKE_PID="$(bash "$SCRIPT_DIR/fake_server.sh" "$FAKE_PORT" "$resp3")"
if [[ -z "$FAKE_PID" ]]; then
  echo "FEHLSCHLAG: Fake-Server (3. Start) konnte nicht gestartet werden" >&2
  exit 1
fi
for _ in $(seq 1 30); do
  if nc -z 127.0.0.1 "$FAKE_PORT" 2>/dev/null; then
    break
  fi
  sleep 0.1
done
export LEX_API_URL="http://127.0.0.1:$FAKE_PORT/v1/chat/completions"
big="$(printf '%*s' 140000 '')"
append_message user "$big"
# Zweite Riesen-Message: >131072 B Gesamtkontext — hätte jq weiterhin
# --argjson m (statt --slurpfile), scheiterte der Body-Bau an E2BIG und
# der rc-Guard von call_api brächte den Test zum Fallen (Deckung für
# den jq-Fix, Review-Fund 2026-09-29).
append_message user "$big"
mrc=0; out="$(run_turn "Groß" 2>/dev/null)" || mrc=$?
assert "http (Body > 128 KiB läuft, E2BIG-Fix)" "Großer Body ok." "$out"
assert "http (Body > 128 KiB rc)" "0" "$mrc"

# 7. Retry-Pfad (Schritt 53, §6 #36): HTTP 500 wird WIEDERHOLT, bevor der
#    Turn stirbt — Norm des OpenAI-SDKs. Script-Datei: erste Zeile 500,
#    zweite Zeile gültig → nach einem Backoff muss die Antwort kommen.
resp4="$TMP/responses4.json"
printf '%s\n%s\n' \
  'STATUS:500|{"error":"boom"}' \
  '{"choices":[{"index":0,"message":{"role":"assistant","content":"Nach dem Retry.","reasoning_content":"","tool_calls":[]},"finish_reason":"stop"}],"usage":{"total_tokens":10}}' > "$resp4"
kill "$FAKE_PID" 2>/dev/null || true
FAKE_PID=""
FAKE_PORT=$((20000 + RANDOM % 8000))
FAKE_PID="$(bash "$SCRIPT_DIR/fake_server.sh" "$FAKE_PORT" "$resp4")"
if [[ -z "$FAKE_PID" ]]; then
  echo "FEHLSCHLAG: Fake-Server (4. Start) konnte nicht gestartet werden" >&2
  exit 1
fi
for _ in $(seq 1 30); do
  if nc -z 127.0.0.1 "$FAKE_PORT" 2>/dev/null; then
    break
  fi
  sleep 0.1
done
export LEX_API_URL="http://127.0.0.1:$FAKE_PORT/v1/chat/completions"
export LEX_API_RETRIES=1
_api_retries=1   # load_config lief bereits beim Source — Tier 4 greift sonst nie
# shellcheck disable=SC2154  # _log_dir kommt aus dem gesourcten lex
rm -f "$_log_dir/lex.log"
setup_messages
mrc=0; out="$(run_turn "Nach dem Retry" 2>"$TMP/err4.txt")" || mrc=$?
assert "retry (Antwort nach HTTP 500)" "Nach dem Retry." "$out"
assert "retry (rc=0)" "0" "$mrc"
assert "retry (Backoff protokolliert)" "1" \
  "$([[ "$(cat "$_log_dir/lex.log" 2>/dev/null)" == *"Versuch 1 fehlgeschlagen"* ]] && echo 1 || echo 0)"

# Ohne Budget (LEX_API_RETRIES=0): derselbe 500 muss hart fehlschlagen.
resp5="$TMP/responses5.json"
printf '%s\n' 'STATUS:500|{"error":"boom"}' > "$resp5"
kill "$FAKE_PID" 2>/dev/null || true
FAKE_PID=""
FAKE_PORT=$((20000 + RANDOM % 8000))
FAKE_PID="$(bash "$SCRIPT_DIR/fake_server.sh" "$FAKE_PORT" "$resp5")"
if [[ -z "$FAKE_PID" ]]; then
  echo "FEHLSCHLAG: Fake-Server (5. Start) konnte nicht gestartet werden" >&2
  exit 1
fi
for _ in $(seq 1 30); do
  if nc -z 127.0.0.1 "$FAKE_PORT" 2>/dev/null; then
    break
  fi
  sleep 0.1
done
export LEX_API_URL="http://127.0.0.1:$FAKE_PORT/v1/chat/completions"
export LEX_API_RETRIES=0
_api_retries=0
rm -f "$_log_dir/lex.log"
setup_messages
mrc=0; out="$(run_turn "Ohne Budget" 2>"$TMP/err5.txt")" || mrc=$?
assert "retry aus (rc != 0)" "1" "$([[ "$mrc" -ne 0 ]] && echo 1 || echo 0)"
assert "retry aus (kein Backoff im Log)" "0" \
  "$([[ "$(cat "$_log_dir/lex.log" 2>/dev/null)" == *"Versuch 1 fehlgeschlagen"* ]] && echo 1 || echo 0)"
if grep -q "HTTP 500" "$TMP/err5.txt" 2>/dev/null; then
  printf '  [PASS] retry aus (HTTP 500 genannt)\n'
else
  printf '  [FAIL] retry aus (kein HTTP 500 in der Meldung): %q\n' "$(cat "$TMP/err5.txt" 2>/dev/null)" >&2
  FAIL=1
fi
unset LEX_API_RETRIES

# 8. M5 (2026-10-08): `--server` fragt den KONFIGURIERTEN Ursprung ab
#    (`_api_url`) statt hartkodiert 127.0.0.1:8080 — sonst widersprach der
#    Status dem server_hint und meldete „nicht erreichbar", obwohl der
#    Server auf dem konfigurierten Port lief.
HPORT=$((20000 + RANDOM % 8000))
cat > "$TMP/health_srv.sh" <<'HEALTH_EOF'
#!/bin/bash
IFS= read -r _req || exit 0
while IFS= read -r _l; do [[ -z "${_l%$'\r'}" ]] && break; done
body='{"status":"ok"}'
printf 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s' "${#body}" "$body"
HEALTH_EOF
ncat --listen 127.0.0.1 "$HPORT" -k --sh-exec "bash $TMP/health_srv.sh" </dev/null >/dev/null 2>&1 &
HEALTH_PID=$!
for _ in $(seq 1 30); do
  nc -z 127.0.0.1 "$HPORT" 2>/dev/null && break
  sleep 0.1
done
sout="$(LEX_API_URL="http://127.0.0.1:$HPORT/v1/chat/completions" bash "$LEX_DIR/lex" --server 2>&1)"
src=$?
assert "server (konfigurierter Port beantwortet /health)" "0" "$src"
contains "server (health-Text vom konfigurierten Port)" '"status":"ok"' "$sout"
kill "$HEALTH_PID" 2>/dev/null || true
wait "$HEALTH_PID" 2>/dev/null || true

# Ohne Listener: Fehlerstatus statt „nicht erreichbar" mit rc 0.
sout="$(LEX_API_URL="http://127.0.0.1:$HPORT/v1/chat/completions" bash "$LEX_DIR/lex" --server 2>&1)"
src=$?
assert "server (nicht erreichbar → rc 1)" "1" "$src"
contains "server (Meldung nennt den konfigurierten Ursprung)" "nicht erreichbar" "$sout"

if (( FAIL > 0 )); then
  echo "FEHLSCHLAG: $FAIL Test(s) in test_http.sh" >&2
  exit 1
fi
echo "test_http.sh grün. ✓"
exit 0
