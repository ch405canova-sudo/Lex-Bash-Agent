#!/usr/bin/env bash
#
# lex/test/test_limits.sh — nothing at the lex↔llama boundary gets cut off.
#
# Finding 2026-09-30: caps at 100 000 bytes (append_message/append_tool_message/
# setup_messages, because `jq --arg` fails on MAX_ARG_STRLEN) and 50 000 bytes
# (per-tool caps) tore data out of the protocol without the model noticing.
# The path now runs over files (--rawfile/--slurpfile), and oversized tool
# results are stored instead of thrown away.
#
# What is checked:
#   1. user-/tool-/assistant messages at full length in _messages
#   2. session JSONL with the same length
#   3. system prompt including wiki state uncut
#   4. tool_read_file returns the whole file
#   5. oversized tool result → head + storage path, storage complete
#   6. server answer (llama→lex) uncut in the context
#
# HIGH PORTS only — the real llama-server (8080) is never touched.
#
# shellcheck disable=SC2154  # _messages/_mock_file/_system_prompt come from the loaded lex
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
    printf '         text (start): %q\n' "${hay:0:200}" >&2
    FAIL=1
  fi
}
not_contains() {
  local desc="$1" needle="$2" hay="$3"
  if [[ "$hay" != *"$needle"* ]]; then
    printf '  [PASS] %s\n' "$desc"
  else
    printf '  [FAIL] %s (must not contain: %q)\n' "$desc" "$needle" >&2
    printf '         text (start): %q\n' "${hay:0:200}" >&2
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
mkbig() {   # $1 = number of chars, with escaping stress (quotes, backslash, tab, lines)
  local n="$1"
  awk -v n="$n" 'BEGIN{
    s = "Line \"with\" quotes and \\ Backslash and\tTab and\\nNewline ";
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
    echo "FAILED: no free port" >&2
    exit 1
  fi
  FAKE_PID="$(bash "$SCRIPT_DIR/fake_server.sh" "$port" "$1" 2>/dev/null)"
  if [[ -z "$FAKE_PID" ]]; then
    echo "FAILED: fake server does not start" >&2
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
# Source lex: LEX_HOME isolated, mock off (the HTTP path is what gets tested).
# ---------------------------------------------------------------------------
export LEX_HOME="$TMP"
export LEX_MODEL="$TMP/model.gguf"
# Wiki isolated: otherwise the real wiki state hangs on the system prompt and
# the length statements below no longer match.
export LEX_WIKI_DIR="$TMP/wiki"
mkdir -p "$TMP/wiki"
unset LEX_MOCK
unset LEX_MOCK_FILE
source "$LEX_DIR/lex" < /dev/null > /dev/null 2>&1 || {
  echo "FAILED: $LEX_DIR/lex not loadable (syntax/bash error)" >&2
  exit 1
}
setup_messages >/dev/null 2>&1 || true
session_file="${_session_file:-}"

# ===========================================================================
# 1. append_message: long message arrives complete
# ===========================================================================
printf '  [INFO] append_message (280 000 chars)\n'
big="$(mkbig 280000)"
blen=${#big}
append_message "user" "$big"
got="$(jq -r '.[-1].content | length' <<< "$_messages" 2>/dev/null)"
assert "limits (user content complete)" "$blen" "$got"
not_contains "limits (user content without truncation marker)" "truncated" \
  "$(jq -r '.[-1].content' <<< "$_messages" 2>/dev/null)"

# ===========================================================================
# 2. append_tool_message: long tool result arrives complete
# ===========================================================================
printf '  [INFO] append_tool_message (280 000 chars)\n'
append_tool_message "tc-limits" "$big"
got="$(jq -r '.[-1].content | length' <<< "$_messages" 2>/dev/null)"
assert "limits (tool content complete)" "$blen" "$got"
assert "limits (tool message with id)" "tc-limits" \
  "$(jq -r '.[-1].tool_call_id // ""' <<< "$_messages" 2>/dev/null)"
assert "limits (role stays tool)" "tool" \
  "$(jq -r '.[-1].role' <<< "$_messages" 2>/dev/null)"

# ===========================================================================
# 3. session: the same record stands complete in the JSONL
# ===========================================================================
printf '  [INFO] session JSONL\n'
if [[ -n "$session_file" && -f "$session_file" ]]; then
  rec="$(jq -r 'select(.type=="message") | .message.content | length' "$session_file" 2>/dev/null | tail -n 1)"
  assert "limits (session contains full length)" "$blen" "$rec"
  check "limits (session JSONL is valid)" \
    "$([[ "$(jq -s '.' "$session_file" >/dev/null 2>&1; echo $?)" == "0" ]] && echo 1 || echo 0)"
else
  printf '  [FAIL] limits: session file missing (%s)\n' "${session_file:-empty}" >&2
  FAIL=1
fi

# ===========================================================================
# 4. tool_read_file: whole file, no own cap anymore
# ===========================================================================
printf '  [INFO] tool_read_file (60 000 bytes)\n'
awk 'BEGIN{for(i=0;i<60000;i++)printf "r"}' > "$TMP/gross.txt"
out="$(tool_read_file "$TMP/gross.txt" 2>/dev/null)"
assert "limits (read_file: whole file)" "60000" "${#out}"
not_contains "limits (read_file: no truncation marker)" "truncated" "$out"

# ===========================================================================
# 5. oversized tool result → head + storage path, storage complete
# ===========================================================================
printf '  [INFO] spill (60 000 bytes to the model)\n'
MOCK="$TMP/mock_spill.jsonl"
cmd="$(jq -cn --arg c "awk 'BEGIN{for(i=0;i<60000;i++)printf \"s\"}'" '{command:$c}')"
{
  jq -cn --argjson a "$cmd" \
    '{choices:[{index:0,message:{role:"assistant",content:"",reasoning_content:"",
      tool_calls:[{id:"tc-spill",type:"function",
        function:{name:"bash",arguments:($a|tostring)}}]}}],
      usage:{total_tokens:10}}'
  jq -cn '{choices:[{index:0,message:{role:"assistant",content:"done",
    reasoning_content:"",tool_calls:[]}}],usage:{total_tokens:10}}'
} > "$MOCK"
_mock_file="$MOCK"
run_turn "big result" < /dev/null > /dev/null 2>&1
_mock_file=""

toolmsg="$(jq -r '.[] | select(.role=="tool") | .content' <<< "$_messages" 2>/dev/null)"
contains "limits (spill pointer in the context)" "full output stored at" "$toolmsg"
contains "limits (spill path in the context)" "$LEX_HOME/toolout/" "$toolmsg"
spill="$(ls -1 "$LEX_HOME/toolout/"*.txt 2>/dev/null | head -n 1)"
if [[ -n "$spill" ]]; then
  slen="$(wc -c < "$spill" | tr -d ' ')"
  check "limits (storage complete ≥ 60 000 bytes)" "$([[ "$slen" -ge 60000 ]] && echo 1 || echo 0)"
  printf '         storage: %s (%s bytes)\n' "$spill" "$slen"
else
  printf '  [FAIL] limits: no storage under %s/toolout\n' "$LEX_HOME" >&2
  FAIL=1
fi

# M1 (audit 2026-10-08): the spill lies with 600 and REDACTED on disk —
# before the raw tool output went unprotected into toolout/.
m1="$(_tool_spill m1probe 'PASSWORD=hunter2 api_key=ghp_secret123')"
check "limits (M1: spill created)" "$([[ -n "$m1" && -f "$m1" ]] && echo 1 || echo 0)"
assert "limits (M1: spill mode 600)" "600" \
  "$(stat -c '%a' "$m1" 2>/dev/null || stat -f '%Lp' "$m1" 2>/dev/null)"
m1c="$(cat "$m1" 2>/dev/null)"
check "limits (M1: secret redacted)" \
  "$([[ "$m1c" != *hunter2* && "$m1c" != *ghp_secret123* && "$m1c" == *REDACT* ]] && echo 1 || echo 0)"

# ===========================================================================
# 6. server answer (llama→lex): 150 000 chars uncut in the context
# ===========================================================================
printf '  [INFO] server answer (150 000 chars)\n'
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
run_turn "long answer" < /dev/null > /dev/null 2>&1
kill_fake
alen=150000
got="$(jq -r '.[-1].content | length' <<< "$_messages" 2>/dev/null)"
assert "limits (server answer complete)" "$alen" "$got"
assert "limits (role assistant)" "assistant" \
  "$(jq -r '.[-1].role' <<< "$_messages" 2>/dev/null)"
not_contains "limits (server answer without truncation marker)" "truncated" \
  "$(jq -r '.[-1].content' <<< "$_messages" 2>/dev/null)"

# ===========================================================================
# 7. system prompt including wiki state: no 100 000-byte cap
# ===========================================================================
printf '  [INFO] system prompt (250 000 chars)\n'
orig_sys="$_system_prompt"
_system_prompt="$(mkbig 250000)"
setup_messages >/dev/null 2>&1
got="$(jq -r '.[0].content | length' <<< "$_messages" 2>/dev/null)"
assert "limits (system prompt complete)" "250000" "$got"
not_contains "limits (system prompt without truncation marker)" "truncated" \
  "$(jq -r '.[0].content' <<< "$_messages" 2>/dev/null)"
_system_prompt="$orig_sys"
setup_messages >/dev/null 2>&1

echo ""
if (( FAIL > 0 )); then
  printf 'FAILED: %s test(s) in test_limits.sh\n' "$FAIL" >&2
  exit 1
fi
echo "test_limits.sh green. ✓"
exit 0
