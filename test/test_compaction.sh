#!/usr/bin/env bash
#
# lex/test/test_compaction.sh — context compaction + context HUD (step 42)
#
# Fixated:
#   1. Inert-by-threshold: with the defaults NOTHING is compacted (the 591
#      old checks keep running unchanged).
#   2. Trigger below a forced threshold (LEX_CTX_LIMIT/LEX_COMPACT_KEEP).
#   3. Fail-safe: empty/broken summary → _messages byte-identical.
#   4. Pairing gate (_pairing_ok), unit grouping, serialize,
#      threshold math — as unit tests over source (pattern test_sse).
#   5. Slash /compact in REPL (PTY) and oneshot, HUD ctx%, config tier.
#
# MOCK/FAKE only — the real llama-server (8080) is never touched.
#
set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEX_DIR="$(dirname "$SCRIPT_DIR")"
LEX_BIN="$LEX_DIR/lex"

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
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
    printf '         text: %q\n' "$hay" >&2
    FAIL=1
  fi
}
not_contains() {
  local desc="$1" needle="$2" hay="$3"
  if [[ "$hay" != *"$needle"* ]]; then
    printf '  [PASS] %s\n' "$desc"
  else
    printf '  [FAIL] %s (must not contain: %q)\n' "$desc" "$needle" >&2
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
# grep -c returns 0 on errors — normalized to a number.
count_of() {   # "pattern" "file"
  local n
  n="$(grep -c -- "$1" "$2" 2>/dev/null || true)"
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  printf '%s' "$n"
}

export LEX_HOME="$TMP/base"
export LEX_MODEL="$TMP/model.gguf"
unset LEX_MOCK LEX_MOCK_FILE LEX_TRACE LEX_CTX_LIMIT LEX_COMPACT \
      LEX_COMPACT_KEEP LEX_COMPACT_BUFFER LEX_MAX_TOKENS 2>/dev/null || true

echo ""
echo "[INFO] static checks (source anchors)"

# The run hook MUST sit before the user-append (the only safe point).
hook_line="$(grep -n '^\s*_compact_run$' "$LEX_BIN" | head -1 | cut -d: -f1)"
append_line="$(grep -n 'append_message "user" "\$input"' "$LEX_BIN" | head -1 | cut -d: -f1)"
check "source (_compact_run before user-append)" \
  "$([[ -n "$hook_line" && -n "$append_line" && "$hook_line" -lt "$append_line" ]] && echo 1 || echo 0)"
check "source (G6 gate on the swap path)" \
  "$(grep -qF '_pairing_ok <<< "$new"' "$LEX_BIN" && echo 1 || echo 0)"
check "source (_msg_override in call_api)" \
  "$(grep -qF '${_msg_override:-${_messages:-}}' "$LEX_BIN" && echo 1 || echo 0)"
check "source (_tools_off in _build_tools)" \
  "$(grep -qF '_tools_off:-}' "$LEX_BIN" && echo 1 || echo 0)"
help_out="$(LEX_MOCK="done" "$LEX_BIN" --help 2>&1)"
contains "help (mentions /compact)" "/compact" "$help_out"
contains "help (mentions LEX_COMPACT env)" "LEX_COMPACT" "$help_out"

echo "[INFO] config tier + /status"
st="$(LEX_MOCK="done" "$LEX_BIN" --status 2>&1)"
contains "status (compact line default)" "compact   : on · threshold 242144 · keep 15000 · buffer 20000" "$st"
contains "status (ctx line default)" "ctx       : ?/262144" "$st"
st2="$(LEX_MOCK="done" LEX_CTX_LIMIT=50000 LEX_COMPACT_KEEP=1234 LEX_COMPACT=off "$LEX_BIN" --status 2>&1)"
contains "status (ENV ctx 50000 → threshold 30000)" "threshold 30000" "$st2"
contains "status (ENV keep 1234)" "keep 1234" "$st2"
contains "status (ENV compact off)" "compact   : off" "$st2"
st3="$(LEX_MOCK="done" LEX_CTX_LIMIT=xyz LEX_COMPACT_KEEP=abc LEX_COMPACT=vielleicht "$LEX_BIN" --status 2>&1)"
contains "status (broken ctx → default threshold)" "threshold 242144" "$st3"
contains "status (broken keep → 15000)" "keep 15000" "$st3"
contains "status (broken compact → on)" "compact   : on" "$st3"

echo "[INFO] inert: defaults trigger NO compaction"
out="$(LEX_MOCK="done" "$LEX_BIN" --oneshot <<< 'hello' 2>"$TMP/inert.err")"
assert "inert (answer)" "Works." "$out"
not_contains "inert (no 🗜 message)" "compacted" "$(cat "$TMP/inert.err")"
rec="$(grep -h '"type":"compaction"' "$LEX_HOME"/sessions/*/session.jsonl 2>/dev/null | wc -l | tr -d ' ')"
assert "inert (no compaction record)" "0" "$rec"

echo "[INFO] /compact force (oneshot, empty context)"
rc=0
out="$(LEX_MOCK="done" "$LEX_BIN" --oneshot <<< '/compact' 2>"$TMP/force.err")" || rc=$?
assert "force (rc)" "0" "$rc"
contains "force (message)" "Nothing to compact" "$(cat "$TMP/force.err")"

echo "[INFO] /compact force (REPL under PTY)"
repl_out="$(printf '/compact\n/exit\n' | LEX_MOCK="done" \
  timeout 30 script -qec "bash '$LEX_BIN'" /dev/null 2>&1 | tr -d '\r')"
contains "pty /compact (message)" "Nothing to compact" "$repl_out"
contains "pty /compact (Bye)" "Bye" "$repl_out"
not_contains "pty /compact (no model call)" "Works." "$repl_out"

echo "[INFO] auto trigger below a forced threshold (PTY, 2 turns)"
export LEX_HOME="$TMP/trig"
export LEX_MOCK="done" LEX_CTX_LIMIT=100 LEX_COMPACT_KEEP=10 LEX_TRACE=1
trig_out="$(printf 'This is a longer first question with plenty of content so that the head measurably grows and the summary can replace it, please go ahead.\nThe second question after the first one: does the swap go through cleanly?\n/exit\n' \
  | timeout 30 script -qec "bash '$LEX_BIN'" /dev/null 2>&1 | tr -d '\r')"
unset LEX_MOCK LEX_CTX_LIMIT LEX_COMPACT_KEEP LEX_TRACE
contains "trigger (🗜 message)" "Context compacted" "$trig_out"
sfile="$(ls "$LEX_HOME"/sessions/*/session.jsonl 2>/dev/null | head -1)"
check "trigger (session.jsonl exists)" "$([[ -s "$sfile" ]] && echo 1 || echo 0)"
rec="$(grep -h '"type":"compaction"' "$sfile" 2>/dev/null | head -1)"
contains "trigger (record type)" '"type":"compaction"' "$rec"
if jq -e '.type == "compaction" and (.estimate_before > 0) and (.kept_units >= 1)
          and (.estimate_after > 0) and (.summary_chars > 0)' \
       >/dev/null 2>&1 <<< "$rec"; then
  printf '  [PASS] trigger (record fields plausible)\n'
else
  printf '  [FAIL] trigger (record fields plausible): %s\n' "$rec" >&2; FAIL=1
fi
contains "trigger (both turns answered)" "Works." "$trig_out"
c_count="$(grep -c 'Context compacted' <<< "$trig_out" 2>/dev/null || true)"
[[ "$c_count" =~ ^[0-9]+$ ]] || c_count=0
check "trigger (exactly ONE compaction)" "$([[ "$c_count" == "1" ]] && echo 1 || echo 0)"
logc="$(count_of 'compact: ~' "$LEX_HOME/log/lex.log")"
check "trigger (log line written)" "$([[ "$logc" -ge 1 ]] && echo 1 || echo 0)"

echo "[INFO] fail-safe: empty summary (PTY + mock file)"
export LEX_HOME="$TMP/failsafe"
mf="$TMP/failsafe_mock.jsonl"
printf '%s\n%s\n%s\n' \
  '{"choices":[{"index":0,"message":{"role":"assistant","content":"First answer ok.","tool_calls":[]},"finish_reason":"stop"}]}' \
  '{"choices":[{"index":0,"message":{"role":"assistant","content":"","tool_calls":[]},"finish_reason":"stop"}]}' \
  '{"choices":[{"index":0,"message":{"role":"assistant","content":"Second answer despite the error.","tool_calls":[]},"finish_reason":"stop"}]}' \
  > "$mf"
export LEX_MOCK_FILE="$mf" LEX_CTX_LIMIT=100 LEX_COMPACT_KEEP=10 LEX_TRACE=1
fs_out="$(printf 'Longer first question with enough content so that the head plays a role on the swap and should be replaced, please go ahead.\nSecond question after the failed swap — does the answer still run?\n/exit\n' \
  | timeout 30 script -qec "bash '$LEX_BIN'" /dev/null 2>&1 | tr -d '\r')"
unset LEX_MOCK_FILE LEX_CTX_LIMIT LEX_COMPACT_KEEP LEX_TRACE
contains "failsafe (clear message)" "returned no content" "$fs_out"
sfile="$(ls "$LEX_HOME"/sessions/*/session.jsonl 2>/dev/null | head -1)"
rec="$(grep -h '"type":"compaction"' "$sfile" 2>/dev/null | wc -l | tr -d ' ')"
assert "failsafe (NO compaction record)" "0" "$rec"
contains "failsafe (turn 2 continues)" "Second answer despite the error." "$fs_out"
not_contains "failsafe (no 🗜)" "Context compacted" "$fs_out"
logc="$(count_of 'empty summary' "$LEX_HOME/log/lex.log")"
check "failsafe (log: empty summary)" "$([[ "$logc" -ge 1 ]] && echo 1 || echo 0)"

echo "[INFO] unit tests (source, pattern test_sse)"
export LEX_HOME="$TMP/units"
export LEX_MODEL="$TMP/model.gguf"
mkdir -p "$LEX_HOME"
mf2="$TMP/units_mock.jsonl"
printf '%s\n%s\n%s\n%s\n' \
  '{"choices":[{"index":0,"message":{"role":"assistant","content":"## Goal\n- Summary from mock.","tool_calls":[]},"finish_reason":"stop"}]}' \
  '{"choices":[{"index":0,"message":{"role":"assistant","content":"","tool_calls":[]},"finish_reason":"stop"}]}' \
  '{"choices":[{"index":0,"message":{"role":"assistant","content":"## Goal\n- Second summary.","tool_calls":[]},"finish_reason":"stop"}]}' \
  '{"choices":[{"index":0,"message":{"role":"assistant","content":"## Goal\n- Third summary after auto.","tool_calls":[]},"finish_reason":"stop"}]}' \
  > "$mf2"
export LEX_MOCK_FILE="$mf2"
source "$LEX_DIR/lex" < /dev/null > /dev/null 2>&1 || {
  echo "FAILED: $LEX_DIR/lex not loadable" >&2
  exit 1
}

# Audit gap 2026-10-08: the source anchor above only checks the keyword
# `_tools_off:-}` — the BODY was never checked. Functional here, after the
# source: the compaction's summary request must deliver EXACTLY [], the
# normal request must contain the tool schemas.
tb_on="$(_build_tools)"
_tools_off=1
tb_off="$(_build_tools)"
_tools_off=""
assert "tools_off (summary request exactly [])" "[]" "$tb_off"
contains "tools_off (normal request contains tools)" '"name": "browser"' "$tb_on"

# --- _pairing_ok -----------------------------------------------------------
pair_ok='[{"role":"system","content":"s"},{"role":"user","content":"u"},{"role":"assistant","content":"a"}]'
_pairing_ok <<< "$pair_ok" >/dev/null 2>&1 && check "pairing (valid) " 1 || check "pairing (valid)" 0
bad1='[{"role":"system","content":"s"},{"role":"assistant","content":"a","tool_calls":[{"id":"c1","type":"function","function":{"name":"bash","arguments":"{}"}}]},{"role":"tool","tool_call_id":"c9","content":"x"}]'
_pairing_ok <<< "$bad1" >/dev/null 2>&1 && check "pairing (tool without call → 1)" 0 || check "pairing (tool without call → 1)" 1
bad2='[{"role":"system","content":"s"},{"role":"user","content":"u"},{"role":"assistant","content":"","tool_calls":[{"id":"c1","type":"function","function":{"name":"bash","arguments":"{}"}}]}]'
_pairing_ok <<< "$bad2" >/dev/null 2>&1 && check "pairing (open tool_calls at the end → 1)" 0 || check "pairing (open tool_calls at the end → 1)" 1
nudge='[{"role":"system","content":"s"},{"role":"assistant","content":"","tool_calls":[{"id":"c1","type":"function","function":{"name":"bash","arguments":"{}"}}]},{"role":"user","content":"nudge"},{"role":"assistant","content":"done"}]'
_pairing_ok <<< "$nudge" >/dev/null 2>&1 && check "pairing (nudge case allowed)" 1 || check "pairing (nudge case allowed)" 0
answered='[{"role":"system","content":"s"},{"role":"assistant","content":"","tool_calls":[{"id":"c1","type":"function","function":{"name":"bash","arguments":"{}"}}]},{"role":"tool","tool_call_id":"c1","content":"ok"}]'
_pairing_ok <<< "$answered" >/dev/null 2>&1 && check "pairing (answered pair)" 1 || check "pairing (answered pair)" 0
check "pairing (too short → 1)" "$(_pairing_ok <<< '[{"role":"system","content":"s"}]' >/dev/null 2>&1; echo $?)"
dbl='[{"role":"system","content":"s"},{"role":"assistant","content":"","tool_calls":[{"id":"c1","type":"function","function":{"name":"bash","arguments":"{}"}}]},{"role":"tool","tool_call_id":"c1","content":"a"},{"role":"tool","tool_call_id":"c1","content":"b"}]'
_pairing_ok <<< "$dbl" >/dev/null 2>&1 && check "pairing (double answer → 1)" 0 || check "pairing (double answer → 1)" 1

# --- _compact_units --------------------------------------------------------
units_in='[{"role":"user","content":"question"},{"role":"assistant","content":"","tool_calls":[{"id":"c1","type":"function","function":{"name":"bash","arguments":"{}"}}]},{"role":"tool","tool_call_id":"c1","content":"r1"},{"role":"tool","tool_call_id":"c2","content":"r2"},{"role":"assistant","content":"done"}]'
units_out="$(printf '%s' "$units_in" | _compact_units)"
assert "units (3 units, pair=1..3)" \
  '[{"s":0,"e":0,"k":"user"},{"s":1,"e":3,"k":"pair"},{"s":4,"e":4,"k":"assistant"}]' \
  "$units_out"

# --- _compact_threshold ----------------------------------------------------
_ctx_limit=262144 _max_tokens=16384 _compact_buffer=20000
assert "threshold (default 242144)" "242144" "$(_compact_threshold)"
_ctx_limit=0
assert "threshold (ctx 0 → 0)" "0" "$(_compact_threshold)"
_ctx_limit=262144 _max_tokens=30000
assert "threshold (out > buffer)" "232144" "$(_compact_threshold)"

# --- _compact_estimate -----------------------------------------------------
assert "estimate (400 bytes → 133)" "133" "$(_compact_estimate "$(printf 'x%.0s' {1..400})")"

# --- _compact_serialize ----------------------------------------------------
ser="$(_compact_serialize "$units_in" 2000)"
contains "serialize ([User])" "[User]: question" "$ser"
contains "serialize ([Model])" "[Model]: done" "$ser"
contains "serialize ([Tool call])" "[Tool call]: bash({})" "$ser"
contains "serialize ([Tool result])" "[Tool result]: r1" "$ser"
big_tool="$(jq -cn --arg c "$(printf 'y%.0s' {1..3000})" '[{"role":"system","content":"s"},{"role":"tool","tool_call_id":"c1","content":$c}]')"
ser2="$(_compact_serialize "$big_tool" 2000)"
contains "serialize (shortening > 2000 → [truncated])" "[truncated]" "$ser2"

# --- _compact_run: force-Swap --------------------------------------------
_ctx_limit=100 _max_tokens=16384 _compact_buffer=20000 _compact_keep=10
_compact=on _compact_count=0 _turn_count=7
_messages="$(jq -cn '[{role:"system",content:"SYS-PROMPT-VERY-LONG"},
  {role:"user",content:"A longer first question with plenty of content so that the head measurably grows and clearly has to be replaced."},
  {role:"assistant",content:"Answer one."}]')"
tc_before="$_turn_count"
_compact_run force; rc=$?
assert "swap (rc 0)" "0" "$rc"
assert "swap (turn_count unchanged)" "$tc_before" "$_turn_count"
assert "swap (count +1)" "1" "$_compact_count"
slot1="$(jq -r '.[1].content' <<< "$_messages" 2>/dev/null)"
contains "swap (marker in slot 1)" "<!--lex-compact-->" "$slot1"
check "swap (pairing_ok after the swap)" "$(_pairing_ok <<< "$_messages" >/dev/null 2>&1 && echo 1 || echo 0)"
assert "swap (length 3 = sys+summary+tail)" "3" "$(jq 'length' <<< "$_messages")"
assert "swap (system unchanged)" "system" "$(jq -r '.[0].role' <<< "$_messages")"
contains "swap (summary content inside)" "Summary from mock" "$slot1"
logc="$(count_of 'compact: ~' "$LEX_HOME/log/lex.log")"
check "swap (log written)" "$([[ "$logc" -ge 1 ]] && echo 1 || echo 0)"
spanc="$(count_of '"name":"compact"' "$LEX_HOME/log/spans.jsonl")"
check "swap (span written)" "$([[ "$spanc" -ge 1 ]] && echo 1 || echo 0)"

# --- G4: empty summary → _messages byte-identical ------------------------
# Enrich first: without a head, force would stop at G2 before the call.
append_message user "Interim question with a bit more text so that on the next force attempt a head is guaranteed to exist."
append_message assistant "Interim answer."
snap="$(md5sum <<< "$_messages" | cut -d' ' -f1)"
_compact=on _compact_run force; rc=$?
assert "G4 (rc 1 for empty summary)" "1" "$rc"
assert "G4 (_messages byte-identical)" "$snap" "$(md5sum <<< "$_messages" | cut -d' ' -f1)"
assert "G4 (count unchanged)" "1" "$_compact_count"

# --- second compaction: prior summary is replaced, never stacked ----------
append_message user "Second round: continue with the plan, the undertaking is not finished yet and needs more context."
append_message assistant "Done — second answer is ready."
_compact_run force; rc=$?
assert "recompact (rc 0)" "0" "$rc"
assert "recompact (count 2)" "2" "$_compact_count"
markers="$(grep -o '<!--lex-compact-->' <<< "$_messages" | wc -l | tr -d ' ')"
assert "recompact (exactly ONE marker)" "1" "$markers"
contains "recompact (marker stays in slot 1)" "<!--lex-compact-->" "$(jq -r '.[1].content' <<< "$_messages" | head -c 40)"
check "recompact (pairing_ok)" "$(_pairing_ok <<< "$_messages" >/dev/null 2>&1 && echo 1 || echo 0)"
assert "recompact (slot 0 stays system)" "system" "$(jq -r '.[0].role' <<< "$_messages")"

# --- auto path: LEX_COMPACT=off saves, force still works -------------------
# Enrich the state so the auto path really has something to do.
append_message user "Third round: now I need more context again, please summarize once more and continue."
append_message assistant "Done — third answer is ready."
snap="$(md5sum <<< "$_messages" | cut -d' ' -f1)"
_compact=off
_compact_run; rc=$?
assert "off (auto rc 0, nothing happens)" "0" "$rc"
assert "off (_messages unchanged)" "$snap" "$(md5sum <<< "$_messages" | cut -d' ' -f1)"
assert "off (count unchanged)" "2" "$_compact_count"
_compact=on
_compact_run; rc=$?
check "off (auto with on → swap)" "$([[ "$rc" == "0" && "$_compact_count" == "3" ]] && echo 1 || echo 0)"

# --- HUD ctx% (functional) ------------------------------------------------
export LEX_TRACE=1
_ctx_limit=262144 _last_prompt_tokens=65536 _last_completion_tokens=42
hud="$({ _trace_hud 0; } 2>&1)"
contains "hud (ctx 65536/262144 = 25%)" "tokens 65536/262144 (25%) prompt + 42 completion" "$hud"
_ctx_limit=0
_last_prompt_tokens=999
hud2="$({ _trace_hud 0; } 2>&1)"
contains "hud (without limit → old formula)" "tokens 999 prompt + 42 completion" "$hud2"
_ctx_limit=262144 _last_prompt_tokens=""
hud3="$({ _trace_hud 0; } 2>&1)"
contains "hud (without usage → ?/limit)" "tokens ?/262144 prompt" "$hud3"
unset LEX_TRACE

echo ""
if (( FAIL > 0 )); then
  printf 'FAILED: %s test(s) in test_compaction.sh\n' "$FAIL" >&2
  exit 1
fi
echo "test_compaction.sh green. ✓"
exit 0
