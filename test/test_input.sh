#!/usr/bin/env bash
#
# lex/test/test_input.sh — CLI modes: version, help, oneshot, unknown command.
# Every test runs with LEX_MOCK / LEX_MOCK_FILE — NEVER against 127.0.0.1:8080.
#
set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEX_DIR="$(dirname "$SCRIPT_DIR")"
LEX_BIN="$LEX_DIR/lex"

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

# Load/isolate the script: LEX_HOME points into TMP, otherwise the test
# writes sessions and mock shadows into the real ~/.lex (isolation bug 2026-09-28).
export LEX_HOME="$TMP"

# 1. --version
assert "version" "lex 0.1.0" "$("$LEX_BIN" --version)"

# 2. --help
out="$("$LEX_BIN" --help 2>&1)"
if [[ "$out" == *"lex — a pure-Bash LLM terminal agent"* ]]; then
  printf '  [PASS] help\n'
else
  printf '  [FAIL] help\n' >&2
  FAIL=1
fi

# 3. Unknown command → error on stderr + exit 1
out="$("$LEX_BIN" --wrong 2>&1 1>/dev/null)"
rc=0
"$LEX_BIN" --wrong >/dev/null 2>&1
rc=$?
if [[ "$out" == *"Unknown command: --wrong"* ]]; then
  printf '  [PASS] unknown command (error message)\n'
else
  printf '  [FAIL] unknown command (error message): %q\n' "$out" >&2
  FAIL=1
fi
if (( rc == 1 )); then
  printf '  [PASS] unknown command (exit 1)\n'
else
  printf '  [FAIL] unknown command (exit %s)\n' "$rc" >&2
  FAIL=1
fi

# 4. --oneshot with LEX_MOCK=done
out="$(echo 'Say hello' | LEX_MOCK="done" "$LEX_BIN" --oneshot 2>/dev/null)"
assert "oneshot (mock)" "Works." "$out"

# 5. --oneshot with empty input → no output, exit 0
out="$(printf '' | LEX_MOCK="done" "$LEX_BIN" --oneshot 2>/dev/null)"
rc=0
printf '' | LEX_MOCK="done" "$LEX_BIN" --oneshot >/dev/null 2>&1
rc=$?
assert "oneshot (empty input)" "" "$out"
if (( rc == 0 )); then
  printf '  [PASS] oneshot (empty input, exit 0)\n'
else
  printf '  [FAIL] oneshot (empty input, exit %s)\n' "$rc" >&2
  FAIL=1
fi

# 5b. WITHOUT --oneshot, but without a TTY (pipe): agent_loop evaluates
# like oneshot (P3, review 2026-09-29) — otherwise `echo … | lex` would
# swallow the input silently.
out="$(echo 'Say hello' | LEX_MOCK="done" "$LEX_BIN" 2>/dev/null)"
assert "pipe without flag (non-TTY → oneshot)" "Works." "$out"
rc=0
printf '' | LEX_MOCK="done" "$LEX_BIN" >/dev/null 2>&1
rc=$?
if (( rc == 0 )); then
  printf '  [PASS] pipe without flag (empty input, exit 0)\n'
else
  printf '  [FAIL] pipe without flag (empty input, exit %s)\n' "$rc" >&2
  FAIL=1
fi

# 6. LEX_MOCK_FILE: first line is emitted
mock="$TMP/mock.json"
printf '%s\n' '{"choices":[{"index":0,"message":{"role":"assistant","content":"From file."}}]}' > "$mock"
out="$(echo 'Test' | LEX_MOCK_FILE="$mock" "$LEX_BIN" --oneshot 2>/dev/null)"
assert "mock-file (first line)" "From file." "$out"

# 7. LEX_MOCK_FILE is consumed: each line = one API answer
printf '%s\n%s\n' \
  '{"choices":[{"index":0,"message":{"role":"assistant","content":"First."}}]}' \
  '{"choices":[{"index":0,"message":{"role":"assistant","content":"Second."}}]}' > "$mock"
out="$(echo 'Test' | LEX_MOCK_FILE="$mock" "$LEX_BIN" --oneshot 2>/dev/null)"
assert "mock-file (1st answer)" "First." "$out"
out="$(echo 'Test' | LEX_MOCK_FILE="$mock" "$LEX_BIN" --oneshot 2>/dev/null)"
assert "mock-file (2nd answer)" "Second." "$out"

if (( FAIL > 0 )); then
  echo "FAILED: $FAIL test(s) in test_input.sh" >&2
  exit 1
fi
echo "test_input.sh green. ✓"
exit 0
