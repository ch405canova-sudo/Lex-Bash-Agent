#!/usr/bin/env bash
#
# lex/test/run_all.sh — läuft alle Tests, gibt Exit-Code 0 nur wenn alle grün.
#
set -u
set -o pipefail

# Hintergrund-Erbgut-Sperre (Fund 2026-10-10, siehe test_input.sh): läuft
# run_all aus einem Hintergrund-Job (lex' tool_bash startet so), erben alle
# Läufer SIGINT=ignore und die ^C-Nadeln fallen ohne Defekt rot. Einmaliger
# Reset vor dem ersten Läufer.
_sigign="$(awk '/^SigIgn:/{print $2}' /proc/$$/status 2>/dev/null || true)"
if [[ -n "${_sigign:-}" ]] && command -v env >/dev/null 2>&1 \
   && env --help 2>/dev/null | grep -q -- '--default-signal' \
   && (( (16#$_sigign >> 1) & 1 )); then
  exec env --default-signal=INT bash "${BASH_SOURCE[0]}" "$@"
fi

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

# Testboden — die Suite darf nicht still leiser werden.
# Fund 2026-09-30: test_foo.sh gelöscht bzw. aus der Runner-Liste genommen,
# dadurch war eine kaputte Pfadänderung in call_api() unsichtbar grün.
# Prüft drei Richtungen: jeder in run_all.sh genannte Runner existiert und ist
# ausführbar · keine Testdatei gegenüber HEAD gelöscht · jede vorhandene
# test_*.sh läuft auch wirklich mit.
testboden_check() {
  local ref b f bad missing="" deleted="" orphan=""
  # Gegriffen werden nur die Runner-Aufrufe selbst (Pfad mit SCRIPT_DIR-
  # Vorsprung) — Kommentare und Beispielnamen in diesem Skript dürfen die
  # Prüfung nicht triggern.
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
  # N9-Selbsttest: die Syntax-Prüfung darf keine bewusst kaputte Datei
  # durchwinken (sonst ist der breitere Scope nur Behauptung).
  bad="$(mktemp)"
  printf 'if true\n' >"$bad"
  if syntax_check "$bad" 2>/dev/null; then
    rm -f "$bad"
    printf '  syntax_check findet keine kaputte Datei (N9)\n'
    return 1
  fi
  rm -f "$bad"
  if [[ -n "$missing$deleted$orphan" ]]; then
    [[ -n "$missing"  ]] && printf '  fehlte/unausführbar:%s\n' "$missing"
    [[ -n "$deleted"  ]] && printf '  gegenüber HEAD gelöscht:%s\n' "$deleted"
    [[ -n "$orphan"   ]] && printf '  vorhanden, aber nicht eingebunden:%s\n' "$orphan"
    return 1
  fi
  return 0
}

# Syntax-Prüfung so breit wie CI sie fordert (Fund N9 2026-10-08:
# vorher nur `lex` + `llama-proxy.sh` — `werkstatt_index.sh`
# und die Testdateien selbst wurden lokal nie syntaxgeprüft). Argumente
# überschreiben die Dateiliste (Selbsttest im Testboden).
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
run_test "selfedit"     "$SCRIPT_DIR/test_selfedit.sh"
run_test "loop"         "$SCRIPT_DIR/test_loop.sh"
run_test "http"         "$SCRIPT_DIR/test_http.sh"
run_test "features"     "$SCRIPT_DIR/test_features.sh"
run_test "mem_pref"     "$SCRIPT_DIR/test_mem_pref.sh"
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
  echo "FEHLSCHLAG: $FAIL Test(s) gescheitert." >&2
  exit 1
fi
echo "ALLE TESTS GRÜN. ✓"
exit 0
