#!/usr/bin/env bash
#
# lex/test/test_tools.sh — die 5 Tools + safe_path + dispatch (direkt per Funktion).
# Skript wird per source geladen (stdin=/dev/null → REPL-Pfad bricht sofort ab).
# Kein Port 8080, kein echtes HTTP.
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
    printf '         erwartet: %q\n' "$expected" >&2
    printf '         ist:      %q\n' "$actual" >&2
    FAIL=1
  fi
}

# Skript laden: env-variante LEX_HOME (Isolierung) + LEX_MODEL, stdin=/dev/null
export LEX_HOME="$TMP"
export LEX_MODEL="$TMP/model.gguf"
source "$LEX_DIR/lex" < /dev/null > /dev/null 2>&1 || {
  echo "FEHLSCHLAG: $LEX_DIR/lex nicht ladbar (Syntax-/Bash-Fehler)" >&2
  exit 1
}

# 8. safe_path: normale Datei unter LEX_HOME wird erlaubt
res="$(safe_path "$TMP/file.txt")"
assert "safe_path (erlaubt)" "$TMP/file.txt" "$res"

# 9. safe_path: Deny-Liste (z. B. /etc/passwd) wird abgelehnt (Fehlerpfad im
#    eigenen TMP, nicht geteilter /tmp-Pfad)
safe_path /etc/passwd >/dev/null 2>"$TMP/safe_err"
err="$(cat "$TMP/safe_err")"
if [[ "$err" == *"nicht erlaubt"* ]]; then
  printf '  [PASS] safe_path (Deny-Liste)\n'
else
  printf '  [FAIL] safe_path (Deny-Liste): %q\n' "$err" >&2
  FAIL=1
fi

# 10. tool_write_file: schreibt Datei, erzeugt Verzeichnisse
tool_write_file "$TMP/a/b/c.txt" "Hallo Welt" >/dev/null 2>&1
content="$(cat "$TMP/a/b/c.txt")"
assert "write_file (Inhalt + Verzeichnis)" "Hallo Welt" "$content"

# 10b. Audit H2 (2026-10-08): "" landete über safe_path im CWD und ein
#      Verzeichnispfad schluckte den tmp-MV — beides meldete „geschrieben"
#      und hinterließ .lex-write.*-Dotfiles. Jetzt Fehlerpfad + rc 1.
out="$(tool_write_file "" "x" 2>&1)"; rc=$?
assert "write_file (leerer Pfad → rc 1)" "1" "$rc"
assert "write_file (leerer Pfad → Meldung)" "1" \
  "$([[ "$out" == *"Pfad leer"* ]] && echo 1 || echo 0)"
out="$(tool_write_file "$TMP" "x" 2>&1)"; rc=$?
assert "write_file (Verzeichnis → rc 1)" "1" "$rc"
assert "write_file (Verzeichnis → Meldung)" "1" \
  "$([[ "$out" == *"Verzeichnis"* ]] && echo 1 || echo 0)"
assert "write_file (kein .lex-write.-Dotfile)" "0" \
  "$(find "$TMP" -maxdepth 1 -name '.lex-write.*' 2>/dev/null | wc -l)"
out="$(tool_append_file "" "x" 2>&1)"; rc=$?
assert "append_file (leerer Pfad → rc 1)" "1" "$rc"
out="$(tool_append_file "$TMP" "x" 2>&1)"; rc=$?
assert "append_file (Verzeichnis → rc 1)" "1" "$rc"

# 11. tool_read_file: liest geschriebene Datei
content="$(tool_read_file "$TMP/a/b/c.txt")"
assert "read_file" "Hallo Welt" "$content"

# 12. tool_read_file: fehlende Datei → Fehler + exit 1
tool_read_file "$TMP/nicht_da.txt" >/dev/null 2>&1
rc=$?
if (( rc != 0 )); then
  printf '  [PASS] read_file (fehlende Datei)\n'
else
  printf '  [FAIL] read_file (fehlende Datei)\n' >&2
  FAIL=1
fi

# 12b. tool_read_file: liefert die Datei vollständig — _tool_max_output greift
#      nicht mehr pro Tool, sondern zentral in run_turn (Spill statt Abschnitt;
#      der Alt-Zustand „Kappe + Bytezahl" hieß E2BIG-Schutz, der heute am
#      Nachrichtenpfad nicht mehr existiert). Vollständigkeit: test_limits.sh.
big="$TMP/big.txt"
: > "$big"
i=0; while (( i < 40 )); do printf 'aaaaaaaaaa\n' >> "$big"; i=$((i + 1)); done
_tool_max_output=5
out="$(tool_read_file "$big")"
_tool_max_output=50000
exp="$(cat "$big")"
if [[ "$out" == "$exp" && "$out" != *"abgeschnitten"* ]]; then
  printf '  [PASS] read_file (volle Datei trotz _tool_max_output)\n'
else
  printf '  [FAIL] read_file (volle Datei): %q\n' "$out" >&2
  FAIL=1
fi

# 13. tool_edit_file: ersetzt erstes Vorkommen
printf 'vor old nach\n' > "$TMP/e.txt"
tool_edit_file "$TMP/e.txt" "old" "neu" >/dev/null 2>&1
content="$(cat "$TMP/e.txt")"
assert "edit_file" "vor neu nach" "$content"

# 14. tool_edit_file: Suchtext nicht gefunden → exit 1
tool_edit_file "$TMP/e.txt" "nichte" "x" >/dev/null 2>&1
rc=$?
if (( rc != 0 )); then
  printf '  [PASS] edit_file (Suchtext fehlt)\n'
else
  printf '  [FAIL] edit_file (Suchtext fehlt)\n' >&2
  FAIL=1
fi

# 15. tool_bash: erfolgreiches Kommando
out="$(tool_bash "echo Hallo")"
assert "bash (Erfolg)" "Hallo" "$out"

# 16. tool_bash: Fehler-Exit-Code
out="$(tool_bash "false")"
if [[ "$out" == *"Exit-Code: 1"* ]]; then
  printf '  [PASS] bash (Fehler)\n'
else
  printf '  [FAIL] bash (Fehler): %q\n' "$out" >&2
  FAIL=1
fi

# 16b. pipefail (Fund 2026-10-12): der rc gilt für die KETTE, nicht für
#      das letzte Glied — sonst meldet `make … | tail` auch bei einem
#      gescheiterten Glied „Exit-Code: 0" und das Modell schreibt trotzdem
#      „installiert".
out="$(tool_bash "false | cat")"
if [[ "$out" == *"Exit-Code: 1"* ]]; then
  printf '  [PASS] bash (pipefail: rc der Kette)\n'
else
  printf '  [FAIL] bash (pipefail: rc der Kette): %q\n' "$out" >&2
  FAIL=1
fi
out="$(tool_bash "true | cat")"
if [[ "$out" != *"Exit-Code"* ]]; then
  printf '  [PASS] bash (pipefail: Erfolg bleibt rc-frei)\n'
else
  printf '  [FAIL] bash (pipefail: Erfolg bleibt rc-frei): %q\n' "$out" >&2
  FAIL=1
fi

# 17. tool_bash: stdin wird ignoriert (</dev/null) — sonst hängt `cat`/`read` am Terminal
out="$(printf 'x\n' | tool_bash "cat")"
assert "bash (ignoriert stdin)" "" "$out"

# 18. tool_bash: keine Kürzung mehr durch _tool_max_output (die alte Version
#     hing hier einen Abbruch-Hinweis an — der lag vor dem Spill, das heute
#     in run_turn greift: Kopf + Ablagepfad statt Abschnitt)
_tool_max_output=5
out="$(tool_bash "printf 'aaaaaaaaaa'")"
_tool_max_output=50000
assert "bash (volle Ausgabe trotz _tool_max_output)" "aaaaaaaaaa" "$out"

# 19. tool_list_files: existierendes Verzeichnis
out="$(tool_list_files "$TMP/a/b" 2>/dev/null)"
if [[ "$out" == *"c.txt"* ]]; then
  printf '  [PASS] list_files\n'
else
  printf '  [FAIL] list_files\n' >&2
  FAIL=1
fi

# 20. tool_list_files: fehlendes Verzeichnis → exit 1
tool_list_files "$TMP/kaputt" >/dev/null 2>&1
rc=$?
if (( rc != 0 )); then
  printf '  [PASS] list_files (fehlendes Verzeichnis)\n'
else
  printf '  [FAIL] list_files (fehlendes Verzeichnis)\n' >&2
  FAIL=1
fi

# 21. dispatch_tool: read_file über JSON-Args
args="$(jq -n --arg p "$TMP/a/b/c.txt" '{"path":$p}')"
out="$(dispatch_tool "read_file" "$args")"
assert "dispatch (read_file)" "Hallo Welt" "$out"

# 22. dispatch_tool: unbekanntes Tool → exit 1
dispatch_tool "kann_nicht" '{}' >/dev/null 2>&1
rc=$?
if (( rc != 0 )); then
  printf '  [PASS] dispatch (unbekanntes Tool)\n'
else
  printf '  [FAIL] dispatch (unbekanntes Tool)\n' >&2
  FAIL=1
fi

if (( FAIL > 0 )); then
  echo "FEHLSCHLAG: $FAIL Test(s) in test_tools.sh" >&2
  exit 1
fi
echo "test_tools.sh grün. ✓"
exit 0
