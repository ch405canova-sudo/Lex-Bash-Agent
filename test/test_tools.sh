#!/usr/bin/env bash
#
# lex/test/test_tools.sh — the 5 tools + safe_path + dispatch (called directly as functions).
# The script is loaded via source (stdin=/dev/null → the REPL path exits immediately).
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

# Load the script: env variant LEX_HOME (isolation) + LEX_MODEL, stdin=/dev/null
export LEX_HOME="$TMP"
export LEX_MODEL="$TMP/model.gguf"
source "$LEX_DIR/lex" < /dev/null > /dev/null 2>&1 || {
  echo "FAILED: $LEX_DIR/lex not loadable (syntax/bash error)" >&2
  exit 1
}

# 8. safe_path: a normal file under LEX_HOME is allowed
res="$(safe_path "$TMP/file.txt")"
assert "safe_path (allowed)" "$TMP/file.txt" "$res"

# 9. safe_path: deny list (e.g. /etc/passwd) is refused (error path in our
#    own TMP, not a shared /tmp path)
safe_path /etc/passwd >/dev/null 2>"$TMP/safe_err"
err="$(cat "$TMP/safe_err")"
if [[ "$err" == *"is not allowed"* ]]; then
  printf '  [PASS] safe_path (deny list)\n'
else
  printf '  [FAIL] safe_path (deny list): %q\n' "$err" >&2
  FAIL=1
fi

# 10. tool_write_file: writes a file, creates directories
tool_write_file "$TMP/a/b/c.txt" "Hello world" >/dev/null 2>&1
content="$(cat "$TMP/a/b/c.txt")"
assert "write_file (content + directory)" "Hello world" "$content"

# 11. tool_read_file: reads the written file
content="$(tool_read_file "$TMP/a/b/c.txt")"
assert "read_file" "Hello world" "$content"

# 12. tool_read_file: missing file → error + exit 1
tool_read_file "$TMP/missing.txt" >/dev/null 2>&1
rc=$?
if (( rc != 0 )); then
  printf '  [PASS] read_file (missing file)\n'
else
  printf '  [FAIL] read_file (missing file)\n' >&2
  FAIL=1
fi

# 12b. tool_read_file: output cap (E2BIG protection, step 17b)
big="$TMP/big.txt"
: > "$big"
i=0; while (( i < 40 )); do printf 'aaaaaaaaaa\n' >> "$big"; i=$((i + 1)); done
_tool_max_output=5
out="$(tool_read_file "$big")"
_tool_max_output=50000
if [[ "$out" == aaaaa* && "$out" == *"truncated"*"bytes total"* ]]; then
  printf '  [PASS] read_file (cap + byte count)\n'
else
  printf '  [FAIL] read_file (cap): %q\n' "$out" >&2
  FAIL=1
fi

# 13. tool_edit_file: replaces the first occurrence
printf 'before old after\n' > "$TMP/e.txt"
tool_edit_file "$TMP/e.txt" "old" "new" >/dev/null 2>&1
content="$(cat "$TMP/e.txt")"
assert "edit_file" "before new after" "$content"

# 14. tool_edit_file: search text not found → exit 1
tool_edit_file "$TMP/e.txt" "nope" "x" >/dev/null 2>&1
rc=$?
if (( rc != 0 )); then
  printf '  [PASS] edit_file (search text missing)\n'
else
  printf '  [FAIL] edit_file (search text missing)\n' >&2
  FAIL=1
fi

# 15. tool_bash: successful command
out="$(tool_bash "echo Hello")"
assert "bash (success)" "Hello" "$out"

# 16. tool_bash: error exit code
out="$(tool_bash "false")"
if [[ "$out" == *"Exit code: 1"* ]]; then
  printf '  [PASS] bash (error)\n'
else
  printf '  [FAIL] bash (error): %q\n' "$out" >&2
  FAIL=1
fi

# 17. tool_bash: stdin is ignored (</dev/null) — otherwise `cat`/`read` hangs on the terminal
out="$(printf 'x\n' | tool_bash "cat")"
assert "bash (ignores stdin)" "" "$out"

# 18. tool_bash: truncation note with a real line break (no literal \n)
_tool_max_output=5
out="$(tool_bash "printf 'aaaaaaaaaa'")"
_tool_max_output=50000
assert "bash (truncation line break)" $'aaaaa\n... (truncated, 10 bytes total)' "$out"

# 19. tool_list_files: existing directory
out="$(tool_list_files "$TMP/a/b" 2>/dev/null)"
if [[ "$out" == *"c.txt"* ]]; then
  printf '  [PASS] list_files\n'
else
  printf '  [FAIL] list_files\n' >&2
  FAIL=1
fi

# 20. tool_list_files: missing directory → exit 1
tool_list_files "$TMP/broken" >/dev/null 2>&1
rc=$?
if (( rc != 0 )); then
  printf '  [PASS] list_files (missing directory)\n'
else
  printf '  [FAIL] list_files (missing directory)\n' >&2
  FAIL=1
fi

# 21. dispatch_tool: read_file via JSON args
args="$(jq -n --arg p "$TMP/a/b/c.txt" '{"path":$p}')"
out="$(dispatch_tool "read_file" "$args")"
assert "dispatch (read_file)" "Hello world" "$out"

# 22. dispatch_tool: unknown tool → exit 1
dispatch_tool "does_not_exist" '{}' >/dev/null 2>&1
rc=$?
if (( rc != 0 )); then
  printf '  [PASS] dispatch (unknown tool)\n'
else
  printf '  [FAIL] dispatch (unknown tool)\n' >&2
  FAIL=1
fi

if (( FAIL > 0 )); then
  echo "FAILED: $FAIL test(s) in test_tools.sh" >&2
  exit 1
fi
echo "test_tools.sh green. ✓"
exit 0
