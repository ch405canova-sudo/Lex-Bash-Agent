#!/usr/bin/env bash
#
# lex/test/test_selfedit.sh — Self-edit sandbox in dispatch_tool (§2, 2026-10-12)
#
# What is checked: an edit whose target is the lex script itself runs on
# a copy, the gates run there, and it is only promoted when green. On red
# the original stays byte-identical. An edit on a foreign target creates
# NO sandbox and runs without delay.
#
# How it is checked: the fixture tree carries stubs in place of the real
# gates, which record their call in $TMP/calls. That proves the wiring
# (gate 2 is invoked exactly under tree/test/run_all.sh, its rc is
# evaluated) without paying the ~82 s of the real suite per run. The
# mechanical fitness of the real suite in a copy was proven 2026-10-12
# (13/13, 896 PASS, 82 s, rc 0) and is in the wiki log.
#
# No port 8080, no real HTTP.
#
set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEX_DIR="$(dirname "$SCRIPT_DIR")"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export TMPDIR="$TMP"          # sandboxes land in the trap-cleared directory
# Review-S6: an exported escape var would make the whole test runner
# falsely red before section 8 sets it itself. Delete it hard here,
# so the test controls its own environment.
unset LEX_SELFEDIT_GATES

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

# Load the script: isolated LEX_HOME (must be $TMP so safe_path accepts the
# sandbox target files), stdin=/dev/null → REPL path aborts.
export LEX_HOME="$TMP"
export LEX_MODEL="$TMP/model.gguf"
source "$LEX_DIR/lex" < /dev/null > /dev/null 2>&1 || {
  echo "FAILURE: $LEX_DIR/lex not loadable (syntax/bash error)" >&2
  exit 1
}

# ── Fixture: repo structure with stubby gates ────────────────────────────────
# Both gates write their call along — the statement: "this gate was called
# at exactly this path". The exit code steers green/red.
FX="$TMP/fixture"
CALLS="$TMP/calls"
mkdir -p "$FX/tools" "$FX/test"
printf 'ORIGINAL_CONTENT\n' > "$FX/lex"    # the script itself — otherwise
                                           # _selfedit_anlegen fails on tree/lex
stub() {  # $1=name $2=rc
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s" >>"%s"\nexit %s\n' \
    "$1" "$CALLS" "$2" > "$FX/$1"
}
G1="tools/selfcheck_lex.sh"
G2="test/run_all.sh"
set_gates() {  # $1=selfcheck-rc $2=run_all-rc
  rm -f "$CALLS"
  stub "$G1" "$1"
  stub "$G2" "$2"
}
gates_ran() {  # call order, e.g. "G1 G2" — or empty if none ran
  [[ -f "$CALLS" ]] || return 0
  tr '\n' ' ' < "$CALLS" | sed 's/ $//'
}

# Correct globals from the source context: at `source` $0 is the TEST
# script, so _lex_script/_lex_repo_dir would otherwise point at the wrong targets.
TARGET="$TMP/target_lex"
_lex_repo_dir="$FX"
_lex_script="$TARGET"

wjson() { jq -n --arg p "$1" --arg c "$2" '{path:$p, content:$c}'; }
ejson() { jq -n --arg p "$1" --arg o "$2" --arg n "$3" '{path:$p, old:$o, new:$n}'; }

# ══ 1. _selfedit_ziel — when does the sandbox apply at all? ══════════════════
set_gates 0 0
_selfedit_ziel write_file "$(wjson "$TARGET" "x")" >/dev/null 2>&1
assert "ziel: write_file on lex → applies" "0" "$?"
_selfedit_ziel edit_file "$(ejson "$TARGET" "a" "b")" >/dev/null 2>&1
assert "ziel: edit_file on lex → applies" "0" "$?"
_selfedit_ziel bash '{"command":"true"}' >/dev/null 2>&1
assert "ziel: bash tool → does NOT apply" "1" "$?"
_selfedit_ziel write_file "$(wjson "$TMP/foreign.txt" "x")" >/dev/null 2>&1
assert "ziel: foreign target → does NOT apply" "1" "$?"
_selfedit_ziel read_file "$(wjson "$TARGET" "x")" >/dev/null 2>&1
assert "ziel: read_file (no write tool) → does NOT apply" "1" "$?"

# ══ 2. _selfedit_anlegen — tree, cleanliness, no .git ════════════════════════
sbx="$(_selfedit_anlegen)"; rc=$?
assert "anlegen: rc" "0" "$rc"
assert "anlegen: tree/lex present" "1" "$([[ -f "$sbx/tree/lex" ]] && echo 1 || echo 0)"
assert "anlegen: tree/test/run_all.sh present" "1" "$([[ -f "$sbx/tree/test/run_all.sh" ]] && echo 1 || echo 0)"
assert "anlegen: .git NOT copied along" "0" "$([[ -e "$sbx/tree/.git" ]] && echo 1 || echo 0)"
assert "anlegen: stdout contains ONLY the path" "1" "$([[ -d "$sbx" ]] && echo 1 || echo 0)"
rm -rf "$sbx"

# ══ 3. Green path through dispatch — promoted, gates ran, cleaned up ═════════
printf 'BEFORE\n' > "$TARGET"
dispatch_tool write_file "$(wjson "$TARGET" "AFTER")" >/dev/null 2>&1
assert "dispatch green: rc" "0" "$?"
assert "dispatch green: content promoted" "AFTER" "$(cat "$TARGET")"
assert "dispatch green: gate 1 ran first" "$G1" "$(gates_ran | cut -d' ' -f1)"
assert "dispatch green: gate 1+2 in order" "$G1 $G2" "$(gates_ran)"
assert "dispatch green: backup created" "1" "$([[ -f "$TMP/lex.bak" ]] && echo 1 || echo 0)"
assert "dispatch green: sandbox removed" "0" \
  "$(find "$TMP" -maxdepth 1 -name 'lex-sbx.*' 2>/dev/null | wc -l)"

# ══ 4. Red path — gate 1 red ⇒ original byte-identical, rc 1 ═════════════════
printf 'BEFORE\n' > "$TARGET"
before="$(sha256sum < "$TARGET")"
set_gates 1 0
out="$(dispatch_tool write_file "$(wjson "$TARGET" "MUST_NOT_PASS")" 2>&1)"; rc=$?
assert "dispatch red: rc" "1" "$rc"
assert "dispatch red: original byte-identical" "$before" "$(sha256sum < "$TARGET")"
assert "dispatch red: content unchanged" "BEFORE" "$(cat "$TARGET")"
assert "dispatch red: finding in tool result" "1" \
  "$([[ "$out" == *"REJECTED"* && "$out" == *"original stays unchanged"* ]] && echo 1 || echo 0)"
assert "dispatch red: sandbox removed" "0" \
  "$(find "$TMP" -maxdepth 1 -name 'lex-sbx.*' 2>/dev/null | wc -l)"

# ══ 5. Red path via gate 2 — run_all rc 1 is evaluated, stop before promotion ═
printf 'BEFORE\n' > "$TARGET"
before="$(sha256sum < "$TARGET")"
set_gates 0 1
out="$(dispatch_tool write_file "$(wjson "$TARGET" "MUST_NOT_EITHER")" 2>&1)"; rc=$?
assert "dispatch red (gate 2): rc" "1" "$rc"
assert "dispatch red (gate 2): original byte-identical" "$before" "$(sha256sum < "$TARGET")"
assert "dispatch red (gate 2): gate 1+2 ran" "$G1 $G2" "$(gates_ran)"
assert "dispatch red (gate 2): finding names gate 2/2" "1" \
  "$([[ "$out" == *"gate 2/2 run_all"* ]] && echo 1 || echo 0)"
rm -rf -- "$TMP"/lex-sbx.* 2>/dev/null || true

# ══ 6. Negative gate — foreign target: no sandbox, no gate, no delay ═════════
set_gates 0 0
dispatch_tool write_file "$(wjson "$TMP/foreign.txt" "FOREIGN")" >/dev/null 2>&1
assert "foreign: rc" "0" "$?"
assert "foreign: content written directly" "FOREIGN" "$(cat "$TMP/foreign.txt")"
assert "foreign: no gate ran" "" "$(gates_ran)"
assert "foreign: no sandbox created" "0" \
  "$(find "$TMP" -maxdepth 1 -name 'lex-sbx.*' 2>/dev/null | wc -l)"

# ══ 7. Escape LEX_SELFEDIT_GATES=fast — only gate 1, warning is explicit ═════
printf 'BEFORE\n' > "$TARGET"
set_gates 0 0
export LEX_SELFEDIT_GATES=fast
out="$(dispatch_tool write_file "$(wjson "$TARGET" "FAST")" 2>&1)"; rc=$?
unset LEX_SELFEDIT_GATES
assert "fast: rc" "0" "$rc"
assert "fast: promoted" "FAST" "$(cat "$TARGET")"
assert "fast: only gate 1 ran" "$G1" "$(gates_ran)"
assert "fast: warning says THE SUITE DID NOT run" "1" \
  "$([[ "$out" == *"THE SUITE DID NOT RUN"* ]] && echo 1 || echo 0)"
assert "fast: promotion NOT \"gates green\" (S4 contradiction)" "0" \
  "$([[ "$out" == *"gates green"* ]] && echo 1 || echo 0)"
assert "fast: promotion names the gap itself" "1" \
  "$([[ "$out" == *"the suite did NOT run"* ]] && echo 1 || echo 0)"

# ══ 8. Escape LEX_SELFEDIT_GATES=off — no check, warning explicit ════════════
printf 'BEFORE\n' > "$TARGET"
set_gates 1 1                       # gates WOULD fall → need not run at all
export LEX_SELFEDIT_GATES=off
out="$(dispatch_tool write_file "$(wjson "$TARGET" "OFF")" 2>&1)"; rc=$?
unset LEX_SELFEDIT_GATES
assert "off: rc" "0" "$rc"
assert "off: promoted" "OFF" "$(cat "$TARGET")"
assert "off: no gate ran" "" "$(gates_ran)"
assert "off: warning says WITHOUT any check" "1" \
  "$([[ "$out" == *"WITHOUT any check"* ]] && echo 1 || echo 0)"
assert "off: promotion NOT \"gates green\" (S4 contradiction)" "0" \
  "$([[ "$out" == *"gates green"* ]] && echo 1 || echo 0)"
assert "off: promotion reports explicitly WITHOUT check" "1" \
  "$([[ "$out" == *"promoted (WITHOUT any check)"* ]] && echo 1 || echo 0)"

# ══ 9. Real copy path — tree of the real repo, runner byte-identical there ═══
# Proves that gate 2 in the sandbox tree really finds the REAL runner
# (not just a stub) — the stub tests above only check the wiring.
_lex_repo_dir="$LEX_DIR"
real_sbx="$(_selfedit_anlegen)"; rc=$?
assert "real: anlegen rc" "0" "$rc"
assert "real: real run_all in the copy" "1" \
  "$([[ -f "$real_sbx/tree/test/run_all.sh" ]] && echo 1 || echo 0)"
assert "real: run_all byte-identical to the original" \
  "$(sha256sum < "$LEX_DIR/test/run_all.sh")" \
  "$(sha256sum < "$real_sbx/tree/test/run_all.sh")"
assert "real: lex in the copy byte-identical to the original" \
  "$(sha256sum < "$LEX_DIR/lex")" "$(sha256sum < "$real_sbx/tree/lex")"
assert "real: no .git copied along" "0" "$([[ -e "$real_sbx/tree/.git" ]] && echo 1 || echo 0)"
rm -rf "$real_sbx"
_lex_repo_dir="$FX"

# ══ 10. Regression B1 — tilde path must NOT bypass the sandbox ═══════════════
# safe_path expands `~` itself (lex:1306), `readlink -f` alone resolves
# `~/target_lex` as `$PWD/~/target_lex`. Without the fix in _selfedit_ziel
# the target check would be rc 1 → no gates, and tool_write_file would then
# have written DIRECTLY to the original via safe_path (review-B1).
printf 'BEFORE\n' > "$TARGET"
set_gates 0 0
HOME_REAL="$HOME"
export HOME="$TMP"                      # so `~/$rel` means exactly $TARGET
# Intentionally LITERAL tilde: the test wants to prove that _selfedit_ziel and
# safe_path expand the tilde THEMSELVES (review-B1). Writing $HOME would
# remove exactly the case under test — hence no correction here.
# Attention shellcheck: the directive binds to the FIRST simple command of the
# next line — hence `_z=1` on its own line before it, otherwise it applies
# to the assignment and the call stays reported (0.11.0, checked).
_z=1
# shellcheck disable=SC2088
_selfedit_ziel write_file "$(wjson "~/target_lex" "x")" >/dev/null 2>&1 && _z=0
export HOME="$HOME_REAL"
assert "B1 tilde: _selfedit_ziel detects ~-path" "0" "$_z"

export HOME="$TMP"
# Literal tilde is the subject under test, see above.
# shellcheck disable=SC2088
dispatch_tool write_file "$(wjson "~/target_lex" "TILDE")" >/dev/null 2>&1; rc=$?
export HOME="$HOME_REAL"
assert "B1 tilde: dispatch rc" "0" "$rc"
assert "B1 tilde: promoted" "TILDE" "$(cat "$TARGET")"
assert "B1 tilde: gates ran (no silent direct access)" "$G1 $G2" "$(gates_ran)"
assert "B1 tilde: sandbox cleared away" "0" \
  "$(find "$TMP" -maxdepth 1 -name 'lex-sbx.*' 2>/dev/null | wc -l)"

# ══ 11. Edit itself failed ⇒ NO gates, original untouched ════════════════════
# The branch `if (( _rc == 0 ))` had no needle at all until now: the sandbox must
# be discarded and the suite skipped when the edit did not even land.
printf 'BEFORE\n' > "$TARGET"
before="$(sha256sum < "$TARGET")"
set_gates 0 0
dispatch_tool edit_file "$(ejson "$TARGET" "DOES_NOT_EXIST_HERE" "something")" >/dev/null 2>&1; rc=$?
assert "_rc!=0: rc" "1" "$rc"
assert "_rc!=0: original byte-identical" "$before" "$(sha256sum < "$TARGET")"
assert "_rc!=0: NO gate ran" "" "$(gates_ran)"
assert "_rc!=0: sandbox discarded" "0" \
  "$(find "$TMP" -maxdepth 1 -name 'lex-sbx.*' 2>/dev/null | wc -l)"

# ══ 12. Sandbox not creatable ⇒ message + original untouched ═════════════════
_ZIEL_A="$_lex_script"; _REPO_A="$_lex_repo_dir"
printf 'BEFORE\n' > "$TARGET"
before="$(sha256sum < "$TARGET")"
set_gates 0 0
_lex_repo_dir="$TMP/doesnotexist"          # without lex/ and test/run_all.sh
out="$(dispatch_tool write_file "$(wjson "$TARGET" "MUST_NOT")" 2>&1)"; rc=$?
_lex_repo_dir="$_REPO_A"
assert "anlegen-fail: rc" "1" "$rc"
assert "anlegen-fail: original byte-identical" "$before" "$(sha256sum < "$TARGET")"
assert "anlegen-fail: message with original hint" "1" \
  "$([[ "$out" == *"original stays unchanged"* ]] && echo 1 || echo 0)"
assert "anlegen-fail: no gate ran" "" "$(gates_ran)"
assert "anlegen-fail: no half-open sandbox" "0" \
  "$(find "$TMP" -maxdepth 1 -name 'lex-sbx.*' 2>/dev/null | wc -l)"
_lex_script="$_ZIEL_A"

# ══ 13. Promotion failed ⇒ rc 1, error message, no success claim ═════════════
# Fixture: the parent directory of the target is a REGULAR FILE → `cp` to
# `$_lex_script.new.$$` fails with ENOTDIR, independent of rights/root.
sbx2="$(_selfedit_anlegen)"; assert "uebernehmen-fail: sandbox creatable" "0" "$?"
printf 'not-a-directory\n' > "$TMP/block"
_lex_script="$TMP/block/lex"             # $TMP/block is a file, not a dir
# Capture stderr here: the deliberate "backup not writable" hint
# (graceful degradation) would only be test noise — we check the stdout message.
out="$(_selfedit_uebernehmen "$sbx2" 2>/dev/null)"; rc=$?
_lex_script="$_ZIEL_A"
assert "uebernehmen-fail: rc" "1" "$rc"
assert "uebernehmen-fail: reports the error" "1" \
  "$([[ "$out" == *"promotion failed"* ]] && echo 1 || echo 0)"
assert "uebernehmen-fail: NO success message next to it" "0" \
  "$([[ "$out" == *"promoted"* ]] && echo 1 || echo 0)"
rm -rf -- "$sbx2"

# ══ 14. Cleanup — no sandbox litter left behind ══════════════════════════════
assert "end: no sandbox directories open" "0" \
  "$(find "$TMP" -maxdepth 1 -name 'lex-sbx.*' 2>/dev/null | wc -l)"

if (( FAIL )); then
  echo "FAILURE: test_selfedit" >&2
  exit 1
fi
echo "test_selfedit: ok"
exit 0
