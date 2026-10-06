#!/usr/bin/env bash
#
# lex/test/test_http.sh — the real curl path in call_api() via a fake OpenAI server.
# Starts fake_server.sh on a high port, points LEX_API_URL at it,
# and tests the real HTTP body construction (jq -n + curl), WITHOUT touching
# the llama-server (port 8080).
#
set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEX_DIR="$(dirname "$SCRIPT_DIR")"

TMP="$(mktemp -d)"
FAKE_PID=""
cleanup() {
  # Kill the server first, then clean up: handler/lock live in TMP
  # and are still needed by ncat per connection.
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

# 1. fake server response file (one JSON response per line)
resp="$TMP/responses.json"
printf '%s\n%s\n' \
  '{"choices":[{"index":0,"message":{"role":"assistant","content":"Hello over HTTP!","reasoning_content":"","tool_calls":[]},"finish_reason":"stop"}],"usage":{"total_tokens":10}}' \
  '{"choices":[{"index":0,"message":{"role":"assistant","content":"Done.","reasoning_content":"","tool_calls":[]},"finish_reason":"stop"}],"usage":{"total_tokens":10}}' > "$resp"

# 2. start the fake server on a high port
FAKE_PORT=$((20000 + RANDOM % 8000))
FAKE_PID="$(bash "$SCRIPT_DIR/fake_server.sh" "$FAKE_PORT" "$resp")"
if [[ -z "$FAKE_PID" ]]; then
  echo "FAILED: fake server could not be started on port $FAKE_PORT" >&2
  exit 1
fi

# wait for the port (the fake server waits internally, but check again anyway)
for _ in $(seq 1 30); do
  if nc -z 127.0.0.1 "$FAKE_PORT" 2>/dev/null; then
    break
  fi
  sleep 0.1
done

# 3. source lex with the real HTTP path (mock off, API URL at the fake server)
export LEX_HOME="$TMP"
export LEX_MODEL="$TMP/model.gguf"
export LEX_API_URL="http://127.0.0.1:$FAKE_PORT/v1/chat/completions"
unset LEX_MOCK
unset LEX_MOCK_FILE
source "$LEX_DIR/lex" < /dev/null > /dev/null 2>&1 || {
  echo "FAILED: $LEX_DIR/lex not loadable (syntax/bash error)" >&2
  exit 1
}

# 4. test: final answer over the real HTTP path
out="$(run_turn "Test over HTTP" 2>/dev/null)"
assert "http (final answer)" "Hello over HTTP!" "$out"

# 5. test: multi-turn (the 2nd answer comes from the server, the 1st was a tool call)
resp2="$TMP/responses2.json"
printf '%s\n%s\n' \
  '{"choices":[{"index":0,"message":{"role":"assistant","content":"","tool_calls":[{"id":"tc1","type":"function","function":{"name":"read_file","arguments":"{\"path\":\"'$TMP'/http.txt\"}"}}]},"finish_reason":"stop"}]}' \
  '{"choices":[{"index":0,"message":{"role":"assistant","content":"Reading done.","reasoning_content":"","tool_calls":[]},"finish_reason":"stop"}]}' > "$resp2"

# restart the fake server with a new response file (the old one is used up)
kill "$FAKE_PID" 2>/dev/null || true
FAKE_PID=""
FAKE_PORT=$((20000 + RANDOM % 8000))
FAKE_PID="$(bash "$SCRIPT_DIR/fake_server.sh" "$FAKE_PORT" "$resp2")"
if [[ -z "$FAKE_PID" ]]; then
  echo "FAILED: fake server (2nd start) could not be started on port $FAKE_PORT" >&2
  exit 1
fi
for _ in $(seq 1 30); do
  if nc -z 127.0.0.1 "$FAKE_PORT" 2>/dev/null; then
    break
  fi
  sleep 0.1
done
export LEX_API_URL="http://127.0.0.1:$FAKE_PORT/v1/chat/completions"
printf 'Content\n' > "$TMP/http.txt"
out="$(run_turn "Read" 2>/dev/null)"
assert "http (multi-turn with a tool)" "Reading done." "$out"

#6. Body > 128 KiB: exec argument limit (E2BIG) — curl gets @file instead of
#   an argv string (finding 2026-09-29: multiple turns push the history
#   over the kernel limit; without the fix: "Argument list too long").
resp3="$TMP/responses3.json"
printf '%s\n' '{"choices":[{"index":0,"message":{"role":"assistant","content":"Big body ok.","reasoning_content":"","tool_calls":[]}}],"usage":{"total_tokens":1}}' > "$resp3"
kill "$FAKE_PID" 2>/dev/null || true
FAKE_PID=""
FAKE_PORT=$((20000 + RANDOM % 8000))
FAKE_PID="$(bash "$SCRIPT_DIR/fake_server.sh" "$FAKE_PORT" "$resp3")"
if [[ -z "$FAKE_PID" ]]; then
  echo "FAILED: fake server (3rd start) could not be started" >&2
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
# Second giant message: >131072 B total context — if jq still
# used --argjson m (instead of --slurpfile), body building would fail with E2BIG and
# the rc-guard of call_api would fail the test (coverage for
# the jq fix, review finding 2026-09-29).
append_message user "$big"
mrc=0; out="$(run_turn "Big" 2>/dev/null)" || mrc=$?
assert "http (Body > 128 KiB works, E2BIG fix)" "Big body ok." "$out"
assert "http (Body > 128 KiB rc)" "0" "$mrc"

# 7. Retry path (step 53, §6 #36): HTTP 500 is RETRIED before the turn dies
#    — the OpenAI SDK norm. Script file: first line 500, second line valid →
#    after one backoff the answer must come.
resp4="$TMP/responses4.json"
printf '%s\n%s\n' \
  'STATUS:500|{"error":"boom"}' \
  '{"choices":[{"index":0,"message":{"role":"assistant","content":"After the retry.","reasoning_content":"","tool_calls":[]},"finish_reason":"stop"}],"usage":{"total_tokens":10}}' > "$resp4"
kill "$FAKE_PID" 2>/dev/null || true
FAKE_PID=""
FAKE_PORT=$((20000 + RANDOM % 8000))
FAKE_PID="$(bash "$SCRIPT_DIR/fake_server.sh" "$FAKE_PORT" "$resp4")"
if [[ -z "$FAKE_PID" ]]; then
  echo "FAILED: fake server (4th start) could not be started" >&2
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
_api_retries=1   # load_config already ran when sourced — tier 4 never fires then
# shellcheck disable=SC2154  # _log_dir comes from the sourced lex
rm -f "$_log_dir/lex.log"
setup_messages
mrc=0; out="$(run_turn "After the retry" 2>"$TMP/err4.txt")" || mrc=$?
assert "retry (answer after HTTP 500)" "After the retry." "$out"
assert "retry (rc=0)" "0" "$mrc"
assert "retry (backoff logged)" "1" \
  "$([[ "$(cat "$_log_dir/lex.log" 2>/dev/null)" == *"attempt 1 failed"* ]] && echo 1 || echo 0)"

# Without budget (LEX_API_RETRIES=0): the same 500 must fail hard.
resp5="$TMP/responses5.json"
printf '%s\n' 'STATUS:500|{"error":"boom"}' > "$resp5"
kill "$FAKE_PID" 2>/dev/null || true
FAKE_PID=""
FAKE_PORT=$((20000 + RANDOM % 8000))
FAKE_PID="$(bash "$SCRIPT_DIR/fake_server.sh" "$FAKE_PORT" "$resp5")"
if [[ -z "$FAKE_PID" ]]; then
  echo "FAILED: fake server (5th start) could not be started" >&2
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
mrc=0; out="$(run_turn "Without budget" 2>"$TMP/err5.txt")" || mrc=$?
assert "retry off (rc != 0)" "1" "$([[ "$mrc" -ne 0 ]] && echo 1 || echo 0)"
assert "retry off (no backoff in the log)" "0" \
  "$([[ "$(cat "$_log_dir/lex.log" 2>/dev/null)" == *"attempt 1 failed"* ]] && echo 1 || echo 0)"
if grep -q "HTTP 500" "$TMP/err5.txt" 2>/dev/null; then
  printf '  [PASS] retry off (HTTP 500 named)\n'
else
  printf '  [FAIL] retry off (no HTTP 500 in the message): %q\n' "$(cat "$TMP/err5.txt" 2>/dev/null)" >&2
  FAIL=1
fi
unset LEX_API_RETRIES

if (( FAIL > 0 )); then
  echo "FAILED: $FAIL test(s) in test_http.sh" >&2
  exit 1
fi
echo "test_http.sh green. ✓"
exit 0
