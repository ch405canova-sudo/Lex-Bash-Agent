#!/usr/bin/env bash
#
# lex/test/test_eval.sh — span_log / dispatch_tool instrumentation / cmd_eval.
# Tests span-level logging and the trace-level report.
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

# Load the script: LEX_HOME isolated, LEX_MODEL fake, mock on, stdin=/dev/null
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

# ============================================================================
# 1. span_log: the function exists and writes valid JSONL
# ============================================================================
printf '  [INFO] span_log\n'
if ! declare -F span_log >/dev/null 2>&1; then
  printf '  [FAIL] span_log function does not exist\n' >&2
  FAIL=1
fi

# call span_log
rm -f "$SPAN_FILE"
span_log "test_tool" '{"key":"value"}' 42 true
if [[ -f "$SPAN_FILE" ]]; then
  # check: valid JSONL (every line valid JSON)
  line_count=$(wc -l < "$SPAN_FILE")
  jq -s '.' "$SPAN_FILE" >/dev/null 2>&1 && json_ok=1 || json_ok=0
  if (( json_ok == 1 && line_count >= 1 )); then
    printf '  [PASS] span_log writes valid JSONL\n'
  else
    printf '  [FAIL] span_log: invalid JSONL (lines=%d, json_ok=%d)\n' "$line_count" "$json_ok" >&2
    FAIL=1
  fi
  # check: ok is a boolean
  ok_val=$(jq -rs '.[-1].ok' "$SPAN_FILE" 2>/dev/null)
  if [[ "$ok_val" == "true" ]]; then
    printf '  [PASS] span_log: ok=true\n'
  else
    printf '  [FAIL] span_log: ok expected "true", got "%s"\n' "$ok_val" >&2
    FAIL=1
  fi
fi

# ============================================================================
# 2. dispatch_tool: instrumentation writes a span on a tool call
# ============================================================================
printf '  [INFO] dispatch_tool\n'
# before: no spans
rm -f "$SPAN_FILE"
# mock file: 1 tool call + 1 done
MOCK="$TMP/mock_dispatch.jsonl"
cat > "$MOCK" <<EOF
{"choices":[{"index":0,"message":{"role":"assistant","content":"","reasoning_content":"","tool_calls":[{"id":"tc1","type":"tool_call","function":{"name":"read_file","arguments":"{\"path\":\"$TMP/readme.txt\"}"}}]}}],"usage":{"total_tokens":10}}
{"choices":[{"index":0,"message":{"role":"assistant","content":"done","reasoning_content":"","tool_calls":[]}}],"usage":{"total_tokens":10}}
EOF
echo "test" > "$TMP/readme.txt"
_mock_file="$MOCK"
run_turn "Test read" < /dev/null > /dev/null 2>&1
_mock_file=""

if [[ -f "$SPAN_FILE" ]]; then
  name=$(jq -rs '.[0].name' "$SPAN_FILE" 2>/dev/null)
  if [[ "$name" == "read_file" ]]; then
    printf '  [PASS] dispatch_tool writes a span for read_file\n'
  else
    printf '  [FAIL] dispatch_tool: unexpected tool name "%s"\n' "$name" >&2
    FAIL=1
  fi
  # ok should be true (the file exists)
  ok=$(jq -rs '.[0].ok' "$SPAN_FILE" 2>/dev/null)
  if [[ "$ok" == "true" ]]; then
    printf '  [PASS] dispatch_tool: ok=true (success)\n'
  else
    printf '  [FAIL] dispatch_tool: ok expected "true", got "%s"\n' "$ok" >&2
    FAIL=1
  fi
  # duration_ms must be a number
  dur=$(jq -rs '.[0].duration_ms' "$SPAN_FILE" 2>/dev/null)
  if [[ "$dur" =~ ^[0-9]+$ ]]; then
    printf '  [PASS] dispatch_tool: duration_ms is a number (%s)\n' "$dur"
  else
    printf '  [FAIL] dispatch_tool: duration_ms not a number: %q\n' "$dur" >&2
    FAIL=1
  fi
else
  printf '  [FAIL] dispatch_tool: no span log written\n' >&2
  FAIL=1
fi

# ============================================================================
# 3. dispatch_tool: the error path writes ok=false
# ============================================================================
printf '  [INFO] dispatch_tool error path\n'
rm -f "$SPAN_FILE"
cat > "$MOCK" <<EOF
{"choices":[{"index":0,"message":{"role":"assistant","content":"","reasoning_content":"","tool_calls":[{"id":"tc2","type":"tool_call","function":{"name":"read_file","arguments":"{\"path\":\"$TMP/nonexistent.txt\"}"}}]}}],"usage":{"total_tokens":10}}
{"choices":[{"index":0,"message":{"role":"assistant","content":"done","reasoning_content":"","tool_calls":[]}}],"usage":{"total_tokens":10}}
EOF
_mock_file="$MOCK"
run_turn "Test missing" < /dev/null > /dev/null 2>&1
_mock_file=""

if [[ -f "$SPAN_FILE" ]]; then
  ok=$(jq -rs '.[0].ok' "$SPAN_FILE" 2>/dev/null)
  if [[ "$ok" == "false" ]]; then
    printf '  [PASS] dispatch_tool: ok=false (failure)\n'
  else
    printf '  [FAIL] dispatch_tool error path: ok expected "false", got "%s"\n' "$ok" >&2
    FAIL=1
  fi
else
  printf '  [FAIL] dispatch_tool error path: no span log\n' >&2
  FAIL=1
fi

# ============================================================================
# 4. cmd_eval: report from a valid span log
# ============================================================================
printf '  [INFO] cmd_eval\n'
rm -f "$SPAN_FILE"
cat > "$SPAN_FILE" <<'EOF'
{"ts":"2026-09-30T10:00:00+00:00","name":"read_file","args_hash":"abc123","duration_ms":15,"ok":true}
{"ts":"2026-09-30T10:00:01+00:00","name":"bash","args_hash":"def456","duration_ms":120,"ok":true}
{"ts":"2026-09-30T10:00:02+00:00","name":"bash","args_hash":"ghi789","duration_ms":50,"ok":false}
{"ts":"2026-09-30T10:00:03+00:00","name":"read_file","args_hash":"jkl012","duration_ms":10,"ok":true}
EOF

out="$(cmd_eval "$SPAN_FILE" 2>&1)"
rc=$?

if (( rc == 0 )); then
  printf '  [PASS] cmd_eval: rc=0\n'
else
  printf '  [FAIL] cmd_eval: rc=%d\n' "$rc" >&2
  FAIL=1
fi

if [[ "$out" == *"Trace-level evaluation"* ]]; then
  printf '  [PASS] cmd_eval: header present\n'
else
  printf '  [FAIL] cmd_eval: header missing\n' >&2
  FAIL=1
fi

if [[ "$out" == *"FAILED: 1 of 4"* ]]; then
  printf '  [PASS] cmd_eval: verdict correct (1 of 4 failed)\n'
else
  printf '  [FAIL] cmd_eval: verdict expected "FAILED: 1 of 4", got:\n  %q\n' "$out" >&2
  FAIL=1
fi

if [[ "$out" == *"Per tool:"* ]]; then
  printf '  [PASS] cmd_eval: per-tool section present\n'
else
  printf '  [FAIL] cmd_eval: per-tool section missing\n' >&2
  FAIL=1
fi

if [[ "$out" == *"read_file:"* && "$out" == *"bash:"* ]]; then
  printf '  [PASS] cmd_eval: both tools in the per-tool report\n'
else
  printf '  [FAIL] cmd_eval: tools missing from the per-tool report\n' >&2
  FAIL=1
fi

# ============================================================================
# 5. cmd_eval: empty file
# ============================================================================
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

# ============================================================================
# 6. cmd_eval: missing file
# ============================================================================
printf '  [INFO] cmd_eval (missing file)\n'
out="$(cmd_eval "$TMP/nonexistent.jsonl" 2>&1)"
rc=$?
if (( rc == 0 )) && [[ "$out" == *"No span log found"* ]]; then
  printf '  [PASS] cmd_eval: missing file\n'
else
  printf '  [FAIL] cmd_eval: missing file (rc=%d)\n' "$rc" >&2
  FAIL=1
fi

# ============================================================================
# 7. lex --eval CLI flag
# ============================================================================
printf '  [INFO] lex --eval CLI\n'
out="$(bash "$LEX_DIR/lex" --eval "$SPAN_FILE" 2>&1)"
rc=$?
if (( rc == 0 )); then
  printf '  [PASS] lex --eval: rc=0\n'
else
  printf '  [FAIL] lex --eval: rc=%d\n' "$rc" >&2
  FAIL=1
fi

if [[ "$out" == *"Trace-level evaluation"* ]]; then
  printf '  [PASS] lex --eval: header\n'
else
  printf '  [FAIL] lex --eval: header missing\n' >&2
  FAIL=1
fi

echo ""
if (( FAIL > 0 )); then
  printf 'FAILED: %d test(s) failed\n' "$FAIL" >&2
  exit 1
else
  echo "ALL TESTS GREEN. ✓"
  exit 0
fi
