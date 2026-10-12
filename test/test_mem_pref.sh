#!/usr/bin/env bash
#
# lex/test/test_mem_pref.sh — `_mem_pref_ex` (preferences from mem/ into the
# system prompt). Context LEX.md §7/92: `mem/` was WRITE-ONLY until now, counted
# in /status, but never injected. Six preferences lay still, two
# of them security rules.
# NEVER real requests to 127.0.0.1:8080 — only LEX_MOCK / LEX_MOCK_FILE.
#
# shellcheck disable=SC1090,SC1111,SC2154  # source is loaded via variable;
#                                    # variables from lex are invisible to shellcheck.
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

contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf '  [PASS] %s\n' "$desc"
  else
    printf '  [FAIL] %s\n' "$desc" >&2
    printf '         expected (contains): %q\n' "$needle" >&2
    printf '         actual:              %q\n' "$haystack" >&2
    FAIL=1
  fi
}

notcontains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf '  [PASS] %s\n' "$desc"
  else
    printf '  [FAIL] %s\n' "$desc" >&2
    printf '         must NOT contain: %q\n' "$needle" >&2
    FAIL=1
  fi
}

check() {
  local desc="$1" ok="$2"
  if [[ "$ok" == "1" ]]; then
    printf '  [PASS] %s\n' "$desc"
  else
    printf '  [FAIL] %s\n' "$desc" >&2
    FAIL=1
  fi
}

# --- Fixture: isolated LEX_HOME, stdin=/dev/null (REPL path aborts) ---------
export LEX_HOME="$TMP"
export LEX_MODEL="$TMP/model.gguf"
export LEX_MEM_DIR="$TMP/mem"
export LEX_WIKI_DIR="$TMP/wiki"
export LEX_SESSION=0
source "$LEX_BIN" < /dev/null > /dev/null 2>&1 || {
  echo "FAILURE: $LEX_BIN not loadable (syntax/bash error)" >&2
  exit 1
}
load_config || { echo "FAILURE: load_config" >&2; exit 1; }

mkdir -p "$LEX_MEM_DIR" "$LEX_WIKI_DIR"

# Writes in the format of tool_mem_add — frontmatter like the production store.
mkmem() {  # $1 = filename, $2 = type, $3 = content
  printf -- '---\ndate: 2026-01-03T00:00:00+0200\ntype: %s\nslug: %s\n---\n\n%s\n' \
    "$2" "${1%.md}" "$3" > "$LEX_MEM_DIR/$1"
}

# ══ 1. Base fixture ═════════════════════════════════════════════════════════
# Timestamps rise → `sort -r` must deliver c, b, a.
mkmem "20260103000001-a-older.md"    preference "OLDER preference"
mkmem "20260103000002-b-middle.md"   preference "MIDDLE preference"
mkmem "20260103000003-c-newest.md"   preference "NEWEST preference"
mkmem "20260103000004-d-fact.md"     fact       "FACT_DO_NOT_INJECT"
mkmem "20260103000005-e-memory.md"   memory     "MEMORY_DO_NOT_INJECT"
mkmem "20260103000006-f-note.md"     note       "NOTE_DO_NOT_INJECT"
mkmem "20260103000007-g-ignored.txt" preference "TXT_DO_NOT_INJECT"

# ══ 2. Gates, return value, preference-only ═════════════════════════════════
rc=0; out="$(LEX_MEM_PREF=off _mem_pref_ex)" || rc=$?
assert "gate off: rc" "0" "$rc"
assert "gate off: empty (nothing injected)" "" "$out"

rc=0; out="$(_mem_pref_ex)" || rc=$?
assert "default: rc" "0" "$rc"
contains "default: block header names the store path" "Your preferences" "$out"
contains "default: store path in the header" "$TMP/mem" "$out"

contains "preference-only: fact stays out" "1" \
  "$([[ "$out" == *FACT_DO_NOT_INJECT* ]] && echo 0 || echo 1)"
contains "preference-only: memory stays out" "1" \
  "$([[ "$out" == *MEMORY_DO_NOT_INJECT* ]] && echo 0 || echo 1)"
contains "preference-only: note stays out" "1" \
  "$([[ "$out" == *NOTE_DO_NOT_INJECT* ]] && echo 0 || echo 1)"
contains "non-.md file is ignored" "1" \
  "$([[ "$out" == *TXT_DO_NOT_INJECT* ]] && echo 0 || echo 1)"
contains "all three preferences are in" "3" \
  "$(printf '%s' "$out" | grep -c '^- ')"

# ══ 3. Order and contradiction rule ═════════════════════════════════════════
# The rule IS the purpose of the order — without it two equally-ranking
# preferences neutralize each other (the case of the tone entries 10-02 / 10-09).
contains "contradiction rule stands as text in the block" "NEWEST entry" "$out"

i_c="$(printf '%s' "$out" | grep -b -o 'NEWEST preference' | head -1 | cut -d: -f1)"
i_b="$(printf '%s' "$out" | grep -b -o 'MIDDLE preference' | head -1 | cut -d: -f1)"
i_a="$(printf '%s' "$out" | grep -b -o 'OLDER preference'  | head -1 | cut -d: -f1)"
check "order: newest first (c < b < a in byte offset)" \
  "$([[ -n "$i_c" && -n "$i_b" && -n "$i_a" && "$i_c" -lt "$i_b" && "$i_b" -lt "$i_a" ]] && echo 1 || echo 0)"
check "bullet stands with text on one line (no lone \"- \")" \
  "$(printf '%s' "$out" | grep -cE '^- $' | awk '{print ($1==0)?1:0}')"

# ══ 4. Budgets ══════════════════════════════════════════════════════════════
# Never cut silently — visible marker (same class as §7/89).
out="$(LEX_MEM_PREF_TOTAL=40 _mem_pref_ex)"
contains "total budget: visible truncation marker" "LEX_MEM_PREF_TOTAL reached" "$out"
notcontains "total budget: cut-off preference is missing" "OLDER preference" "$out"

out="$(LEX_MEM_PREF_MAX=12 _mem_pref_ex)"
contains "per-entry budget: visible truncation marker" "truncated — complete under" "$out"

# ══ 5. Exception cases ══════════════════════════════════════════════════════
mkdir -p "$TMP/empty"
_mem_dir="$TMP/empty"
rc=0; out="$(_mem_pref_ex)" || rc=$?
assert "empty directory: rc" "0" "$rc"
assert "empty directory: empty, no empty block" "" "$out"

_mem_dir="$TMP/doesnotexist"
rc=0; out="$(_mem_pref_ex)" || rc=$?
assert "directory missing: rc" "0" "$rc"
assert "directory missing: empty" "" "$out"

# ══ 6. _mem_dir is respected ════════════════════════════════════════════════
mkdir -p "$TMP/mem2"
printf -- '---\ndate: 2026-01-03T00:00:00+0200\ntype: preference\nslug: secondstore\n---\n\nSECONDSTORE preference\n' \
  > "$TMP/mem2/20260103000099-z-secondstore.md"
_mem_dir="$TMP/mem2"
out="$(_mem_pref_ex)"
contains "second store: its preference" "SECONDSTORE preference" "$out"
notcontains "second store: the first store stays out" "NEWEST preference" "$out"

# ══ 7. Integration: setup_messages really injects it ═════════════════════════
# The actual purpose — otherwise the function would just be dead code.
_mem_dir="$TMP/mem"
LEX_SESSION=0 setup_messages >/dev/null 2>&1
sys="$(printf '%s' "$_messages" | jq -r '.[0].content' 2>/dev/null)"
contains "setup_messages: preference lands in the system prompt" "NEWEST preference" "$sys"
contains "setup_messages: contradiction rule lands in the system prompt" "NEWEST entry" "$sys"
notcontains "setup_messages: fact does NOT land in the system prompt" "FACT_DO_NOT_INJECT" "$sys"
contains "setup_messages: order survives the integration" "1" \
  "$([[ "$(printf '%s' "$sys" | grep -b -o 'NEWEST preference' | head -1 | cut -d: -f1)" \
        -lt "$(printf '%s' "$sys" | grep -b -o 'OLDER preference' | head -1 | cut -d: -f1)" ]] && echo 1 || echo 0)"

# ══ 8. stdout is exclusively the block ══════════════════════════════════════
_mem_dir="$TMP/mem"
rc=0; out="$(_mem_pref_ex 2>"$TMP/err")" || rc=$?
assert "rc also with empty stderr" "0" "$rc"
assert "stderr is empty (no noise into prompt building)" "" "$(cat "$TMP/err")"

# ══ 9. Conclusion ═══════════════════════════════════════════════════════════
if (( FAIL )); then
  echo "FAILURE: test_mem_pref" >&2
  exit 1
fi
echo "test_mem_pref: ok"
exit 0
