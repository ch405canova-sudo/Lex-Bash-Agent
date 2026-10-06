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
if [[ "$out" == *"lex — our own pure-Bash LLM terminal agent"* ]]; then
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

# 5c. /exit and /quit end oneshot WITHOUT a model call
# (review finding 2026-10-01: /exit previously fell through to run_turn — the
# input cost a request and the answer went nowhere.)
out="$(printf '/exit' | LEX_MOCK="done" "$LEX_BIN" --oneshot 2>/dev/null)"
assert "oneshot (/exit without model call)" "" "$out"
rc=0
printf '/exit' | LEX_MOCK="done" "$LEX_BIN" --oneshot >/dev/null 2>&1
rc=$?
if (( rc == 0 )); then
  printf '  [PASS] oneshot (/exit, exit 0)\n'
else
  printf '  [FAIL] oneshot (/exit, exit %s)\n' "$rc" >&2
  FAIL=1
fi
out="$(printf '/quit' | LEX_MOCK="done" "$LEX_BIN" --oneshot 2>/dev/null)"
assert "oneshot (/quit without model call)" "" "$out"
# The same via the pipe path (agent_loop without TTY → oneshot)
out="$(printf '/exit' | LEX_MOCK="done" "$LEX_BIN" 2>/dev/null)"
assert "pipe without flag (/exit without model call)" "" "$out"

# 5d. Real REPL under PTY: /exit ends the session without asking the
# model (monitor: no "Works." from the mock, but a goodbye).
repl_out="$(printf '/exit\n' | LEX_MOCK="done" LEX_HOME="$TMP" \
  timeout 30 script -qec "bash '$LEX_BIN'" /dev/null 2>&1 | tr -d '\r')"
if [[ "$repl_out" == *"Bye!"* ]]; then
  printf '  [PASS] repl (/exit → Bye!, session closed)\n'
else
  printf '  [FAIL] repl (/exit → Bye!): %q\n' "$repl_out" >&2
  FAIL=1
fi
if [[ "$repl_out" != *"Works."* ]]; then
  printf '  [PASS] repl (/exit without model call)\n'
else
  printf '  [FAIL] repl (/exit without model call — the model was asked)\n' >&2
  FAIL=1
fi

# 5e. Prompt guarantee (finding 2026-10-03, user report „after tasks only a
# blinking cursor"): an empty enter must not swallow the prompt.
# Three empty/text inputs → at least 3 prompt lines in the PTY transcript
# (initial + one per input). Before the fix it stayed at 2 (continue skipped
# _prompt).
repl2_out="$(printf '\n\n/exit\n' | LEX_MOCK="done" LEX_HOME="$TMP" \
  timeout 30 script -qec "bash '$LEX_BIN'" /dev/null 2>&1 | tr -d '\r')"
n_prompts="$(printf '%s' "$repl2_out" | grep -o 'lex>' | wc -l | tr -d ' ')"
if (( n_prompts >= 3 )); then
  printf '  [PASS] repl (prompt after empty enter: %s× lex>)\n' "$n_prompts"
else
  printf '  [FAIL] repl (prompt after empty enter — only %s× lex>)\n' "$n_prompts" >&2
  FAIL=1
fi
# Static anchors: both repair spots must remain in the script.
if grep -Fq '[[ -z "$input" ]] && { _spin_stop; _prompt; continue; }' "$LEX_BIN"; then
  printf '  [PASS] repl (anchor: continue path pulls the prompt along)\n'
else
  printf '  [FAIL] repl (anchor: continue path pulls the prompt along)\n' >&2
  FAIL=1
fi
if grep -Fq 'while [[ -f "$_spin_flag" ]]; do' "$LEX_BIN"; then
  printf '  [PASS] repl (anchor: spinner loop has a flag gate)\n'
else
  printf '  [FAIL] repl (anchor: spinner loop has a flag gate)\n' >&2
  FAIL=1
fi

# 5f. Ctrl+C at the prompt (step 51): lex must NOT die. Before the fix
# there was no trap … INT — a single Ctrl+C ended the process (live finding
# 2026-10-05, session 125104). The first press discards only the line,
# /exit finishes cleanly with rc 0.
intlog="$TMP/int_prompt.log"
( sleep 2; printf '\003'; sleep 1; printf '/exit\n' ) | \
  LEX_MOCK="done" LEX_HOME="$TMP" timeout 30 script -qec "bash '$LEX_BIN'" /dev/null > "$intlog" 2>&1
rc=$?
out="$(tr -d '\r' < "$intlog")"
if (( rc == 0 )) && [[ "$out" == *"Bye!"* ]]; then
  printf '  [PASS] repl (Ctrl+C at prompt: REPL lives, /exit rc 0)\n'
else
  printf '  [FAIL] repl (Ctrl+C at prompt: rc=%s Bye=%s)\n' \
    "$rc" "$([[ "$out" == *Bye!* ]] && echo yes || echo no)" >&2
  printf '         output: %q\n' "$out" >&2
  FAIL=1
fi
if [[ "$out" == *"^C"* ]]; then
  printf '  [PASS] repl (Ctrl+C at prompt: ^C in transcript)\n'
else
  printf '  [FAIL] repl (Ctrl+C at prompt: no ^C in transcript)\n' >&2
  FAIL=1
fi

# 5g. Ctrl+C during the tool run (step 51): turn aborted, child dead
# (timeout --foreground, otherwise sleep kept running until tool_timeout:
# 20 s measured), session protocol-conform (tool_call gets an answer),
# REPL lives. Regression without the fix: rc=124 via timeout 30 (child
# runs the full 60 s).
smock="$TMP/int_turn.json"
printf '%s\n' \
  '{"choices":[{"index":0,"message":{"role":"assistant","content":"","tool_calls":[{"id":"tcI","type":"function","function":{"name":"bash","arguments":"{\"command\":\"sleep 60\"}"}}]}}]}' \
  '{"choices":[{"index":0,"message":{"role":"assistant","content":"Done.","tool_calls":[]}}]}' > "$smock"
t0=$SECONDS
( sleep 1; printf 'start\n'; sleep 2; printf '\003'; sleep 1; printf '/exit\n' ) | \
  LEX_MOCK_FILE="$smock" LEX_HOME="$TMP" timeout 30 script -qec "bash '$LEX_BIN'" /dev/null > "$intlog" 2>&1
rc=$?
dauer=$((SECONDS - t0))
out="$(tr -d '\r' < "$intlog")"
if (( rc == 0 )) && [[ "$out" == *"Turn aborted"* ]] && [[ "$out" == *"Bye!"* ]]; then
  printf '  [PASS] repl (Ctrl+C in turn: aborted, REPL lives, rc 0, %ss)\n' "$dauer"
else
  printf '  [FAIL] repl (Ctrl+C in turn: rc=%s duration=%ss)\n' "$rc" "$dauer" >&2
  printf '         output: %q\n' "$out" >&2
  FAIL=1
fi
if (( dauer < 25 )); then
  printf '  [PASS] repl (Ctrl+C in turn: child dead at once — %ss << 60s sleep)\n' "$dauer"
else
  printf '  [FAIL] repl (Ctrl+C in turn: child kept running (%ss — timeout without --foreground?)\n' "$dauer" >&2
  FAIL=1
fi
int_sess="$(ls -t "$TMP"/sessions/*/session.jsonl 2>/dev/null | head -1)"
if [[ -n "$int_sess" ]] && grep -q 'Turn aborted via Ctrl+C' "$int_sess"; then
  printf '  [PASS] repl (Ctrl+C in turn: tool-answer marker in the session)\n'
else
  printf '  [FAIL] repl (Ctrl+C in turn: marker missing in the session)\n' >&2
  FAIL=1
fi

# 5h. Session grant (step 52): at the first sudo ONE y/N question on the
# TTY, afterwards sudo runs in the same session without further questions
# (no y per command — user decision 2026-10-05). Fake sudo in PATH logs
# the calls: exactly 1x "entire session" in the transcript, both sudo
# commands executed (second run WITHOUT a second question).
fakebin="$TMP/fakebin"
mkdir -p "$fakebin"
cat > "$fakebin/sudo" <<'FAKESUDO'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_SUDO_LOG:?}"
if [[ "${1:-}" == "-n" && "${2:-}" == "true" ]]; then exit 0; fi
echo "SUDO-EXECUTED"
exit 0
FAKESUDO
chmod 755 "$fakebin/sudo"
glog="$TMP/fakesudo.log"
: > "$glog"
gmock="$TMP/grant.json"
printf '%s\n' \
  '{"choices":[{"index":0,"message":{"role":"assistant","content":"","tool_calls":[{"id":"tcG","type":"function","function":{"name":"bash","arguments":"{\"command\":\"sudo -n echo SUDO-RAN\"}"}}]}}]}' \
  '{"choices":[{"index":0,"message":{"role":"assistant","content":"First run done.","tool_calls":[]}}]}' \
  '{"choices":[{"index":0,"message":{"role":"assistant","content":"","tool_calls":[{"id":"tcH","type":"function","function":{"name":"bash","arguments":"{\"command\":\"sudo -n echo AGAIN-RAN\"}"}}]}}]}' \
  '{"choices":[{"index":0,"message":{"role":"assistant","content":"Second run done.","tool_calls":[]}}]}' > "$gmock"
( sleep 1; printf 'start\n'; sleep 3; printf 'y\n'; sleep 3; printf 'again\n'; sleep 3; printf '/exit\n' ) | \
  PATH="$fakebin:$PATH" FAKE_SUDO_LOG="$glog" LEX_MOCK_FILE="$gmock" LEX_HOME="$TMP" \
  timeout 40 script -qec "bash '$LEX_BIN'" /dev/null > "$intlog" 2>&1
rc=$?
out="$(tr -d '\r' < "$intlog")"
if (( rc == 0 )) && [[ "$out" == *"Bye!"* ]]; then
  printf '  [PASS] grant (session: y → both sudo runs, rc 0)\n'
else
  printf '  [FAIL] grant: rc=%s Bye!=%s\n' \
    "$rc" "$([[ "$out" == *Bye!* ]] && echo yes || echo no)" >&2
  printf '         output: %q\n' "$out" >&2
  FAIL=1
fi
n_grant="$(printf '%s' "$out" | grep -o 'entire session' | wc -l | tr -d ' ')"
if (( n_grant == 1 )); then
  printf '  [PASS] grant (exactly ONE session question — no y/N per command)\n'
else
  printf '  [FAIL] grant: %sx "entire session" in transcript (expected 1)\n' "$n_grant" >&2
  FAIL=1
fi
if grep -q 'echo SUDO-RAN' "$glog" && grep -q 'echo AGAIN-RAN' "$glog"; then
  printf '  [PASS] grant (second sudo executed without a question)\n'
else
  printf '  [FAIL] grant (fake sudo log incomplete): %s\n' "$(tr '\n' ';' < "$glog")" >&2
  FAIL=1
fi
if [[ "$out" == *"First run done."* ]] && [[ "$out" == *"Second run done."* ]]; then
  printf '  [PASS] grant (both turns visible in the REPL)\n'
else
  printf '  [FAIL] grant (turns missing in transcript)\n' >&2
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
