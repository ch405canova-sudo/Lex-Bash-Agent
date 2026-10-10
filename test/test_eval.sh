#!/usr/bin/env bash
#
# lex/test/test_eval.sh — span_log / instrumentation in dispatch_tool / cmd_eval.
# Tests the span level and the trace-level report (lex --eval).
# No port 8080, no real HTTP.
#
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

# load lex: LEX_HOME isolated, LEX_MODEL fake, mock on, stdin=/dev/null
export LEX_HOME="$TMP"
export LEX_MODEL="$TMP/model.gguf"
export LEX_MOCK="done"
export LEX_LOG_DIR="$TMP/log"
mkdir -p "$TMP/log"
source "$LEX_DIR/lex" < /dev/null > /dev/null 2>&1 || {
  echo "FAILED: $LEX_DIR/lex not loadable (syntax/bash error)" >&2
  exit 1
}
_log_dir="$TMP/log"

SPAN_FILE="$TMP/log/spans.jsonl"

# ===========================================================================
# 1. span_log: the function exists and writes valid JSONL
# ===========================================================================
printf '  [INFO] span_log\n'
if declare -F span_log >/dev/null 2>&1; then
  printf '  [PASS] span_log present\n'
else
  printf '  [FAIL] span_log missing\n' >&2
  FAIL=1
fi

rm -f "$SPAN_FILE"
span_log "test_tool" '{"key":"value"}' 42 true
if [[ -f "$SPAN_FILE" ]]; then
  line_count=$(wc -l < "$SPAN_FILE")
  jq -s '.' "$SPAN_FILE" >/dev/null 2>&1 && json_ok=1 || json_ok=0
  if (( json_ok == 1 && line_count >= 1 )); then
    printf '  [PASS] span_log writes valid JSONL\n'
  else
    printf '  [FAIL] span_log: invalid JSONL (lines=%d, json=%d)\n' "$line_count" "$json_ok" >&2
    FAIL=1
  fi
  ok_val=$(jq -rs '.[-1].ok' "$SPAN_FILE" 2>/dev/null)
  assert "span_log: ok=true" "true" "$ok_val"
else
  printf '  [FAIL] span_log: file missing\n' >&2
  FAIL=1
fi

# ===========================================================================
# 2. dispatch_tool: instrumentation logs one tool run
# ===========================================================================
printf '  [INFO] dispatch_tool\n'
rm -f "$SPAN_FILE"
MOCK="$TMP/mock_dispatch.jsonl"
cat > "$MOCK" <<EOF
{"choices":[{"index":0,"message":{"role":"assistant","content":"","reasoning_content":"","tool_calls":[{"id":"tc1","type":"tool_call","function":{"name":"read_file","arguments":"{\"path\":\"$TMP/readme.txt\"}"}}]}}],"usage":{"total_tokens":10}}
{"choices":[{"index":0,"message":{"role":"assistant","content":"fertig","reasoning_content":"","tool_calls":[]}}],"usage":{"total_tokens":10}}
EOF
echo "test" > "$TMP/readme.txt"
_mock_file="$MOCK"
run_turn "Test read" < /dev/null > /dev/null 2>&1
_mock_file=""

if [[ -f "$SPAN_FILE" ]]; then
  name=$(jq -rs '.[0].name' "$SPAN_FILE" 2>/dev/null)
  assert "dispatch: span for read_file" "read_file" "$name"
  ok=$(jq -rs '.[0].ok' "$SPAN_FILE" 2>/dev/null)
  assert "dispatch: ok=true (success)" "true" "$ok"
  dur=$(jq -rs '.[0].duration_ms' "$SPAN_FILE" 2>/dev/null)
  if [[ "$dur" =~ ^[0-9]+$ ]]; then
    printf '  [PASS] dispatch: duration_ms is a number (%s)\n' "$dur"
  else
    printf '  [FAIL] dispatch: duration_ms not a number: %q\n' "$dur" >&2
    FAIL=1
  fi
else
  printf '  [FAIL] dispatch: no span log\n' >&2
  FAIL=1
fi

# ===========================================================================
# 3. dispatch_tool: the error path logs ok=false
# ===========================================================================
printf '  [INFO] dispatch_tool (error path)\n'
rm -f "$SPAN_FILE"
cat > "$MOCK" <<EOF
{"choices":[{"index":0,"message":{"role":"assistant","content":"","reasoning_content":"","tool_calls":[{"id":"tc2","type":"tool_call","function":{"name":"read_file","arguments":"{\"path\":\"$TMP/nonexistent.txt\"}"}}]}}],"usage":{"total_tokens":10}}
{"choices":[{"index":0,"message":{"role":"assistant","content":"fertig","reasoning_content":"","tool_calls":[]}}],"usage":{"total_tokens":10}}
EOF
_mock_file="$MOCK"
run_turn "Test missing" < /dev/null > /dev/null 2>&1
_mock_file=""

if [[ -f "$SPAN_FILE" ]]; then
  ok=$(jq -rs '.[0].ok' "$SPAN_FILE" 2>/dev/null)
  assert "dispatch: ok=false (failure)" "false" "$ok"
else
  printf '  [FAIL] dispatch (error path): no span log\n' >&2
  FAIL=1
fi

# ===========================================================================
# 4. cmd_eval: report from a valid span file
# ===========================================================================
printf '  [INFO] cmd_eval\n'
rm -f "$SPAN_FILE"
cat > "$SPAN_FILE" <<'EOF'
{"ts":"2026-09-30T10:00:00+0200","name":"read_file","args_hash":"abc123","duration_ms":15,"ok":true}
{"ts":"2026-09-30T10:00:01+0200","name":"bash","args_hash":"def456","duration_ms":120,"ok":true}
{"ts":"2026-09-30T10:00:02+0200","name":"bash","args_hash":"ghi789","duration_ms":50,"ok":false}
{"ts":"2026-09-30T10:00:03+0200","name":"read_file","args_hash":"jkl012","duration_ms":10,"ok":true}
EOF

out="$(cmd_eval "$SPAN_FILE" 2>&1)"
rc=$?
assert "cmd_eval: rc" "0" "$rc"
contains "cmd_eval: header" "Trace-level evaluation" "$out"
contains "cmd_eval: verdict" "FAILED: 1 of 4" "$out"
contains "cmd_eval: per-tool section" "Per tool:" "$out"
if [[ "$out" == *"read_file:"* && "$out" == *"bash:"* ]]; then
  printf '  [PASS] cmd_eval: both tools in the report\n'
else
  printf '  [FAIL] cmd_eval: tools missing from the report\n' >&2
  FAIL=1
fi

# ===========================================================================
# 5. cmd_eval: empty file
# ===========================================================================
printf '  [INFO] cmd_eval (empty file)\n'
rm -f "$SPAN_FILE"
touch "$SPAN_FILE"
out="$(cmd_eval "$SPAN_FILE" 2>&1)"
rc=$?
if (( rc == 0 )) && [[ "$out" == *"OK: 0 tool calls, 0 failures"* ]]; then
  printf '  [PASS] cmd_eval: empty file\n'
else
  printf '  [FAIL] cmd_eval: empty file (rc=%d)\n' "$rc" >&2
  FAIL=1
fi

# ===========================================================================
# 6. cmd_eval: missing file
# ===========================================================================
printf '  [INFO] cmd_eval (missing file)\n'
out="$(cmd_eval "$TMP/nonexistent.jsonl" 2>&1)"
rc=$?
# M4 (2026-10-08): "no spans" is an error state — before rc 0, so
# `lex --eval` without data reported success anyway.
if (( rc == 1 )) && [[ "$out" == *"No span log found"* ]]; then
  printf '  [PASS] cmd_eval: missing file (rc 1)\n'
else
  printf '  [FAIL] cmd_eval: missing file (rc=%d)\n' "$rc" >&2
  FAIL=1
fi

# ===========================================================================
# 7. CLI: lex --eval
# ===========================================================================
printf '  [INFO] lex --eval (CLI)\n'
out="$(bash "$LEX_DIR/lex" --eval "$SPAN_FILE" 2>&1)"
rc=$?
assert "lex --eval: rc" "0" "$rc"
contains "lex --eval: header" "Trace-level evaluation" "$out"

# ===========================================================================
# 8. N7: `lex --eval --approve <file>` — --approve must not be eaten as a
#    filename (flags in any order).
# ===========================================================================
printf '  [INFO] lex --eval --approve (flag position)\n'
out="$(bash "$LEX_DIR/lex" --eval --approve "$SPAN_FILE" 2>&1)"
rc=$?
assert "lex --eval --approve: rc" "0" "$rc"
contains "lex --eval --approve: evaluates" "Trace-level evaluation" "$out"

# ===========================================================================
# 9. M4: settings-`log_dir` reaches the evaluator (own LEX_HOME without a
#    `log/` folder — otherwise the hard default would find the file too).
# ===========================================================================
printf '  [INFO] lex --eval (settings-log_dir)\n'
mkdir -p "$TMP/settingslog" "$TMP/evalhome"
cp "$SPAN_FILE" "$TMP/settingslog/spans.jsonl"
jq -n --arg d "$TMP/settingslog" '{log_dir:$d}' > "$TMP/evalhome/settings.json"
out="$(env -u LEX_LOG_DIR LEX_HOME="$TMP/evalhome" LEX_MODEL="$TMP/model.gguf" \
  LEX_MOCK=done bash "$LEX_DIR/lex" --eval 2>&1)"
rc=$?
assert "lex --eval settings-log_dir: rc" "0" "$rc"
contains "lex --eval settings-log_dir: span file found" "Trace-level evaluation" "$out"
rm -f "$TMP/evalhome/settings.json"

echo ""
if (( FAIL > 0 )); then
  printf 'FAILED: %s test(s) in test_eval.sh\n' "$FAIL" >&2
  exit 1
fi
echo "test_eval.sh green. ✓"
exit 0
