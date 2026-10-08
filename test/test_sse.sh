#!/usr/bin/env bash
#
# lex/test/test_sse.sh — streaming path in call_api() via fake SSE server.
#
# Regressions that the streaming rework (2026-09-30) brought, which this
# test pins down:
#   1. curl-rc and HTTP code are REALLY measured (server gone / HTTP error
#      → real error message, not "answer was empty" as a nudge).
#   2. tool_calls are merged across several deltas (before only the last
#      delta survived → name None, arguments a fragment like "}").
#   3. data: prefix also works without a space.
#   4. an aborted stream (no [DONE]) is explicitly warned about.
#
# HIGH PORTS only — the real llama-server (8080) is never touched.
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
    printf '         expected: %q\n' "$expected" >&2
    printf '         actual:   %q\n' "$actual" >&2
    FAIL=1
  fi
}
contains() {
  local desc="$1" needle="$2" hay="$3"
  if [[ "$hay" == *"$needle"* ]]; then
    printf '  [PASS] %s\n' "$desc"
  else
    printf '  [FAIL] %s (search: %q)\n' "$desc" "$needle" >&2
    printf '         text: %q\n' "$hay" >&2
    FAIL=1
  fi
}
not_contains() {
  local desc="$1" needle="$2" hay="$3"
  if [[ "$hay" != *"$needle"* ]]; then
    printf '  [PASS] %s\n' "$desc"
  else
    printf '  [FAIL] %s (must not contain: %q)\n' "$desc" "$needle" >&2
    printf '         text: %q\n' "$hay" >&2
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

start_fake() {   # $1 = script or SSE file
  kill_fake
  FAKE_PORT=$((20000 + RANDOM % 8000))
  FAKE_PID="$(bash "$SCRIPT_DIR/fake_server.sh" "$FAKE_PORT" "$1" 2>/dev/null)"
  if [[ -z "$FAKE_PID" ]]; then
    echo "FAILED: fake server does not start (port $FAKE_PORT)" >&2
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
free_port() {   # port where nothing is listening at all
  local p
  for _ in $(seq 1 20); do
    p=$((20000 + RANDOM % 8000))
    nc -z 127.0.0.1 "$p" 2>/dev/null || { printf '%s' "$p"; return 0; }
  done
  echo "FAILED: no free port found" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# Source lex like test_http.sh: mock off, LEX_HOME isolated.
# (While sourcing, main runs with an empty command → load_config.)
# ---------------------------------------------------------------------------
export LEX_HOME="$TMP"
export LEX_MODEL="$TMP/model.gguf"
unset LEX_MOCK
unset LEX_MOCK_FILE
source "$LEX_DIR/lex" < /dev/null > /dev/null 2>&1 || {
  echo "FAILED: $LEX_DIR/lex not loadable (syntax/bash error)" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# 1. content across several deltas
# ---------------------------------------------------------------------------
printf '%s\n' \
  'data: {"choices":[{"index":0,"delta":{"content":"Hello "}}]}' \
  '' \
  'data: {"choices":[{"index":0,"delta":{"content":"over SSE."}}]}' \
  '' \
  'data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}' \
  '' \
  'data: [DONE]' \
  '' > "$TMP/inhalt.sse"
start_fake "$TMP/inhalt.sse"
out="$(run_turn "Test" 2>/dev/null)"
assert "sse (content across deltas)" "Hello over SSE." "$out"

# ---------------------------------------------------------------------------
# 2. tool_calls across several deltas (name in the first, arguments spread)
# ---------------------------------------------------------------------------
printf 'File content\n' > "$TMP/tool.txt"
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
assert "sse (tool_calls: exactly one entry)" "1" \
  "$(jq '.choices[0].message.tool_calls | length' <<< "$resp" 2>/dev/null)"
assert "sse (tool_calls: name from the first delta)" "read_file" \
  "$(jq -r '.choices[0].message.tool_calls[0].function.name' <<< "$resp" 2>/dev/null)"
assert "sse (tool_calls: arguments assembled)" "{\"path\":\"$TMP/tool.txt\"}" \
  "$(jq -r '.choices[0].message.tool_calls[0].function.arguments' <<< "$resp" 2>/dev/null)"
assert "sse (tool_calls: id from the first delta)" "call_1" \
  "$(jq -r '.choices[0].message.tool_calls[0].id' <<< "$resp" 2>/dev/null)"

# ---------------------------------------------------------------------------
# 3. server unreachable → REAL error, no empty-answer nudge
# ---------------------------------------------------------------------------
LEX_API_URL="http://127.0.0.1:$(free_port)/v1/chat/completions"
export LEX_API_URL
rc=0
run_turn "Hello" >"$TMP/out3.txt" 2>"$TMP/err3.txt" || rc=$?
err3="$(cat "$TMP/err3.txt")"
check "sse (server down → rc != 0)" "$([[ $rc -ne 0 ]] && echo 1 || echo 0)"
contains "sse (server down → error message)" "request failed" "$err3"
contains "sse (server down → API error instead of silence)" "API error" "$err3"
not_contains "sse (server down → no empty-answer nudge)" "last answer was empty" "$err3"

# ---------------------------------------------------------------------------
# 4. HTTP error (500) → real error with status code
# ---------------------------------------------------------------------------
# THREE 500 lines: call_api tries three times by default (2 retries, step
# 53) — only when ALL of them fail may the turn end with rc != 0. A success
# line in between would have passed silently.
statusfile="$TMP/status.json"
printf 'STATUS:500|{"error":"boom"}\n%.0s' 1 2 3 > "$statusfile"
start_fake "$statusfile"
rc=0
run_turn "Hello" >"$TMP/out4.txt" 2>"$TMP/err4.txt" || rc=$?
err4="$(cat "$TMP/err4.txt")"
check "sse (HTTP 500 → rc != 0)" "$([[ $rc -ne 0 ]] && echo 1 || echo 0)"
contains "sse (HTTP 500 → status code named)" "HTTP 500" "$err4"
contains "sse (HTTP 500 → all attempts exhausted)" "after 3 attempt(s)" "$err4"
not_contains "sse (HTTP 500 → no nudge)" "last answer was empty" "$err4"

# ---------------------------------------------------------------------------
# 5. data: without a space (SSE-conform)
# ---------------------------------------------------------------------------
printf '%s\n' \
  'data:{"choices":[{"index":0,"delta":{"content":"Without space."}}]}' \
  '' \
  'data:{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}' \
  '' \
  'data:[DONE]' \
  '' > "$TMP/praesix.sse"
start_fake "$TMP/praesix.sse"
out="$(run_turn "Test" 2>/dev/null)"
assert "sse (data: without a space)" "Without space." "$out"

# ---------------------------------------------------------------------------
# 6. stream ends without [DONE] → warning, text is used anyway
# ---------------------------------------------------------------------------
printf '%s\n' \
  'data: {"choices":[{"index":0,"delta":{"content":"Partial text."}}]}' \
  '' \
  'data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}' \
  '' > "$TMP/kein_done.sse"
start_fake "$TMP/kein_done.sse"
rc=0
out="$(run_turn "Test" 2>"$TMP/err6.txt")" || rc=$?
assert "sse (partial text is used)" "Partial text." "$out"
check "sse (without [DONE] → rc 0)" "$([[ $rc -eq 0 ]] && echo 1 || echo 0)"
contains "sse (without [DONE] → explicit warning)" "without [DONE]" "$(cat "$TMP/err6.txt")"

# ---------------------------------------------------------------------------
# 7. body without a data:-event → evaluable error, no empty "answer"
# ---------------------------------------------------------------------------
printf 'this is no stream\n' > "$TMP/kein_stream.sse"
start_fake "$TMP/kein_stream.sse"
rc=0
run_turn "Test" >"$TMP/out7.txt" 2>"$TMP/err7.txt" || rc=$?
check "sse (body without data:-event → rc != 0)" "$([[ $rc -ne 0 ]] && echo 1 || echo 0)"
contains "sse (body without data:-event → error message)" "could not be evaluated" "$(cat "$TMP/err7.txt")"

# ---------------------------------------------------------------------------
# 8. performance budget (regression 2026-09-30: ~4 jq forks per SSE line
#    → 3000 chunks cost 29 s). Budget: under 2 s, and the content may
#    arrive completely (otherwise "fast" would just be a cut-off answer).
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
check "sse (budget: 3000 chunks → rc 0)" "$([[ $rc -eq 0 ]] && echo 1 || echo 0)"
assert "sse (budget: content complete, no silent truncation)" "3000" \
  "$(jq -r '.choices[0].message.content | length' <<< "$resp" 2>/dev/null)"
if (( ms < 2000 )); then
  printf '  [PASS] sse (budget: 3000 chunks under 2000 ms — %d ms)\n' "$ms"
else
  printf '  [FAIL] sse (budget: 3000 chunks under 2000 ms — were %d ms)\n' "$ms" >&2
  FAIL=1
fi

# ---------------------------------------------------------------------------
# 9. request body asks for the usage (review finding 2026-10-01: without
#    stream_options.include_usage the llama-server delivers NO usage in the
#    stream — the HUD asks instead of inventing zeros). The body is written
#    along by the fake server via FAKE_BODY_LOG.
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
check "sse (body log created)" "$([[ -s "$FAKE_BODY_LOG" ]] && echo 1 || echo 0)"
assert "sse (body: stream true)" "true" \
  "$(jq -r '.stream // "missing"' <<< "$body9" 2>/dev/null)"
assert "sse (body: stream_options.include_usage)" "true" \
  "$(jq -r '.stream_options.include_usage // "missing"' <<< "$body9" 2>/dev/null)"
# Lever 2 (2026-10-07): chat_template_kwargs must ALWAYS be there — false is
# the template default (unchanged behaviour), true switches thinking off for
# tool requests. Beware jq: `false // "missing"` yields "missing" — the
# value is therefore checked via a null comparison, not //.
_adwt_of() {
  jq -r '.chat_template_kwargs.auto_disable_thinking_with_tools
    | if . == null then "missing" elif type == "boolean" then tostring else "broken" end' \
    <<< "$1" 2>/dev/null
}
assert "sse (body: adwt default false)" "false" "$(_adwt_of "$body9")"
# The running fake server keeps its ENV (FAKE_BODY_LOG path) — therefore
# clear the same log instead of exporting a new path.
: > "$FAKE_BODY_LOG"
_adwt_on_save="${_auto_disable_thinking_with_tools:-}"
_auto_disable_thinking_with_tools=on
call_api >/dev/null 2>"$TMP/err9b.txt" || rc=$?
body9b="$(cat "$FAKE_BODY_LOG" 2>/dev/null)"
assert "sse (body: adwt on = true)" "true" "$(_adwt_of "$body9b")"
_auto_disable_thinking_with_tools="${_adwt_on_save}"
unset FAKE_BODY_LOG

# ---------------------------------------------------------------------------
# 10. usage path: real numbers in the HUD when the server delivers them — and
#     "?" instead of invented zeros when it does not (regression 2026-10-01).
# ---------------------------------------------------------------------------
export LEX_TRACE=1
printf '%s\n' \
  'data: {"choices":[{"index":0,"delta":{"content":"With usage."}}]}' \
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
contains "sse (usage in stream → answer)" "With usage." "$(cat "$TMP/out10.txt")"
# step 42: HUD format with context limit (tokens X/Y (Z%))
contains "sse (usage in the HUD)" "tokens 1409/262144 (0%) prompt + 69 completion" "$(cat "$TMP/err10.txt")"

printf '%s\n' \
  'data: {"choices":[{"index":0,"delta":{"content":"Without usage."}}]}' \
  '' \
  'data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}' \
  '' \
  'data: [DONE]' \
  '' > "$TMP/ohne_usage.sse"
start_fake "$TMP/ohne_usage.sse"
rc=0
run_turn "Test" >"$TMP/out11.txt" 2>"$TMP/err11.txt" || rc=$?
hud11="$(cat "$TMP/err11.txt")"
contains "sse (no usage → HUD asks instead of lying)" "tokens ?/262144 prompt + ? completion" "$hud11"
not_contains "sse (no usage → no invented zeros)" "tokens 0/262144 (0%) prompt + 0 completion" "$hud11"
unset LEX_TRACE

echo ""
if (( FAIL > 0 )); then
  printf 'FAILED: %s test(s) in test_sse.sh\n' "$FAIL" >&2
  exit 1
fi
echo "test_sse.sh green. ✓"
exit 0
