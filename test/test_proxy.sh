#!/usr/bin/env bash
#
# lex/test/test_proxy.sh — debug proxy `tools/llama-proxy.sh`.
#
# Checks: syntax, start/stop, pass-through (incl. a >1 KB body with umlauts
# → Expect: 100-continue + Content-Length in BYTES), logging,
# keep-open (second connection), the 502 case and the 8080 block.
#
# Only high ports of our own are used — the real llama-server (8080)
# is never touched.
#
set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEX_DIR="$(dirname "$SCRIPT_DIR")"
PROXY="$LEX_DIR/tools/llama-proxy.sh"

FAKE_PORT=24611      # fake upstream (answers with content + reasoning)
PROXY_PORT=24612     # proxy against it
PROXY2_PORT=24613    # proxy against a dead upstream (502 test)
DEAD_PORT=24614      # nobody is listening here
BIND_PORT=24615      # M7: bind proof
HOLE_PORT=24616      # M6: accepts, never answers (blackhole)
PROXY7_PORT=24617    # M6: proxy against the blackhole
M7_PORT=24618        # M7: LEX_PROXY_PORT override
M7B_PORT=24619       # M7: port-taken lock (foreign listener)

TMP="$(mktemp -d)"
FAKE_PID=""
HOLE_PID=""
# End a process reliably: first TERM, short wait, then KILL including children.
# ncat -k -c waits after TERM for its `sleep 60` children and otherwise keeps
# running as an orphan until the child ends (found 2026-10-08 after run_all:
# ncat on HOLE_PORT, the cleanup-TERM did not grip).
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

# Port-based fallback (2026-10-08, reproduced): ncat -k -c hands the
# connection fd to its CHILDREN (sh -c 'sleep 60') — they hold the port even
# if the ncat parent is long dead and the children are reparented. Therefore
# kill ALL processes listening on THE test's own high port (ss -p), plus
# ncat pgrep as a fallback. Kills exclusively own test ports.
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
  # also fetch detached child listeners from the port (see _stop_port)
  _stop_port "$HOLE_PORT"
  _stop_port "$M7B_PORT"
  # orphaned handlers of an earlier run (M6 subject) — [.] prevents pgrep
  # from hitting its own command line
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

# assert/contains as in test_features/test_http — the M7 block (audit
# 2026-10-08) used them, here they were missing: the calls ended with
# "command not found" in stderr, left FAIL untouched and the runner went
# quietly green without ever having checked.
assert() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    printf '  [PASS] %s\n' "$desc"
  else
    printf '  [FAIL] %s\n' "$desc" >&2
    printf '         expected: %q\n' "$expected" >&2
    printf '         actual:   %q\n' "$actual" >&2
    FAIL=1
  fi
}

contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf '  [PASS] %s\n' "$desc"
  else
    printf '  [FAIL] %s\n' "$desc" >&2
    printf '         expected (contains): %q\n' "$needle" >&2
    printf '         actual:              %q\n' "$haystack" >&2
    FAIL=1
  fi
}

# 0. Ports free?
busy=0
for p in "$FAKE_PORT" "$PROXY_PORT" "$PROXY2_PORT" "$DEAD_PORT" "$BIND_PORT" "$HOLE_PORT" "$PROXY7_PORT" \
  "$M7_PORT" "$M7B_PORT"; do
  if command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | grep -q ":${p}[[:space:]]"; then
    fail "port $p is in use — the test needs it"
    busy=1
  fi
done
if (( busy == 0 )); then pass "ports free"; fi

# 1. Syntax
if bash -n "$PROXY"; then pass "syntax"; else fail "syntax"; fi

# 2. start the fake upstream
printf '%s\n' '{"choices":[{"index":0,"message":{"role":"assistant","content":"Taugt.","reasoning_content":"thinking briefly","tool_calls":[]},"finish_reason":"stop"}],"usage":{"total_tokens":11}}' \
  > "$TMP/responses.json"
FAKE_PID="$("$SCRIPT_DIR/fake_server.sh" "$FAKE_PORT" "$TMP/responses.json" 2>/dev/null)" || FAKE_PID=""
if [[ -n "$FAKE_PID" ]]; then pass "fake upstream started ($FAKE_PORT)"; else fail "fake upstream started"; fi

# 3. start the proxy (upstream = fake)
out="$(LEX_PROXY_UPSTREAM="http://127.0.0.1:$FAKE_PORT" LEX_PROXY_DIR="$TMP/.proxy" \
       "$PROXY" start "$PROXY_PORT" 2>&1)"
if [[ "$out" == *"Proxy running"* ]]; then
  pass "proxy started ($PROXY_PORT → 127.0.0.1:$FAKE_PORT)"
else
  fail "proxy started: $out"
fi

# 4. pass-through with a >1 KB body (umlauts) — 100-continue + byte CL
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
if [[ "$code" == "200" ]]; then pass "pass-through (HTTP 200, $blen byte body)"; else fail "pass-through (HTTP $code)"; fi
content="$(jq -r '.choices[0].message.content // ""' "$TMP/resp.json" 2>/dev/null || printf '')"
if [[ "$content" == "Taugt." ]]; then pass "upstream answer came back unchanged"; else fail "answer: $content"; fi
if jq -e . >/dev/null 2>&1 "$TMP/resp.json"; then pass "response is valid JSON"; else fail "response is valid JSON"; fi

# 5. log written?
tdir="$TMP/.proxy"
if [[ -s "$tdir/traffic.log" ]]; then pass "traffic.log present"; else fail "traffic.log present"; fi
tlog="$(cat "$tdir/traffic.log" 2>/dev/null)"
for needle in "POST /v1/chat/completions" "HTTP/1.1 200 OK" "rb=4096" "finish=stop" "reasoning=16"; do
  if [[ "$tlog" == *"$needle"* ]]; then pass "log contains '$needle'"; else fail "log contains '$needle'"; fi
done

# 6. request/response files (raw + pretty + upstream headers)
infile="$(find "$tdir" -name '*-in.json' -type f | head -1)"
outfile="$(find "$tdir" -name '*-out.json' -type f | head -1)"
if [[ -n "$infile" && -f "$infile" ]]; then pass "request file written"; else fail "request file written"; fi
if [[ -n "$outfile" && -f "$outfile" ]]; then pass "response file written"; else fail "response file written"; fi
if [[ -n "$infile" && -f "${infile%.json}.pretty.json" ]]; then pass "request pretty"; else fail "request pretty"; fi
if [[ -n "$outfile" && -f "${outfile%.json}.pretty.json" ]]; then pass "response pretty"; else fail "response pretty"; fi
if [[ -n "$infile" ]] && grep -q 'Content-Type' "${infile%-in.json}-rsp-headers.txt" 2>/dev/null; then
  pass "upstream headers logged"
else
  fail "upstream headers logged"
fi
if [[ -n "$infile" ]] && jq -e '.reasoning_budget_tokens == 4096' "$infile" >/dev/null 2>&1; then
  pass "request contains rb=4096"
else
  fail "request contains rb=4096"
fi

# 7. keep-open: second connection
code2="$(curl -sS --max-time 30 -X POST "http://127.0.0.1:$PROXY_PORT/v1/chat/completions" \
         -H 'Content-Type: application/json' -d '{"model":"m","messages":[{"role":"user","content":"hi"}]}' \
         -o /dev/null -w '%{http_code}')"
if [[ "$code2" == "200" ]]; then pass "second connection (ncat -k)"; else fail "second connection (HTTP $code2)"; fi

# 8. show displays request AND response
out="$(LEX_PROXY_DIR="$tdir" "$PROXY" show 1 2>/dev/null)"
if [[ "$out" == *"########## REQUEST"* && "$out" == *"########## RESPONSE"* && "$out" == *"reasoning"* ]]; then
  pass "show (Request + Response)"
else
  fail "show (Request + Response)"
fi

# 9. 502: proxy against a dead upstream
out="$(LEX_PROXY_UPSTREAM="http://127.0.0.1:$DEAD_PORT" LEX_PROXY_DIR="$TMP/.proxy2" \
       "$PROXY" start "$PROXY2_PORT" 2>&1)"
code5="$(curl -sS --max-time 15 -X POST "http://127.0.0.1:$PROXY2_PORT/v1/chat/completions" \
         -H 'Content-Type: application/json' -d '{"model":"m"}' -o "$TMP/err.json" -w '%{http_code}')"
if [[ "$code5" == "502" ]]; then pass "502 for a dead upstream"; else fail "502 for a dead upstream (HTTP $code5)"; fi
if grep -q 'PROXY-ERROR' "$TMP/.proxy2/traffic.log" 2>/dev/null; then
  pass "502 in the log"
else
  fail "502 in the log"
fi

# 10. the 8080 block
out="$(LEX_PROXY_DIR="$TMP/.proxy3" "$PROXY" start 8080 2>&1)"
if [[ "$out" == *"real llama-server"* ]]; then pass "8080 is rejected"; else fail "8080 is rejected: $out"; fi

# 11. stop + status
LEX_PROXY_DIR="$TMP/.proxy" "$PROXY" stop >/dev/null 2>&1
st="$(LEX_PROXY_DIR="$TMP/.proxy" "$PROXY" status 2>/dev/null)"
if [[ "$st" == *"Proxy:  stopped"* ]]; then
  pass "stop"
else
  fail "stop ($st)"
fi
# status names the stored upstream URL, not the default
if [[ "$st" == *"Upstream: http://127.0.0.1:$FAKE_PORT"* ]]; then
  pass "status shows the stored upstream"
else
  fail "status shows the stored upstream ($st)"
fi

# 12. stop of a RUNNING proxy (the normal path must not break through the new
#     PID check — audit H5 2026-10-08)
out="$(LEX_PROXY_DIR="$TMP/.proxy2" "$PROXY" stop 2>&1)"; rc=$?
if (( rc == 0 )) && [[ "$out" == *"Proxy stopped"* ]]; then
  pass "stop (running proxy: rc0 + message)"
else
  fail "stop (running proxy: rc=$rc out=$out)"
fi

# 13. orphaned PID file (PID no longer exists) → clean up, rc 0
mkdir -p "$TMP/.proxy4"
sleep 0.05 & dead=$!; wait "$dead" 2>/dev/null
printf '%s\n' "$dead" > "$TMP/.proxy4/proxy.pid"
out="$(LEX_PROXY_DIR="$TMP/.proxy4" "$PROXY" stop 2>&1)"; rc=$?
if (( rc == 0 )) && [[ "$out" == *"orphaned"* && ! -f "$TMP/.proxy4/proxy.pid" ]]; then
  pass "stop (orphaned PID file cleaned)"
else
  fail "stop (orphaned PID file: rc=$rc out=$out)"
fi

# 14. PID file points to a FOREIGN process (reused PID) → kill nothing,
#     rc 1, still clean up the PID file
sleep 60 & fr=$!
mkdir -p "$TMP/.proxy5"
printf '%s\n' "$fr" > "$TMP/.proxy5/proxy.pid"
out="$(LEX_PROXY_DIR="$TMP/.proxy5" "$PROXY" stop 2>&1)"; rc=$?
alive=0; kill -0 "$fr" 2>/dev/null && alive=1
if (( rc == 1 && alive == 1 )) && [[ "$out" == *"does not belong to the proxy"* ]]; then
  pass "stop (foreign PID not killed)"
else
  fail "stop (foreign PID: rc=$rc alive=$alive out=$out)"
fi
kill "$fr" 2>/dev/null; wait "$fr" 2>/dev/null

# 15. audit M7: port validation (before "abc"/"08080" went unchecked into
#     ss/nc arguments, the 8080 lock was a string comparison)
out="$(LEX_PROXY_DIR="$TMP/.proxyv" "$PROXY" start abc 2>&1)"; rc=$?
if (( rc != 0 )) && [[ "$out" == *"1-5 digits"* ]]; then
  pass "M7 (non-numeric port rejected)"
else
  fail "M7 (non-numeric port: rc=$rc out=$out)"
fi
out="$(LEX_PROXY_DIR="$TMP/.proxyv" "$PROXY" start 70000 2>&1)"; rc=$?
if (( rc != 0 )) && [[ "$out" == *"between 1 and 65535"* ]]; then
  pass "M7 (> 65535 rejected)"
else
  fail "M7 (> 65535: rc=$rc out=$out)"
fi
out="$(LEX_PROXY_DIR="$TMP/.proxyv" "$PROXY" start 08080 2>&1)"; rc=$?
if (( rc != 0 )) && [[ "$out" == *"real llama-server"* ]]; then
  pass "M7 (08080 normalized -> 8080 lock grips)"
else
  fail "M7 (08080: rc=$rc out=$out)"
fi
if ! grep -q 'nc -z 127.0.0.1' "$PROXY"; then
  pass "M7 (no nc -z port test any more)"
else
  fail "M7 (nc -z still in the file)"
fi

# 16. audit M7: bind proof — helper freshly extracted from the file (without
#     releasing the dispatcher of the proxy scripts), checked against a
#     running proxy
eval "$(sed -n '/^_port_owned_by()/,/^}/p' "$PROXY")"
out="$(LEX_PROXY_UPSTREAM="http://127.0.0.1:$FAKE_PORT" LEX_PROXY_DIR="$TMP/.proxy6" \
       "$PROXY" start "$BIND_PORT" 2>&1)"
if [[ "$out" == *"Proxy running"* ]]; then
  pass "M7 (proxy started for bind test)"
else
  fail "M7 (proxy for bind test: $out)"
fi
bind_pid="$(cat "$TMP/.proxy6/proxy.pid" 2>/dev/null || printf '')"
if _port_owned_by "$BIND_PORT" "$bind_pid"; then
  pass "M7 (_port_owned_by: port belongs to our PID)"
else
  fail "M7 (_port_owned_by rejects our own PID)"
fi
sleep 60 & fr6=$!
if ! _port_owned_by "$BIND_PORT" "$fr6"; then
  pass "M7 (_port_owned_by rejects a foreign PID)"
else
  fail "M7 (_port_owned_by believes a foreign PID holds the port)"
fi
kill "$fr6" 2>/dev/null; wait "$fr6" 2>/dev/null
LEX_PROXY_DIR="$TMP/.proxy6" "$PROXY" stop >/dev/null 2>&1

# 17. audit M6: _kill_tree ends the complete subtree
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
  pass "M6 (_kill_tree ends root AND children)"
else
  fail "M6 (_kill_tree: root=$kt_root children=$kt_kids)"
fi

# 18. audit M6: stop ends the sh-exec handlers including curl — before they
#     were left running as orphans until max-time 900
ncat --listen 127.0.0.1 "$HOLE_PORT" -k -c 'sleep 60' </dev/null >/dev/null 2>&1 &
HOLE_PID=$!
sleep 0.3
out="$(LEX_PROXY_UPSTREAM="http://127.0.0.1:$HOLE_PORT" LEX_PROXY_DIR="$TMP/.proxy7" \
       "$PROXY" start "$PROXY7_PORT" 2>&1)"
if [[ "$out" == *"Proxy running"* ]]; then pass "M6 (blackhole proxy started)"; else fail "M6 (blackhole proxy: $out)"; fi
curl -sS --max-time 2 -X POST "http://127.0.0.1:$PROXY7_PORT/v1/chat/completions" \
  -H 'Content-Type: application/json' -d '{"model":"m"}' -o /dev/null 2>/dev/null
h1=""
for _i in $(seq 1 25); do
  h1="$(pgrep -f 'llama-proxy[.]sh __handle' 2>/dev/null | head -n 1)"
  [[ -n "$h1" ]] && break
  sleep 0.2
done
if [[ -z "$h1" ]]; then
  fail "M6 (no handler under blackhole upstream — test setup)"
else
  h1_curl="$(pgrep -P "$h1" 2>/dev/null | tr '\n' ' ')"
  if kill -0 "$h1" 2>/dev/null; then
    pass "M6 (handler runs while the blackhole never answers)"
  else
    fail "M6 (handler died before the stop)"
  fi
  out="$(LEX_PROXY_DIR="$TMP/.proxy7" "$PROXY" stop 2>&1)"; rc=$?
  sleep 0.6
  h_alive=0; kill -0 "$h1" 2>/dev/null && h_alive=1
  c_alive=0
  for k in $h1_curl; do kill -0 "$k" 2>/dev/null && c_alive=1; done
  if (( rc == 0 && h_alive == 0 && c_alive == 0 )) && [[ "$out" == *"Proxy stopped"* ]]; then
    pass "M6 (stop kills handler and curl: orphan gone)"
  else
    fail "M6 (stop: rc=$rc handler-alive=$h_alive curl-alive=$c_alive out=$out)"
  fi
fi
if [[ -n "${HOLE_PID:-}" ]]; then _stop_pid "$HOLE_PID"; HOLE_PID=""; fi
_stop_port "$HOLE_PORT"
# Desired behaviour as a check: after stop NOBODY listens on HOLE_PORT any
# more (the detached child listener of ncat -k would still be there).
hole_waise=1
for _ in $(seq 1 10); do
  if ! ss -ltn 2>/dev/null | grep -q ":${HOLE_PORT}[[:space:]]"; then hole_waise=0; break; fi
  sleep 0.2
done
if (( hole_waise == 0 )); then
  pass "M6 (no listener orphan on HOLE_PORT)"
else
  fail "M6 (listener orphan on HOLE_PORT after the stop: \
$(ss -ltnp 2>/dev/null | grep ":${HOLE_PORT}[[:space:]]" | head -3 | tr '\n' ';')"
fi

# M7 (audit 2026-10-08): LEX_PROXY_PORT override + port-taken protection.
# LEX_PROXY_DIR explicitly ($TMP/.proxy8): without it DIR sits at $PWD/.proxy,
# the block would have written the lock into the repo. Port ONLY from the env —
# start without a port argument, otherwise the argument is checked instead of
# the env variable.
P8="$TMP/.proxy8"
out="$(LEX_PROXY_DIR="$P8" LEX_PROXY_PORT="$M7_PORT" "$PROXY" start 2>&1)"; rc=$?
sleep 0.2
contains "M7 (LEX_PROXY_PORT)" "$M7_PORT" "$out"
# (The old assert demanded "0" at rc==0 — inverted, and never noticed
# without the helper.)
assert "M7 (LEX_PROXY_PORT rc0)" "1" "$(( rc == 0 ? 1 : 0 ))"
LEX_PROXY_DIR="$P8" "$PROXY" stop >/dev/null 2>&1
sleep 0.2
# Port taken: FOREIGN listener. An own proxy would be intercepted before the
# ss check already in _running (different message) — exactly this ss path is
# what M7 checks.
ncat --listen 127.0.0.1 "$M7B_PORT" -k </dev/null >/dev/null 2>&1 &
FR8_PID=$!
for _ in $(seq 1 30); do
  ss -ltn 2>/dev/null | grep -q ":${M7B_PORT}[[:space:]]" && break
  sleep 0.1
done
out2="$(LEX_PROXY_DIR="$P8" "$PROXY" start "$M7B_PORT" 2>&1)"; rc2=$?
contains "M7 (port taken message)" "port $M7B_PORT is in use" "$out2"
assert "M7 (port taken rc1)" "1" "$(( rc2 == 1 ? 1 : 0 ))"
_stop_pid "$FR8_PID"
FR8_PID=""
LEX_PROXY_DIR="$P8" "$PROXY" stop >/dev/null 2>&1 || true

if (( FAIL > 0 )); then
  echo "FAILED: $FAIL test(s) in test_proxy.sh" >&2
  exit 1
fi
echo "test_proxy.sh green. ✓"
exit 0
