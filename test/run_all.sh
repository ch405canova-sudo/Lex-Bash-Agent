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

# testboden — the suite must never grow quietly silent.
# Found 2026-09-30: a test file was deleted or dropped from the runner list,
# which hid a broken path change in call_api() behind invisible green.
# Checks three directions: every runner named in run_all.sh exists and is
# executable · no test file deleted compared to HEAD · every existing
# test_*.sh really does run.
testboden_check() {
  local ref b f bad missing="" deleted="" orphan=""
  # Only the runner invocations themselves are matched (paths carrying the
  # SCRIPT_DIR prefix) — comments and example names inside this script must
  # not trip the check.
  while IFS= read -r ref; do
    ref="${ref##*/}"
    [[ -f "$SCRIPT_DIR/$ref" && -x "$SCRIPT_DIR/$ref" ]] || missing+=" $ref"
  done < <(grep -oE 'SCRIPT_DIR/test_[a-z_]+\.sh' "$SCRIPT_DIR/run_all.sh" | sort -u)
  for f in "$SCRIPT_DIR"/test_*.sh; do
    [[ -e "$f" ]] || continue
    b="$(basename "$f")"
    grep -qF "$b" "$SCRIPT_DIR/run_all.sh" || orphan+=" $b"
  done
  if git -C "$LEX_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    deleted="$(git -C "$LEX_DIR" diff --name-only --diff-filter=D HEAD -- test/ 2>/dev/null | tr '\n' ' ')"
  fi
  # N9 self-test: the syntax check must not wave through a deliberately
  # broken file (otherwise the wider scope is only a claim).
  bad="$(mktemp)"
  printf 'if true\n' >"$bad"
  if syntax_check "$bad" 2>/dev/null; then
    rm -f "$bad"
    printf '  syntax_check does not catch a broken file (N9)\n'
    return 1
  fi
  rm -f "$bad"
  if [[ -n "$missing$deleted$orphan" ]]; then
    [[ -n "$missing"  ]] && printf '  missing/not executable:%s\n' "$missing"
    [[ -n "$deleted"  ]] && printf '  deleted compared to HEAD:%s\n' "$deleted"
    [[ -n "$orphan"   ]] && printf '  present, but not wired in:%s\n' "$orphan"
    return 1
  fi
  return 0
}

# Syntax check as wide as CLAUDE.md/CI demand (finding N9 2026-10-08:
# before only `lex` + `llama-proxy.sh` — `lurk_watch.sh`, `werkstatt_index.sh`
# and the test files themselves were never syntax-checked locally). Arguments
# overwrite the file list (self-test in the testboden).
syntax_check() {
  local f rc=0
  if (( $# > 0 )); then
    for f in "$@"; do bash -n "$f" || rc=1; done
    return "$rc"
  fi
  bash -n "$LEX_BIN" || rc=1
  for f in "$LEX_DIR"/tools/*.sh "$SCRIPT_DIR"/*.sh; do
    [[ -e "$f" ]] || continue
    bash -n "$f" || rc=1
  done
  return "$rc"
}

run_test "testboden"   testboden_check
run_test "syntax"        syntax_check
run_test "input"        "$SCRIPT_DIR/test_input.sh"
run_test "tools"        "$SCRIPT_DIR/test_tools.sh"
run_test "loop"         "$SCRIPT_DIR/test_loop.sh"
run_test "http"         "$SCRIPT_DIR/test_http.sh"
run_test "features"     "$SCRIPT_DIR/test_features.sh"
run_test "proxy"        "$SCRIPT_DIR/test_proxy.sh"
run_test "sse"          "$SCRIPT_DIR/test_sse.sh"
run_test "eval"         "$SCRIPT_DIR/test_eval.sh"
run_test "limits"       "$SCRIPT_DIR/test_limits.sh"
run_test "compaction"   "$SCRIPT_DIR/test_compaction.sh"
run_test "repetition"   "$SCRIPT_DIR/test_repetition.sh"

printf '\n%s\n' "===================================="
printf 'PASS: %d  FAIL: %d  TOTAL: %d\n' "$PASS" "$FAIL" "$TOTAL"
printf '====================================\n'

if (( FAIL > 0 )); then
  echo "FAILED: $FAIL test(s) failed." >&2
  exit 1
fi
echo "ALL TESTS GREEN. ✓"
exit 0
