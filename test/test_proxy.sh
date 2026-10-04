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

TMP="$(mktemp -d)"
FAKE_PID=""
cleanup() {
  LEX_PROXY_DIR="$TMP/.proxy"  "$PROXY" stop >/dev/null 2>&1
  LEX_PROXY_DIR="$TMP/.proxy2" "$PROXY" stop >/dev/null 2>&1
  if [[ -n "$FAKE_PID" ]]; then kill "$FAKE_PID" 2>/dev/null; fi
  sleep 0.2
  rm -rf "$TMP"
  return 0
}
trap cleanup EXIT

FAIL=0
pass() { printf '  [PASS] %s\n' "$1"; }
fail() { printf '  [FAIL] %s\n' "$1" >&2; FAIL=1; }

# 0. Ports free?
busy=0
for p in "$FAKE_PORT" "$PROXY_PORT" "$PROXY2_PORT" "$DEAD_PORT"; do
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

if (( FAIL > 0 )); then
  echo "FAILED: $FAIL test(s) in test_proxy.sh" >&2
  exit 1
fi
echo "test_proxy.sh green. ✓"
exit 0
