#!/usr/bin/env bash
#
# tools/selfcheck_lex.sh — static completeness check for lex.
#
# Why (finding 2026-10-10, LEX.md §6 #44): `bash -n` and `shellcheck`
# only check syntax/style. A call to a function that does not exist is a
# runtime error only ("command not found") — neither tool reports it.
# That is exactly how the Tor-stealth build landed with
# `_tor_stealth_start` in the on-branch and without a definition in the
# script.
#
# What is checked:
#   1. bash -n                     syntax
#   2. shellcheck -S warning       style/clarity (if installed)
#   3. called but NEVER defined internal functions  ← the gap
#   4. target list of critical core functions (completeness of the file)
#
# Invocation:  tools/selfcheck_lex.sh [path/to/lex]     (default: ../lex)
# rc 0 = clean, rc 1 = finding (messages on stdout).
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEX="${1:-$here/../lex}"

fail=0
say() { printf '  [SELFCHECK] %s\n' "$*"; }
bad() { printf '  [SELFCHECK-FAIL] %s\n' "$*"; fail=1; }

[[ -f "$LEX" ]] || { bad "script not found: $LEX"; exit 1; }

# --- 1. Syntax ---------------------------------------------------------------
if bash -n "$LEX" 2>/tmp/selfcheck.$$.err; then
  say "bash -n: ok"
else
  bad "bash -n:"; sed 's/^/      /' /tmp/selfcheck.$$.err >&2
fi
rm -f /tmp/selfcheck.$$.err

# --- 2. shellcheck (if available) -------------------------------------------
if command -v shellcheck >/dev/null 2>&1; then
  if sc="$(shellcheck -S warning "$LEX" 2>&1)"; then
    say "shellcheck -S warning: ok"
  else
    bad "shellcheck -S warning:"; printf '%s\n' "$sc" | sed 's/^/      /' >&2
  fi
else
  say "shellcheck not installed — skipped"
fi

# --- 3. Calls without definition --------------------------------------------
# Definitions: `^ _name()` as well as `function _name`.
# References:  (a) `_name(` with a word boundary before, (b) lines where
#              `_name` stands alone (that was the finding 2026-10-10).
# Deliberate scope: only internal `_` names. Other internal functions
# (without `_`, e.g. `run_turn`) are covered by the target list in 4.
# Comments (leading "#" or from " #") are ignored — otherwise comment
# hints like "see _foo (…" would be a false needle.
# Also excluded: a `$` directly before. `$_var (` is a variable
# expansion with parenthesis text (e.g. log message
# "sandbox $_sbx (target …)"), never a call — otherwise a harmless log
# argument would be reported as a false needle, exactly the class the
# comments above already catch. Finding 2026-10-12.
defs="$(sed -nE 's/^[[:space:]]*(function[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*\(\).*/\2/p' "$LEX" | LC_ALL=C sort -u)"
src_nocomment="$(sed 's/[[:space:]]#.*$//' "$LEX" | grep -vE '^[[:space:]]*#')"
refs_a="$(printf '%s\n' "$src_nocomment" | grep -oE '(^|[^A-Za-z0-9_$])_[A-Za-z0-9_]+[[:space:]]*\(' | grep -oE '_[A-Za-z0-9_]+' | LC_ALL=C sort -u)"
refs_b="$(printf '%s\n' "$src_nocomment" | sed -nE 's/^[[:space:]]*(_[A-Za-z0-9_]+)[[:space:]]*$/\1/p' | LC_ALL=C sort -u)"
missing="$(comm -23 <(printf '%s\n%s\n' "$refs_a" "$refs_b" | LC_ALL=C sort -u | grep -v '^$') <(printf '%s\n' "$defs" | LC_ALL=C sort -u | grep -v '^$') || true)"
if [[ -n "$missing" ]]; then
  bad "called, but NEVER defined (would be a runtime error):"
  printf '%s\n' "$missing" | sed 's/^/      /' >&2
else
  say "no called function without definition"
fi

# --- 4. Target list of core functions ---------------------------------------
# (Extend when a core function is renamed/removed — this list catches
# half-written or damaged scripts that `bash -n` still accepts.)
kritisch=(
  main run_turn call_api dispatch_tool agent_loop setup_messages
  load_config usage oneshot install_lex session_init
  cmd_lexpen _swap_slot0 _build_tools _run_hooks _run_limited
)
for f in "${kritisch[@]}"; do
  if ! printf '%s\n' "$defs" | grep -qx "$f"; then
    bad "core function missing: $f()"
  fi
done
(( fail == 0 )) && say "core functions complete (${#kritisch[@]} checked)"

# --- Result ------------------------------------------------------------------
if (( fail )); then
  printf 'FAILURE: selfcheck %s\n' "$LEX" >&2
  exit 1
fi
printf 'selfcheck %s: ok\n' "$LEX"
exit 0
