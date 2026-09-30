#!/usr/bin/env bash
#
# lex/test/run_all.sh — runs every test, exits 0 only when all are green.
#
set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEX_DIR="$(dirname "$SCRIPT_DIR")"
LEX_BIN="$LEX_DIR/lex"

PASS=0
FAIL=0
TOTAL=0

run_test() {
  local name="$1"
  shift
  TOTAL=$((TOTAL + 1))
  if "$@"; then
    PASS=$((PASS + 1))
    printf '  [PASS] %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  [FAIL] %s\n' "$name"
  fi
}

printf 'lex tests\n'
syntax_check() { bash -n "$LEX_BIN" && bash -n "$LEX_DIR/tools/llama-proxy.sh"; }
run_test "syntax"        syntax_check
run_test "input"        "$SCRIPT_DIR/test_input.sh"
run_test "tools"        "$SCRIPT_DIR/test_tools.sh"
run_test "loop"         "$SCRIPT_DIR/test_loop.sh"
run_test "http"         "$SCRIPT_DIR/test_http.sh"
run_test "features"     "$SCRIPT_DIR/test_features.sh"
run_test "proxy"        "$SCRIPT_DIR/test_proxy.sh"
run_test "eval"         "$SCRIPT_DIR/test_eval.sh"

printf '\n%s\n' "===================================="
printf 'PASS: %d  FAIL: %d  TOTAL: %d\n' "$PASS" "$FAIL" "$TOTAL"
printf '====================================\n'

if (( FAIL > 0 )); then
  echo "FAILED: $FAIL test(s) failed." >&2
  exit 1
fi
echo "ALL TESTS GREEN. ✓"
exit 0
