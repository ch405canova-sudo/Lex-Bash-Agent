#!/usr/bin/env bash
#
# lex/test/test_proxy.sh — Debug-Proxy `tools/llama-proxy.sh`.
#
# Prüft: Syntax, Start/Stop, Durchreichung (inkl. >1-KB-Body mit Umlauten
# → Expect: 100-continue + Content-Length in BYTES), Protokollierung,
# keep-open (zweite Verbindung), 502-Fall und die 8080-Sperre.
#
# Genutzt werden NUR hohe eigene Ports — der echte llama-server (8080)
# wird nie berührt.
#
set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEX_DIR="$(dirname "$SCRIPT_DIR")"
PROXY="$LEX_DIR/tools/llama-proxy.sh"

FAKE_PORT=24611      # Fake-Upstream (antwortet mit Inhalt + reasoning)
PROXY_PORT=24612     # Proxy dagegen
PROXY2_PORT=24613    # Proxy gegen toten Upstream (502-Test)
DEAD_PORT=24614      # niemand lauscht hier
BIND_PORT=24615      # M7: Bind-Nachweis
HOLE_PORT=24616      # M6: akzeptiert, antwortet nie (Blackhole)
PROXY7_PORT=24617    # M6: Proxy gegen das Blackhole
M7_PORT=24618        # M7: LEX_PROXY_PORT-Override
M7B_PORT=24619       # M7: Port-belegt-Sperre (Fremd-Listener)

TMP="$(mktemp -d)"
FAKE_PID=""
HOLE_PID=""
# Prozess zuverlässig beenden: erst TERM, kurz warten, dann KILL samt Kindern.
# ncat -k -c wartet nach TERM auf seine `sleep 60`-Kinder und läuft sonst bis
# zum Kind-Ende als Waise weiter (2026-10-08 nach run_all gefunden: ncat auf
# HOLE_PORT, das cleanup-TERM hatte nicht gegriffen).
_stop_pid() {
  local pid="${1:-}"
  [[ -n "$pid" ]] || return 0
  kill "$pid" 2>/dev/null || true
  for _ in $(seq 1 10); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
  done
  pkill -KILL -P "$pid" 2>/dev/null || true
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  return 0
}

# Port-basierter Fallback (2026-10-08, reproduziert): ncat -k -c übergibt den
# Verbindungs-fd an seine KINDER (sh -c 'sleep 60') — die halten den Port,
# auch wenn der ncat-Parent längst tot und die Kinder reparented sind. Belegt
# daher ALLE Prozesse, die auf DEM test-eigenen High-Port lauschen (ss -p),
# plus ncat-pgrep als Fallback. Killt ausschließlich eigene Test-Ports.
_stop_port() {
  local port="$1" pids p rest last
  [[ "${port:-}" =~ ^[0-9]+$ ]] || return 0
  _port_pids() {
    ss -ltnp 2>/dev/null | awk -v pat=":${port}\$" '$4 ~ pat' \
      | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u | tr '\n' ' '
  }
  rest="${port%?}"
  last="${port: -1}"
  pids="$(_port_pids)$(pgrep -f "ncat.*127.0.0.1 ${rest}[${last}]" 2>/dev/null | tr '\n' ' ')"
  pids="$(printf '%s' "$pids" | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -u | tr '\n' ' ')"
  [[ -n "${pids// /}" ]] || return 0
  for p in $pids; do
    kill -TERM "$p" 2>/dev/null || true
  done
  sleep 0.3
  pids="$(_port_pids)"
  pids="$(printf '%s' "$pids" | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -u | tr '\n' ' ')"
  for p in $pids; do
    kill -KILL "$p" 2>/dev/null || true
  done
  return 0
}
cleanup() {
  LEX_PROXY_DIR="$TMP/.proxy"  "$PROXY" stop >/dev/null 2>&1
  LEX_PROXY_DIR="$TMP/.proxy2" "$PROXY" stop >/dev/null 2>&1
  LEX_PROXY_DIR="$TMP/.proxy6" "$PROXY" stop >/dev/null 2>&1
  LEX_PROXY_DIR="$TMP/.proxy7" "$PROXY" stop >/dev/null 2>&1
  LEX_PROXY_DIR="$TMP/.proxy8"  "$PROXY" stop >/dev/null 2>&1
  if [[ -n "${FR8_PID:-}" ]]; then _stop_pid "$FR8_PID"; fi
  if [[ -n "${HOLE_PID:-}" ]]; then _stop_pid "$HOLE_PID"; fi
  # auch abgespaltene Kind-Listener vom Port holen (siehe _stop_port)
  _stop_port "$HOLE_PORT"
  _stop_port "$M7B_PORT"
  # verwaiste Handler eines früheren Laufs (M6-Prüfling) — [.] verhindert,
  # dass pgrep die eigene Kommandozeile trifft
  pkill -TERM -f 'llama-proxy[.]sh __handle' 2>/dev/null || true
  if [[ -n "$FAKE_PID" ]]; then kill "$FAKE_PID" 2>/dev/null; fi
  sleep 0.2
  rm -rf "$TMP"
  return 0
}
trap cleanup EXIT

FAIL=0
pass() { printf '  [PASS] %s\n' "$1"; }
fail() { printf '  [FAIL] %s\n' "$1" >&2; FAIL=1; }

# assert/contains wie in test_features/test_http — der M7-Block (Audit
# 2026-10-08) nutzte sie, hier fehlten sie: die Aufrufe endeten mit
# „Kommando nicht gefunden“ in stderr, ließen FAIL unangetastet und der
# Läufer ging still grün durch, ohne je geprüft zu haben.
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
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf '  [PASS] %s\n' "$desc"
  else
    printf '  [FAIL] %s\n' "$desc" >&2
    printf '         erwartet (enthält): %q\n' "$needle" >&2
    printf '         ist:                %q\n' "$haystack" >&2
    FAIL=1
  fi
}

# 0. Ports frei?
busy=0
for p in "$FAKE_PORT" "$PROXY_PORT" "$PROXY2_PORT" "$DEAD_PORT" "$BIND_PORT" "$HOLE_PORT" "$PROXY7_PORT" \
  "$M7_PORT" "$M7B_PORT"; do
  if command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | grep -q ":${p}[[:space:]]"; then
    fail "Port $p ist belegt — Test braucht ihn"
    busy=1
  fi
done
if (( busy == 0 )); then pass "Ports frei"; fi

# 1. Syntax
if bash -n "$PROXY"; then pass "syntax"; else fail "syntax"; fi

# 2. Fake-Upstream starten
printf '%s\n' '{"choices":[{"index":0,"message":{"role":"assistant","content":"Taugt.","reasoning_content":"denke kurz nach.","tool_calls":[]},"finish_reason":"stop"}],"usage":{"total_tokens":11}}' \
  > "$TMP/responses.json"
FAKE_PID="$("$SCRIPT_DIR/fake_server.sh" "$FAKE_PORT" "$TMP/responses.json" 2>/dev/null)" || FAKE_PID=""
if [[ -n "$FAKE_PID" ]]; then pass "fake-upstream gestartet ($FAKE_PORT)"; else fail "fake-upstream gestartet"; fi

# 3. Proxy starten (Upstream = Fake)
out="$(LEX_PROXY_UPSTREAM="http://127.0.0.1:$FAKE_PORT" LEX_PROXY_DIR="$TMP/.proxy" \
       "$PROXY" start "$PROXY_PORT" 2>&1)"
if [[ "$out" == *"Proxy läuft"* ]]; then
  pass "proxy gestartet ($PROXY_PORT → 127.0.0.1:$FAKE_PORT)"
else
  fail "proxy gestartet: $out"
fi

# 4. Durchreichung mit >1-KB-Body (Umlauten) — 100-continue + Byte-CL
BODY="$TMP/body.json"
python3 - "$BODY" <<'PY'
import json, sys
json.dump({"model": "test-modell",
           "messages": [{"role": "user", "content": "ü" * 3000}],
           "max_tokens": 4096, "reasoning_budget_tokens": 4096,
           "tools": [{"type": "function", "function": {"name": "bash"}}]},
          open(sys.argv[1], "w"), ensure_ascii=False)
PY
blen="$(wc -c < "$BODY" | tr -d ' ')"
code="$(curl -sS --max-time 30 -X POST "http://127.0.0.1:$PROXY_PORT/v1/chat/completions" \
        -H 'Content-Type: application/json' -d @"$BODY" -o "$TMP/resp.json" -w '%{http_code}')"
if [[ "$code" == "200" ]]; then pass "durchreichung (HTTP 200, $blen Byte Body)"; else fail "durchreichung (HTTP $code)"; fi
content="$(jq -r '.choices[0].message.content // ""' "$TMP/resp.json" 2>/dev/null || printf '')"
if [[ "$content" == "Taugt." ]]; then pass "antwort des upstream kam unverändert zurück"; else fail "antwort: $content"; fi
if jq -e . >/dev/null 2>&1 "$TMP/resp.json"; then pass "response ist valides JSON"; else fail "response ist valides JSON"; fi

# 5. Protokoll geschrieben?
tdir="$TMP/.proxy"
if [[ -s "$tdir/traffic.log" ]]; then pass "traffic.log vorhanden"; else fail "traffic.log vorhanden"; fi
tlog="$(cat "$tdir/traffic.log" 2>/dev/null)"
for needle in "POST /v1/chat/completions" "HTTP/1.1 200 OK" "rb=4096" "finish=stop" "reasoning=16"; do
  if [[ "$tlog" == *"$needle"* ]]; then pass "log enthält '$needle'"; else fail "log enthält '$needle'"; fi
done

# 6. Request/Response-Dateien (roh + pretty + Upstream-Header)
infile="$(find "$tdir" -name '*-in.json' -type f | head -1)"
outfile="$(find "$tdir" -name '*-out.json' -type f | head -1)"
if [[ -n "$infile" && -f "$infile" ]]; then pass "request-Datei geschrieben"; else fail "request-Datei geschrieben"; fi
if [[ -n "$outfile" && -f "$outfile" ]]; then pass "response-Datei geschrieben"; else fail "response-Datei geschrieben"; fi
if [[ -n "$infile" && -f "${infile%.json}.pretty.json" ]]; then pass "request pretty"; else fail "request pretty"; fi
if [[ -n "$outfile" && -f "${outfile%.json}.pretty.json" ]]; then pass "response pretty"; else fail "response pretty"; fi
if [[ -n "$infile" ]] && grep -q 'Content-Type' "${infile%-in.json}-rsp-headers.txt" 2>/dev/null; then
  pass "upstream-header mitprotokolliert"
else
  fail "upstream-header mitprotokolliert"
fi
if [[ -n "$infile" ]] && jq -e '.reasoning_budget_tokens == 4096' "$infile" >/dev/null 2>&1; then
  pass "request enthält rb=4096"
else
  fail "request enthält rb=4096"
fi

# 7. keep-open: zweite Verbindung
code2="$(curl -sS --max-time 30 -X POST "http://127.0.0.1:$PROXY_PORT/v1/chat/completions" \
         -H 'Content-Type: application/json' -d '{"model":"m","messages":[{"role":"user","content":"hi"}]}' \
         -o /dev/null -w '%{http_code}')"
if [[ "$code2" == "200" ]]; then pass "zweite Verbindung (ncat -k)"; else fail "zweite Verbindung (HTTP $code2)"; fi

# 8. show zeigt Request UND Response
out="$(LEX_PROXY_DIR="$tdir" "$PROXY" show 1 2>/dev/null)"
if [[ "$out" == *"########## REQUEST"* && "$out" == *"########## RESPONSE"* && "$out" == *"reasoning"* ]]; then
  pass "show (Request + Response)"
else
  fail "show (Request + Response)"
fi

# 9. 502: Proxy gegen toten Upstream
out="$(LEX_PROXY_UPSTREAM="http://127.0.0.1:$DEAD_PORT" LEX_PROXY_DIR="$TMP/.proxy2" \
       "$PROXY" start "$PROXY2_PORT" 2>&1)"
code5="$(curl -sS --max-time 15 -X POST "http://127.0.0.1:$PROXY2_PORT/v1/chat/completions" \
         -H 'Content-Type: application/json' -d '{"model":"m"}' -o "$TMP/err.json" -w '%{http_code}')"
if [[ "$code5" == "502" ]]; then pass "502 bei totem upstream"; else fail "502 bei totem upstream (HTTP $code5)"; fi
if grep -q 'PROXY-FEHLER' "$TMP/.proxy2/traffic.log" 2>/dev/null; then
  pass "502 im Protokoll"
else
  fail "502 im Protokoll"
fi

# 10. 8080-Sperre
out="$(LEX_PROXY_DIR="$TMP/.proxy3" "$PROXY" start 8080 2>&1)"
if [[ "$out" == *"echte llama-server"* ]]; then pass "8080 wird abgelehnt"; else fail "8080 wird abgelehnt: $out"; fi

# 11. stop + status
LEX_PROXY_DIR="$TMP/.proxy" "$PROXY" stop >/dev/null 2>&1
st="$(LEX_PROXY_DIR="$TMP/.proxy" "$PROXY" status 2>/dev/null)"
if [[ "$st" == *"Proxy:  gestoppt"* ]]; then
  pass "stop"
else
  fail "stop ($st)"
fi
# status nennt die gespeicherte Upstream-URL, nicht den Default
if [[ "$st" == *"Upstream: http://127.0.0.1:$FAKE_PORT"* ]]; then
  pass "status zeigt gespeicherten upstream"
else
  fail "status zeigt gespeicherten upstream ($st)"
fi

# 12. stop eines LAUFENDen Proxys (die normale Strecke darf durch die neue
#     PID-Prüfung nicht kaputtgehen — Audit H5 2026-10-08)
out="$(LEX_PROXY_DIR="$TMP/.proxy2" "$PROXY" stop 2>&1)"; rc=$?
if (( rc == 0 )) && [[ "$out" == *"Proxy gestoppt"* ]]; then
  pass "stop (laufender Proxy: rc0 + Meldung)"
else
  fail "stop (laufender Proxy: rc=$rc out=$out)"
fi

# 13. verwaistes PID-File (PID existiert nicht mehr) → räumen, rc 0
mkdir -p "$TMP/.proxy4"
sleep 0.05 & dead=$!; wait "$dead" 2>/dev/null
printf '%s\n' "$dead" > "$TMP/.proxy4/proxy.pid"
out="$(LEX_PROXY_DIR="$TMP/.proxy4" "$PROXY" stop 2>&1)"; rc=$?
if (( rc == 0 )) && [[ "$out" == *"verwaist"* && ! -f "$TMP/.proxy4/proxy.pid" ]]; then
  pass "stop (verwaistes PID-File geräumt)"
else
  fail "stop (verwaistes PID-File: rc=$rc out=$out)"
fi

# 14. PID-File zeigt auf einen FREMDEN Prozess (wiederverwendete PID) →
#     nichts killen, rc 1, PID-File trotzdem räumen
sleep 60 & fr=$!
mkdir -p "$TMP/.proxy5"
printf '%s\n' "$fr" > "$TMP/.proxy5/proxy.pid"
out="$(LEX_PROXY_DIR="$TMP/.proxy5" "$PROXY" stop 2>&1)"; rc=$?
alive=0; kill -0 "$fr" 2>/dev/null && alive=1
if (( rc == 1 && alive == 1 )) && [[ "$out" == *"gehört nicht zum Proxy"* ]]; then
  pass "stop (Fremd-PID nicht gekillt)"
else
  fail "stop (Fremd-PID: rc=$rc alive=$alive out=$out)"
fi
kill "$fr" 2>/dev/null; wait "$fr" 2>/dev/null

# 15. Audit M7: Port-Validierung (vorher ging "abc"/"08080" ungeprüft in
#     ss/nc-Argumente, die 8080-Sperre war ein String-Vergleich)
out="$(LEX_PROXY_DIR="$TMP/.proxyv" "$PROXY" start abc 2>&1)"; rc=$?
if (( rc != 0 )) && [[ "$out" == *"1–5 Ziffern"* ]]; then
  pass "M7 (Port nicht numerisch abgelehnt)"
else
  fail "M7 (Port nicht numerisch: rc=$rc out=$out)"
fi
out="$(LEX_PROXY_DIR="$TMP/.proxyv" "$PROXY" start 70000 2>&1)"; rc=$?
if (( rc != 0 )) && [[ "$out" == *"1 und 65535"* ]]; then
  pass "M7 (> 65535 abgelehnt)"
else
  fail "M7 (> 65535: rc=$rc out=$out)"
fi
out="$(LEX_PROXY_DIR="$TMP/.proxyv" "$PROXY" start 08080 2>&1)"; rc=$?
if (( rc != 0 )) && [[ "$out" == *"echte llama-server"* ]]; then
  pass "M7 (08080 normalisiert → 8080-Sperre greift)"
else
  fail "M7 (08080: rc=$rc out=$out)"
fi
if ! grep -q 'nc -z 127.0.0.1' "$PROXY"; then
  pass "M7 (kein nc -z-Porttest mehr)"
else
  fail "M7 (nc -z steckt noch in der Datei)"
fi

# 16. Audit M7: Bind-Nachweis — Helfer frisch aus der Datei (ohne den
#     Dispatcher der Proxy-Skripte mitzulösen), gegen laufenden Proxy geprüft
eval "$(sed -n '/^_port_owned_by()/,/^}/p' "$PROXY")"
out="$(LEX_PROXY_UPSTREAM="http://127.0.0.1:$FAKE_PORT" LEX_PROXY_DIR="$TMP/.proxy6" \
       "$PROXY" start "$BIND_PORT" 2>&1)"
if [[ "$out" == *"Proxy läuft"* ]]; then
  pass "M7 (Proxy für Bind-Test gestartet)"
else
  fail "M7 (Proxy für Bind-Test: $out)"
fi
bind_pid="$(cat "$TMP/.proxy6/proxy.pid" 2>/dev/null || printf '')"
if _port_owned_by "$BIND_PORT" "$bind_pid"; then
  pass "M7 (_port_owned_by: Port gehört unserer PID)"
else
  fail "M7 (_port_owned_by lehnt die eigene PID ab)"
fi
sleep 60 & fr6=$!
if ! _port_owned_by "$BIND_PORT" "$fr6"; then
  pass "M7 (_port_owned_by lehnt Fremd-PID ab)"
else
  fail "M7 (_port_owned_by glaubt, eine Fremd-PID hielte den Port)"
fi
kill "$fr6" 2>/dev/null; wait "$fr6" 2>/dev/null
LEX_PROXY_DIR="$TMP/.proxy6" "$PROXY" stop >/dev/null 2>&1

# 17. Audit M6: _kill_tree beendet den kompletten Unterbaum
eval "$(sed -n '/^_kill_tree()/,/^}/p' "$PROXY")"
bash -c 'sleep 300 & exec sleep 300' & root=$!
sleep 0.3
kids="$(pgrep -P "$root" 2>/dev/null | tr '\n' ' ')"
_kill_tree "$root"
wait "$root" 2>/dev/null
sleep 0.3
kt_root=0; kt_kids=0
kill -0 "$root" 2>/dev/null && kt_root=1
for k in $kids; do kill -0 "$k" 2>/dev/null && kt_kids=1; done
if (( kt_root == 0 && kt_kids == 0 )); then
  pass "M6 (_kill_tree beendet Wurzel UND Kinder)"
else
  fail "M6 (_kill_tree: Wurzel=$kt_root Kinder=$kt_kids)"
fi

# 18. Audit M6: stop beendet die sh-exec-Handler samt curl — vorher wurden
#     sie als Waisen bis max-time 900 weiterlaufen gelassen
ncat --listen 127.0.0.1 "$HOLE_PORT" -k -c 'sleep 60' </dev/null >/dev/null 2>&1 &
HOLE_PID=$!
sleep 0.3
out="$(LEX_PROXY_UPSTREAM="http://127.0.0.1:$HOLE_PORT" LEX_PROXY_DIR="$TMP/.proxy7" \
       "$PROXY" start "$PROXY7_PORT" 2>&1)"
if [[ "$out" == *"Proxy läuft"* ]]; then pass "M6 (Blackhole-Proxy gestartet)"; else fail "M6 (Blackhole-Proxy: $out)"; fi
curl -sS --max-time 2 -X POST "http://127.0.0.1:$PROXY7_PORT/v1/chat/completions" \
  -H 'Content-Type: application/json' -d '{"model":"m"}' -o /dev/null 2>/dev/null
h1=""
for _i in $(seq 1 25); do
  h1="$(pgrep -f 'llama-proxy[.]sh __handle' 2>/dev/null | head -n 1)"
  [[ -n "$h1" ]] && break
  sleep 0.2
done
if [[ -z "$h1" ]]; then
  fail "M6 (kein Handler unter Blackhole-Upstream — Testaufbau)"
else
  h1_curl="$(pgrep -P "$h1" 2>/dev/null | tr '\n' ' ')"
  if kill -0 "$h1" 2>/dev/null; then
    pass "M6 (Handler läuft, während das Blackhole nie antwortet)"
  else
    fail "M6 (Handler starb vor dem stop)"
  fi
  out="$(LEX_PROXY_DIR="$TMP/.proxy7" "$PROXY" stop 2>&1)"; rc=$?
  sleep 0.6
  h_alive=0; kill -0 "$h1" 2>/dev/null && h_alive=1
  c_alive=0
  for k in $h1_curl; do kill -0 "$k" 2>/dev/null && c_alive=1; done
  if (( rc == 0 && h_alive == 0 && c_alive == 0 )) && [[ "$out" == *"Proxy gestoppt"* ]]; then
    pass "M6 (stop killt Handler und curl: Waise weg)"
  else
    fail "M6 (stop: rc=$rc Handler-alive=$h_alive curl-alive=$c_alive out=$out)"
  fi
fi
if [[ -n "${HOLE_PID:-}" ]]; then _stop_pid "$HOLE_PID"; HOLE_PID=""; fi
_stop_port "$HOLE_PORT"
# Gewünschtes Verhalten als Prüfung: nach Stopp lauscht NIEMAND mehr auf
# HOLE_PORT (der abgespaltene Kind-Listener von ncat -k wäre sonst noch da).
hole_waise=1
for _ in $(seq 1 10); do
  if ! ss -ltn 2>/dev/null | grep -q ":${HOLE_PORT}[[:space:]]"; then hole_waise=0; break; fi
  sleep 0.2
done
if (( hole_waise == 0 )); then
  pass "M6 (kein Listener-Waisen auf HOLE_PORT)"
else
  fail "M6 (Listener-Waisen auf HOLE_PORT nach dem Stopp: \
$(ss -ltnp 2>/dev/null | grep ":${HOLE_PORT}[[:space:]]" | head -3 | tr '\\n' ';')"
fi

# M7 (Audit 2026-10-08): LEX_PROXY_PORT-Override + Port-belegt-Schutz.
# LEX_PROXY_DIR explizit ($TMP/.proxy8): ohne es liegt DIR bei $PWD/.proxy,
# der Block hätte den Block also ins Repo geschrieben. Port NUR aus der Env —
# start ohne Port-Argument, sonst prüft das Argument statt der Env-Variable.
P8="$TMP/.proxy8"
out="$(LEX_PROXY_DIR="$P8" LEX_PROXY_PORT="$M7_PORT" "$PROXY" start 2>&1)"; rc=$?
sleep 0.2
contains "M7 (LEX_PROXY_PORT)" "$M7_PORT" "$out"
# (Der alte Assert verlangte „0“ bei rc==0 — invertiert, und ohne Helfer nie
# aufgefallen.)
assert "M7 (LEX_PROXY_PORT rc0)" "1" "$(( rc == 0 ? 1 : 0 ))"
LEX_PROXY_DIR="$P8" "$PROXY" stop >/dev/null 2>&1
sleep 0.2
# Port belegt: FREMDER Listener. Ein eigener Proxy würde vor dem ss-Check
# schon in _running abfangen (andere Meldung) — genau diesen ss-Weg prüft M7.
ncat --listen 127.0.0.1 "$M7B_PORT" -k </dev/null >/dev/null 2>&1 &
FR8_PID=$!
for _ in $(seq 1 30); do
  ss -ltn 2>/dev/null | grep -q ":${M7B_PORT}[[:space:]]" && break
  sleep 0.1
done
out2="$(LEX_PROXY_DIR="$P8" "$PROXY" start "$M7B_PORT" 2>&1)"; rc2=$?
contains "M7 (Port belegt Meldung)" "Port $M7B_PORT ist belegt" "$out2"
assert "M7 (Port belegt rc1)" "1" "$(( rc2 == 1 ? 1 : 0 ))"
_stop_pid "$FR8_PID"
FR8_PID=""
LEX_PROXY_DIR="$P8" "$PROXY" stop >/dev/null 2>&1 || true

if (( FAIL > 0 )); then
  echo "FEHLSCHLAG: $FAIL Test(s) in test_proxy.sh" >&2
  exit 1
fi
echo "test_proxy.sh grün. ✓" 
exit 0
