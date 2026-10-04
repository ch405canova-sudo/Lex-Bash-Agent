#!/usr/bin/env bash
#
# lex/test/test_repetition.sh — repetition/loop detection (concept V1).
#
# Finding 2026-10-03 (wiki/errors/2026-10-03-generierungs-loop-abwaegung.md):
# the model ran into a sentence-repetition loop (finish=stop, content not
# empty), the nudge chain in run_turn did not catch that, the loop was
# rendered unchanged. Built: _rep_detect (A1 trailing run, A2 sentence loop,
# A3 rep-4) before the render, nudge B1/B2 against the existing _max_nudges
# budget, truncation render after it, session record type:repetition.
#
# What is checked:
#   1. detector unit tests: real case loop → A2, word loop → A1,
#      varied 4-gram loop → A3
#   2. false-positive gates: lexpen table, code block, normal prose,
#      short sentence ×3 — NO finding
#   3. integration run_turn over the mock queue: soft nudge → hard
#      nudge → truncation after the budget, _messages grows, session records
#   4. static anchors: hook exists, checks ONLY $content (never reasoning),
#      truncation render exists
#
# LEX_MOCK_FILE only (file queue) — the real llama-server (8080) is
# never touched.
#
# shellcheck disable=SC2154  # _messages/_mock_file/_system_prompt come from the loaded lex
set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEX_DIR="$(dirname "$SCRIPT_DIR")"

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
    printf '         text (start): %q\n' "${hay:0:200}" >&2
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
check() {
  local desc="$1" ok="$2"
  if [[ "$ok" == "1" ]]; then
    printf '  [PASS] %s\n' "$desc"
  else
    printf '  [FAIL] %s\n' "$desc" >&2
    FAIL=1
  fi
}

# ===========================================================================
# Fixtures — the REAL loop case from session 20261003-162738 (2912 bytes,
# "I will think it over again" and similar ~15×; content of the assistant
# turn of 2026-10-03 16:53).
# ===========================================================================
FIXTURE_TXT="$TMP/loop.txt"
cat > "$FIXTURE_TXT" <<'FIXTURE'
I have thought too much about this. I am making the decision clear and carrying it out: bloodhound CE is a web-app stack (docker-compose), not a CLI tool. It is a server service. I will mark it as "installable" (Java + Docker are there), but it is a web stack. I install it via docker-compose.

Actually — I will think it over again. bloodhound is a web-app stack. It is not a CLI tool. I will leave it as documentation-only, because it does not fit the "CLI-tool model" of H-Tools.

NO. That would not be correct. The task is clear: "work ONLY through the points listed there as open or half-finished". bloodhound is open. Java is there now. So I shall install bloodhound.

I will think it over again. The task is clear: "work ONLY through the points listed there as open or half-finished". bloodhound is open. Java is there now. So I shall install bloodhound.

But bloodhound is a web-app stack. I have to install it as such.

I will think it over again. The task is clear: "work ONLY through the points listed there as open or half-finished". bloodhound is open. Java is there now. So I shall install bloodhound.

But bloodhound is a web-app stack. I have to install it as such.

I will think it over again. The task is clear: "work ONLY through the points listed there as open or half-finished". bloodhound is open. Java is there now. So I shall install bloodhound.

But bloodhound is a web-app stack. I have to install it as such.

I will think it over again. The task is clear: "work ONLY through the points listed there as open or half-finished". bloodhound is open. Java is there now. So I shall install bloodhound.

But bloodhound is a web-app stack. I have to install it as such.

I will think it over again. The task is clear: "work ONLY through the points listed there as open or half-finished". bloodhound is open. Java is there now. So I shall install bloodhound.

But bloodhound is a web-app stack. I have to install it as such.

I will think it over again. The task is clear: "work ONLY through the points listed there as open or half-finished". bloodhound is open. Java is there now. So I shall install bloodhound.

But bloodhound is a web-app stack. I have to install it as such.

I will think it over again. The task is clear: "work ONLY through the points listed there as open or half-finished". bloodhound is open. Java is there now. So I shall install bloodhound.

But bloodhound is a web-app stack. I have to install it as such.
FIXTURE

# Mock queue: 3× the same loop turn (budget LEX_MAX_NUDGES=2 →
# nudge1, nudge2, truncation) — every call_api pulls one line.
MOCK_QUEUE="$TMP/queue.jsonl"
loop_line="$(jq -c -n --rawfile c "$FIXTURE_TXT" \
  '{choices:[{index:0,message:{role:"assistant",content:$c,reasoning_content:"",tool_calls:[]},finish_reason:"stop"}],usage:{prompt_tokens:100,completion_tokens:200,total_tokens:300}}')"
printf '%s\n%s\n%s\n' "$loop_line" "$loop_line" "$loop_line" > "$MOCK_QUEUE"

# ===========================================================================
# Source lex: LEX_HOME isolated, set the mock queue WELL BEFORE sourcing
# (the shadow copy is created while loading), budget down for a short run.
# ===========================================================================
export LEX_HOME="$TMP"
export LEX_MODEL="$TMP/model.gguf"
export LEX_WIKI_DIR="$TMP/wiki"
mkdir -p "$TMP/wiki"
export LEX_MOCK_FILE="$MOCK_QUEUE"
export LEX_MAX_NUDGES=2
unset LEX_MOCK
source "$LEX_DIR/lex" < /dev/null > /dev/null 2>&1 || {
  echo "FAILED: $LEX_DIR/lex not loadable (syntax/bash error)" >&2
  exit 1
}
setup_messages >/dev/null 2>&1 || true

# ===========================================================================
# 1. detector unit tests
# ===========================================================================
printf '  [INFO] _rep_detect: real case → A2\n'
out="$(printf '%s' "$(cat "$FIXTURE_TXT")" | _rep_detect)"
assert "real-case loop is detected as A2" "A2" "${out%%|*}"

printf '  [INFO] _rep_detect: word loop → A1\n'
out="$(printf 'data %.0s' {1..40} | _rep_detect)"
assert "word loop (data data …) is detected as A1" "A1" "${out%%|*}"

printf '  [INFO] _rep_detect: varied 4-gram loop → A3\n'
out="$({ for _ in $(seq 1 30); do printf 'the quick brown fox jumps over the lazy dog and runs away fast now '; done; echo; } | _rep_detect)"
assert "varied loop is detected as A3" "A3" "${out%%|*}"

# ===========================================================================
# 2. false-positive gates
# ===========================================================================
printf '  [INFO] _rep_detect: false-positive gates\n'
out="$(printf '│ exploit (3/1/—) │ sqlmap, metasploit (system), hashcat 7.1.2 │ hydra (Dual-Use) │\n│ scan (8/1/1) │ ffuf (v2.3.0), httpx, katana, naabu, nmap │ burp-suite │\n│ recon (1/2/—) │ subfinder │ bloodhound (Web-App-Stack Docker-Compose) │\n' | _rep_detect)"
assert "lexpen table: no finding" "" "$out"

out="$(printf 'Example:\n```bash\nwhile true; do echo hello; sleep 1; done\nwhile true; do echo hello; sleep 1; done\nwhile true; do echo hello; sleep 1; done\n```\nThe loop runs forever and has to be terminated manually.\n' | _rep_detect)"
assert "code block: no finding" "" "$out"

out="$(printf 'The server was restarted yesterday. Everything ran stably again afterwards. A second restart was not necessary. We keep watching it and only step in if failures happen again.\n' | _rep_detect)"
assert "normal prose: no finding" "" "$out"

out="$(printf 'This is a short sentence without value. This is a short sentence without value. This is a short sentence without value.\n' | _rep_detect)"
assert "short sentence ×3 (under both gates): no finding" "" "$out"

# ===========================================================================
# 3. integration: run_turn over the mock queue (3 identical loop turns)
# ===========================================================================
printf '  [INFO] run_turn: loop turn, nudge soft → hard → truncation\n'
# NO $(…) subshell: _messages must grow in the current shell process
# (finding in the test itself, 2026-10-03) — catch stdout/stderr over files.
run_turn "continue the task" >"$TMP/out.txt" 2>"$TMP/err.txt"
rc=$?
out="$(cat "$TMP/out.txt")"
err="$(cat "$TMP/err.txt")"
assert "run_turn ends with rc=0 (truncation path)" "0" "$rc"

contains "1. nudge: soft break impulse (finding named)" "Repetition loop detected (A2" "$err"
contains "2. nudge: hard impulse" "detected again" "$err"
contains "budget reached: truncation render" "showing only the start" "$err"
contains "render shows the start of the answer" "I have thought too much about this" "$out"
out_len="${#out}"
check "render is truncated (${out_len} chars, fixture 2912)" \
  "$([[ "$out_len" -ge 1500 && "$out_len" -lt 2500 ]] && echo 1 || echo 0)"

user_msgs="$(jq '[.[] | select(.role=="user")] | length' <<< "$_messages" 2>/dev/null || echo "?")"
assert "_messages: user messages = 1 input + 2 nudges" "3" "$user_msgs"

rep_recs="$(grep -c '"type":"repetition"' "${_session_file:-/dev/null}" 2>/dev/null || true)"
rep_recs="${rep_recs:-0}"
assert "session records type:repetition = 2 nudges + 1 truncation" "3" "$rep_recs"

# ===========================================================================
# 4. static anchors (pin-it-down principle)
# ===========================================================================
printf '  [INFO] static anchors\n'
src="$(cat "$LEX_DIR/lex")"
check "function _rep_detect defined" \
  "$(grep -q '^_rep_detect()' "$LEX_DIR/lex" && echo 1 || echo 0)"
check "hook checks content, not reasoning (scope deepseek #3480)" \
  "$(grep -q 'printf .%s. "\$content" | _rep_detect' "$LEX_DIR/lex" && ! grep -q '_rep_detect.*reasoning' "$LEX_DIR/lex" && echo 1 || echo 0)"
check "truncation render (content:0:2000) present" \
  "$(grep -q 'content:0:2000' "$LEX_DIR/lex" && echo 1 || echo 0)"
check "budget var rep_nudges initialized in run_turn" \
  "$(grep -q 'nudge_count=0 rep_nudges=0' "$LEX_DIR/lex" && echo 1 || echo 0)"
check "session record type:repetition present" \
  "$(grep -q 'type:"repetition"' "$LEX_DIR/lex" && echo 1 || echo 0)"
# shellcheck disable=SC2034  # src only for completeness
: "$src"

if (( FAIL > 0 )); then
  echo "test_repetition: $FAIL failures" >&2
  exit 1
fi
echo "test_repetition green. ✓"
exit 0
