#!/usr/bin/env bash
#
# lex/test/test_loop.sh — run_turn / setup_messages / max-turns.
# The script is loaded via source (stdin=/dev/null → the REPL path exits immediately).
# LEX_MOCK=done for the simple path, LEX_MOCK_FILE for multi-turn.
# No port 8080, no real HTTP.
#
# shellcheck disable=SC2154  # _messages/_mock_file come from the loaded lex
set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEX_DIR="$(dirname "$SCRIPT_DIR")"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

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

# Load the script: LEX_HOME isolated, LEX_MODEL fake, mock active, stdin=/dev/null
export LEX_HOME="$TMP"
export LEX_MODEL="$TMP/model.gguf"
export LEX_MOCK="done"
source "$LEX_DIR/lex" < /dev/null > /dev/null 2>&1 || {
  echo "FAILED: $LEX_DIR/lex not loadable (syntax/bash error)" >&2
  exit 1
}

# 1. setup_messages: system prompt as the first element
setup_messages
role="$(jq -r '.[0].role' <<< "$_messages")"
content="$(jq -r '.[0].content' <<< "$_messages")"
if [[ "$role" == "system" ]] && [[ "$content" == *"You are Lex"* ]]; then
  printf '  [PASS] setup_messages\n'
else
  printf '  [FAIL] setup_messages (role=%s)\n' "$role" >&2
  FAIL=1
fi

# 2. run_turn with LEX_MOCK=done → the model answer is printed
out="$(run_turn "Test" 2>/dev/null)"
assert "run_turn (mock)" "Works." "$out"

# 3. Multi-turn via LEX_MOCK_FILE: tool call → tool result → final answer
mock="$TMP/loop_mock.json"
printf '%s\n' \
  '{"choices":[{"index":0,"message":{"role":"assistant","content":"","tool_calls":[{"id":"tc1","type":"function","function":{"name":"read_file","arguments":"{\"path\":\"'$TMP'/loop.txt\"}"}}]}}]}' \
  '{"choices":[{"index":0,"message":{"role":"assistant","content":"Done.","tool_calls":[]}}]}' > "$mock"
printf 'Content\n' > "$TMP/loop.txt"
_mock_file="$mock"
out="$(run_turn "Read" 2>/dev/null)"
assert "loop (tool + final answer)" "Done." "$out"

# 4. Tool call arguments are parsed correctly (read_file via dispatch)
out="$(cat "$TMP/loop.txt")"
assert "loop (tool output)" "Content" "$out"

# 5. Max turns: _max_turns=2, 2 tool answers → abort (exit 1)
printf '%s\n%s\n' \
  '{"choices":[{"index":0,"message":{"role":"assistant","content":"","tool_calls":[{"id":"t1","type":"function","function":{"name":"bash","arguments":"{\"command\":\"echo a\"}"}}]}}]}' \
  '{"choices":[{"index":0,"message":{"role":"assistant","content":"","tool_calls":[{"id":"t2","type":"function","function":{"name":"bash","arguments":"{\"command\":\"echo b\"}"}}]}}]}' > "$mock"
_max_turns=2
run_turn "Max" >/dev/null 2>&1
rc=$?
if (( rc != 0 )); then
  printf '  [PASS] run_turn (max turns)\n'
else
  printf '  [FAIL] run_turn (max turns, exit %s)\n' "$rc" >&2
  FAIL=1
fi

# 6. finish_reason=length (text): nudge path → the loop continues
mock="$TMP/length_mock.json"
printf '%s\n%s\n' \
  '{"choices":[{"index":0,"message":{"role":"assistant","content":"This is a tru","tool_calls":[]},"finish_reason":"length"}]}' \
  '{"choices":[{"index":0,"message":{"role":"assistant","content":"nicated answer.","tool_calls":[]},"finish_reason":"stop"}]}' > "$mock"
_mock_file="$mock"
run_turn "Test" > "$TMP/out.txt" 2> "$TMP/err.txt"
out="$(cat "$TMP/out.txt")"
assert "length (text, final answer)" "nicated answer." "$out"
if [[ "$(cat "$TMP/err.txt")" == *"truncated"* ]]; then
  printf '  [PASS] length (warning on stderr)\n'
else
  printf '  [FAIL] length (no warning on stderr): %q\n' "$(cat "$TMP/err.txt")" >&2
  FAIL=1
fi

# 7. finish_reason=length (tool calls): tools are NOT executed, nudge
printf '%s\n%s\n' \
  '{"choices":[{"index":0,"message":{"role":"assistant","content":"","tool_calls":[{"id":"tc1","type":"function","function":{"name":"read_file","arguments":"{\"path\":\"'$TMP'/tool_len.txt\"}"}}]},"finish_reason":"length"}]}' \
  '{"choices":[{"index":0,"message":{"role":"assistant","content":"OK.","tool_calls":[]},"finish_reason":"stop"}]}' > "$mock"
printf 'Secret\n' > "$TMP/tool_len.txt"
run_turn "Tool" > "$TMP/out.txt" 2> "$TMP/err.txt"
out="$(cat "$TMP/out.txt")"
assert "length (tool call, final answer)" "OK." "$out"
if [[ "$(cat "$TMP/err.txt")" == *"Tool calls were truncated"* ]]; then
  printf '  [PASS] length (tool calls, warning)\n'
else
  printf '  [FAIL] length (tool calls, warning): %q\n' "$(cat "$TMP/err.txt")" >&2
  FAIL=1
fi

# 8. Rescue logic: repeated length WITH content → after 2 nudges the
#    partial text is rendered (rc 0) instead of ending in nothing with rc 1
#    (limit here hard 2: the mock file has exactly 3 length entries)
_max_nudges=2
printf '%s\n%s\n%s\n' \
  '{"choices":[{"index":0,"message":{"role":"assistant","content":"This is the start of the","tool_calls":[]},"finish_reason":"length"}]}' \
  '{"choices":[{"index":0,"message":{"role":"assistant","content":"answer and here comes the","tool_calls":[]},"finish_reason":"length"}]}' \
  '{"choices":[{"index":0,"message":{"role":"assistant","content":"last part of the sentence.","tool_calls":[]},"finish_reason":"length"}]}' > "$mock"
_mock_file="$mock"
_max_turns=4
run_turn "Test" > "$TMP/out.txt" 2> "$TMP/err.txt"
rc=$?
out="$(cat "$TMP/out.txt")"
assert "rescue (partial text rendered)" "last part of the sentence." "$out"
if (( rc == 0 )) && [[ "$(cat "$TMP/err.txt")" == *"showing the partial text"* ]]; then
  printf '  [PASS] rescue (rc 0 + note on stderr)\n'
else
  printf '  [FAIL] rescue (rc=%s, stderr: %q)\n' "$rc" "$(cat "$TMP/err.txt")" >&2
  FAIL=1
fi

# 9. Max-turns abort renders the partial text that exists (rescue logic)
printf '%s\n' \
  '{"choices":[{"index":0,"message":{"role":"assistant","content":"Half-finished answer.","tool_calls":[]},"finish_reason":"length"}]}' > "$mock"
_mock_file="$mock"
_max_turns=1
run_turn "Test" > "$TMP/out.txt" 2> "$TMP/err.txt"
rc=$?
out="$(cat "$TMP/out.txt")"
assert "max-re (partial text rendered)" "Half-finished answer." "$out"
if (( rc == 0 )) && [[ "$(cat "$TMP/err.txt")" == *"Max Turns reached"* ]]; then
  printf '  [PASS] max-re (rc 0 + note on stderr)\n'
else
  printf '  [FAIL] max-re (rc=%s, stderr: %q)\n' "$rc" "$(cat "$TMP/err.txt")" >&2
  FAIL=1
fi

# 10. _max_nudges lever (default 4, LEX_MAX_NUDGES): limit 1 → the rescue
#     path kicks in after a single nudge, the second length answer is
#     rendered as partial text (rc 0) without exhausting the mock file.
printf '%s\n%s\n' \
  '{"choices":[{"index":0,"message":{"role":"assistant","content":"Part one ","tool_calls":[]},"finish_reason":"length"}]}' \
  '{"choices":[{"index":0,"message":{"role":"assistant","content":"Part two.","tool_calls":[]},"finish_reason":"length"}]}' > "$mock"
_mock_file="$mock"
_max_turns=4
_max_nudges=1
run_turn "Nudge1" > "$TMP/out.txt" 2> "$TMP/err.txt"
rc=$?
out="$(cat "$TMP/out.txt")"
assert "nudge-limit1 (partial text after one nudge)" "Part two." "$out"
if (( rc == 0 )) && [[ "$(cat "$TMP/err.txt")" == *"showing the partial text"* ]]; then
  printf '  [PASS] nudge-limit1 (rc 0 + note)\n'
else
  printf '  [FAIL] nudge-limit1 (rc=%s, stderr: %q)\n' "$rc" "$(cat "$TMP/err.txt")" >&2
  FAIL=1
fi
_max_nudges=4

if (( FAIL > 0 )); then
  echo "FAILED: $FAIL test(s) in test_loop.sh" >&2
  exit 1
fi
echo "test_loop.sh green. ✓"
exit 0
