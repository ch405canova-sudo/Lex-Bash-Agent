#!/usr/bin/env bash
#
# lex/test/test_selfedit.sh — Self-Edit-Sandbox in dispatch_tool (§2, 2026-10-12)
#
# Was geprüft wird: ein Edit, dessen Ziel das lex-Skript selbst ist, läuft auf
# einer Kopie, die Gates laufen dort, befördert wird erst bei grün. Bei rot
# bleibt das Original byte-identisch. Ein Edit auf ein fremdes Ziel legt
# KEINE Sandbox an und läuft ohne Verzögerung.
#
# Wie geprüft wird: der Fixtur-Baum trägt anstelle der echten Gates Stubs,
# die ihre Benennung in $TMP/calls aufzeichnen. Damit ist die Verdrahtung
# belegt (Gate 2 wird genau unter tree/test/run_all.sh aufgerufen, sein rc
# wird gewertet), ohne die ~82 s der echten Suite pro Lauf zu zahlen. Die
# mechanische Eignung der echten Suite in einer Kopie ist 2026-10-12
# nachgewiesen (13/13, 896 PASS, 82 s, rc 0) und steht im Wiki-Log.
#
# Kein Port 8080, kein echtes HTTP.
#
set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEX_DIR="$(dirname "$SCRIPT_DIR")"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export TMPDIR="$TMP"          # Sandboxes landen im trap-geräumten Verzeichnis
# Review-S6: eine exportierte Escape-Var würde den gesamten Test-Runner
# falsch rot machen, bevor Abschnitt 8 sie selbst setzt. Hier hart löschen,
# damit der Test seine eigene Umgebung kontrolliert.
unset LEX_SELFEDIT_GATES

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

# Skript laden: isoliertes LEX_HOME (muss $TMP sein, damit safe_path die
# Sandbox-Zieldateien zulässt), stdin=/dev/null → REPL-Pfad bricht ab.
export LEX_HOME="$TMP"
export LEX_MODEL="$TMP/model.gguf"
source "$LEX_DIR/lex" < /dev/null > /dev/null 2>&1 || {
  echo "FEHLSCHLAG: $LEX_DIR/lex nicht ladbar (Syntax-/Bash-Fehler)" >&2
  exit 1
}

# ── Fixtur: Repo-Struktur mit stubhaften Gates ───────────────────────────────
# Beide Gates schreiben ihre Benennung mit — Aussage: „dieses Gate wurde an
# genau diesem Pfad aufgerufen". Der Exit-Code steuert grün/rot.
FX="$TMP/fixtur"
CALLS="$TMP/calls"
mkdir -p "$FX/tools" "$FX/test"
printf 'ORIGINAL_INHALT\n' > "$FX/lex"    # das Skript selbst — sonst scheitert
                                          # _selfedit_anlegen an tree/lex
stub() {  # $1=Name $2=rc
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
gates_ran() {  # Aufrufreihenfolge, z.B. "G1 G2" — oder leer wenn keins lief
  [[ -f "$CALLS" ]] || return 0
  tr '\n' ' ' < "$CALLS" | sed 's/ $//'
}

# Globals aus dem Quell-Kontext korrigieren: beim `source` ist $0 das TEST-
# skript, also zeigen _lex_script/_lex_repo_dir sonst auf die falschen Ziele.
ZIEL="$TMP/ziel_lex"
_lex_repo_dir="$FX"
_lex_script="$ZIEL"

wjson() { jq -n --arg p "$1" --arg c "$2" '{path:$p, content:$c}'; }
ejson() { jq -n --arg p "$1" --arg o "$2" --arg n "$3" '{path:$p, old:$o, new:$n}'; }

# ══ 1. _selfedit_ziel — wann greift die Sandbox überhaupt? ═══════════════════
set_gates 0 0
_selfedit_ziel write_file "$(wjson "$ZIEL" "x")" >/dev/null 2>&1
assert "ziel: write_file auf lex → greift" "0" "$?"
_selfedit_ziel edit_file "$(ejson "$ZIEL" "a" "b")" >/dev/null 2>&1
assert "ziel: edit_file auf lex → greift" "0" "$?"
_selfedit_ziel bash '{"command":"true"}' >/dev/null 2>&1
assert "ziel: bash-Tool → greift NICHT" "1" "$?"
_selfedit_ziel write_file "$(wjson "$TMP/fremd.txt" "x")" >/dev/null 2>&1
assert "ziel: fremdes Ziel → greift NICHT" "1" "$?"
_selfedit_ziel read_file "$(wjson "$ZIEL" "x")" >/dev/null 2>&1
assert "ziel: read_file (kein Schreib-Tool) → greift NICHT" "1" "$?"

# ══ 2. _selfedit_anlegen — Baum, Sauberkeit, kein .git ═══════════════════════
sbx="$(_selfedit_anlegen)"; rc=$?
assert "anlegen: rc" "0" "$rc"
assert "anlegen: tree/lex vorhanden" "1" "$([[ -f "$sbx/tree/lex" ]] && echo 1 || echo 0)"
assert "anlegen: tree/test/run_all.sh vorhanden" "1" "$([[ -f "$sbx/tree/test/run_all.sh" ]] && echo 1 || echo 0)"
assert "anlegen: .git NICHT mitkopiert" "0" "$([[ -e "$sbx/tree/.git" ]] && echo 1 || echo 0)"
assert "anlegen: stdout enthält NUR den Pfad" "1" "$([[ -d "$sbx" ]] && echo 1 || echo 0)"
rm -rf "$sbx"

# ══ 3. Grüner Weg durch dispatch — befördert, Gates gelaufen, aufgeräumt ══════
printf 'VORHER\n' > "$ZIEL"
dispatch_tool write_file "$(wjson "$ZIEL" "NACHHER")" >/dev/null 2>&1
assert "dispatch grün: rc" "0" "$?"
assert "dispatch grün: Inhalt befördert" "NACHHER" "$(cat "$ZIEL")"
assert "dispatch grün: Gate 1 lief zuerst" "$G1" "$(gates_ran | cut -d' ' -f1)"
assert "dispatch grün: Gate 1+2 in Reihenfolge" "$G1 $G2" "$(gates_ran)"
assert "dispatch grün: Sicherung angelegt" "1" "$([[ -f "$TMP/lex.bak" ]] && echo 1 || echo 0)"
assert "dispatch grün: Sandbox entfernt" "0" \
  "$(find "$TMP" -maxdepth 1 -name 'lex-sbx.*' 2>/dev/null | wc -l)"

# ══ 4. Roter Weg — Gate 1 rot ⇒ Original byte-identisch, rc 1 ════════════════
printf 'VORHER\n' > "$ZIEL"
before="$(sha256sum < "$ZIEL")"
set_gates 1 0
out="$(dispatch_tool write_file "$(wjson "$ZIEL" "DARF_NICHT_DURCH")" 2>&1)"; rc=$?
assert "dispatch rot: rc" "1" "$rc"
assert "dispatch rot: Original byte-identisch" "$before" "$(sha256sum < "$ZIEL")"
assert "dispatch rot: Inhalt unverändert" "VORHER" "$(cat "$ZIEL")"
assert "dispatch rot: Befund im Tool-Ergebnis" "1" \
  "$([[ "$out" == *"ABGELEHNT"* && "$out" == *"Original bleibt unverändert"* ]] && echo 1 || echo 0)"
assert "dispatch rot: Sandbox entfernt" "0" \
  "$(find "$TMP" -maxdepth 1 -name 'lex-sbx.*' 2>/dev/null | wc -l)"

# ══ 5. Roter Weg über Gate 2 — run_all rc 1 wird gewertet, Stop vor Förderung ═
printf 'VORHER\n' > "$ZIEL"
before="$(sha256sum < "$ZIEL")"
set_gates 0 1
out="$(dispatch_tool write_file "$(wjson "$ZIEL" "DARF_AUCH_NICHT")" 2>&1)"; rc=$?
assert "dispatch rot (Gate 2): rc" "1" "$rc"
assert "dispatch rot (Gate 2): Original byte-identisch" "$before" "$(sha256sum < "$ZIEL")"
assert "dispatch rot (Gate 2): Gate 1+2 liefen" "$G1 $G2" "$(gates_ran)"
assert "dispatch rot (Gate 2): Befund nennt Gate 2/2" "1" \
  "$([[ "$out" == *"Gate 2/2 run_all"* ]] && echo 1 || echo 0)"
rm -rf -- "$TMP"/lex-sbx.* 2>/dev/null || true

# ══ 6. Negativ-Gate — fremdes Ziel: keine Sandbox, kein Gate, keine Verzögerung ═
set_gates 0 0
dispatch_tool write_file "$(wjson "$TMP/fremd.txt" "FREMD")" >/dev/null 2>&1
assert "fremd: rc" "0" "$?"
assert "fremd: Inhalt direkt geschrieben" "FREMD" "$(cat "$TMP/fremd.txt")"
assert "fremd: kein Gate gelaufen" "" "$(gates_ran)"
assert "fremd: keine Sandbox angelegt" "0" \
  "$(find "$TMP" -maxdepth 1 -name 'lex-sbx.*' 2>/dev/null | wc -l)"

# ══ 7. Escape LEX_SELFEDIT_GATES=fast — nur Gate 1, Warnung ist ausdrücklich ══
printf 'VORHER\n' > "$ZIEL"
set_gates 0 0
export LEX_SELFEDIT_GATES=fast
out="$(dispatch_tool write_file "$(wjson "$ZIEL" "FAST")" 2>&1)"; rc=$?
unset LEX_SELFEDIT_GATES
assert "fast: rc" "0" "$rc"
assert "fast: befördert" "FAST" "$(cat "$ZIEL")"
assert "fast: nur Gate 1 gelaufen" "$G1" "$(gates_ran)"
assert "fast: Warnung sagt dass DIE SUITE NICHT lief" "1" \
  "$([[ "$out" == *"DIE SUITE LIEF NICHT"* ]] && echo 1 || echo 0)"
assert "fast: Übernahme NICHT »Gates grün« (S4-Widerspruch)" "0" \
  "$([[ "$out" == *"Gates grün"* ]] && echo 1 || echo 0)"
assert "fast: Übernahme nennt die Lücke selbst" "1" \
  "$([[ "$out" == *"die Suite lief NICHT"* ]] && echo 1 || echo 0)"

# ══ 8. Escape LEX_SELFEDIT_GATES=off — keine Prüfung, Warnung ausdrücklich ════
printf 'VORHER\n' > "$ZIEL"
set_gates 1 1                       # Gates WÜRDEN fallen → müssen gar nicht laufen
export LEX_SELFEDIT_GATES=off
out="$(dispatch_tool write_file "$(wjson "$ZIEL" "OFF")" 2>&1)"; rc=$?
unset LEX_SELFEDIT_GATES
assert "off: rc" "0" "$rc"
assert "off: befördert" "OFF" "$(cat "$ZIEL")"
assert "off: kein Gate gelaufen" "" "$(gates_ran)"
assert "off: Warnung sagt OHNE jede Prüfung" "1" \
  "$([[ "$out" == *"OHNE jede Prüfung"* ]] && echo 1 || echo 0)"
assert "off: Übernahme NICHT »Gates grün« (S4-Widerspruch)" "0" \
  "$([[ "$out" == *"Gates grün"* ]] && echo 1 || echo 0)"
assert "off: Übernahme meldet ausdrücklich OHNE Prüfung" "1" \
  "$([[ "$out" == *"übernommen (OHNE jede Prüfung)"* ]] && echo 1 || echo 0)"

# ══ 9. Echter Kopierpfad — Baum des echten Repo, Runner dort byte-identisch ═══
# Belegt, dass Gate 2 im Sandbox-Baum tatsächlich den ECHTEN runner findet
# (nicht nur einen Stub) — die Stub-Tests oben prüfen nur die Verdrahtung.
_lex_repo_dir="$LEX_DIR"
real_sbx="$(_selfedit_anlegen)"; rc=$?
assert "echt: anlegen rc" "0" "$rc"
assert "echt: echter run_all in der Kopie" "1" \
  "$([[ -f "$real_sbx/tree/test/run_all.sh" ]] && echo 1 || echo 0)"
assert "echt: run_all byte-identisch zum Original" \
  "$(sha256sum < "$LEX_DIR/test/run_all.sh")" \
  "$(sha256sum < "$real_sbx/tree/test/run_all.sh")"
assert "echt: lex in der Kopie byte-identisch zum Original" \
  "$(sha256sum < "$LEX_DIR/lex")" "$(sha256sum < "$real_sbx/tree/lex")"
assert "echt: kein .git mitkopiert" "0" "$([[ -e "$real_sbx/tree/.git" ]] && echo 1 || echo 0)"
rm -rf "$real_sbx"
_lex_repo_dir="$FX"

# ══ 10. Regression B1 — Tilde-Pfad darf die Sandbox NICHT umgehen ════════════
# safe_path expandiert `~` selbst (lex:1365), `readlink -f` allein löst
# `~/ziel_lex` als `$PWD/~/ziel_lex` auf. Ohne den Fix in _selfedit_ziel
# wäre die Zielprüfung rc 1 → keine Gates, und tool_write_file hätte danach
# über safe_path DIREKT aufs Original geschrieben (Review-B1).
printf 'VORHER\n' > "$ZIEL"
set_gates 0 0
HOME_ECHTE="$HOME"
export HOME="$TMP"                      # damit `~/$rel` genau $ZIEL meint
# Absichtlich LITERALER Tilde: der Test will beweisen, dass _selfedit_ziel und
# safe_path den Tilde SELBST expandieren (Review-B1). $HOME hinzuschreiben
# würde genau den zu testenden Fall entfernen — deshalb hier keine Korrektur.
# Achtung shellcheck: die Directive bindet an den ERSTEN einfachen Befehl der
# nächsten Zeile — deshalb `_z=1` auf eigener Zeile davor, sonst greift sie
# für die Zuweisung und der Aufruf bleibt gemeldet (0.11.0, geprüft).
_z=1
# shellcheck disable=SC2088
_selfedit_ziel write_file "$(wjson "~/ziel_lex" "x")" >/dev/null 2>&1 && _z=0
export HOME="$HOME_ECHTE"
assert "B1 tilde: _selfedit_ziel erkennt ~-Pfad" "0" "$_z"

export HOME="$TMP"
# Literaler Tilde ist der Testgegenstand, s. o.
# shellcheck disable=SC2088
dispatch_tool write_file "$(wjson "~/ziel_lex" "TILDE")" >/dev/null 2>&1; rc=$?
export HOME="$HOME_ECHTE"
assert "B1 tilde: dispatch rc" "0" "$rc"
assert "B1 tilde: befördert" "TILDE" "$(cat "$ZIEL")"
assert "B1 tilde: Gates liefen (kein stiller Direktzugriff)" "$G1 $G2" "$(gates_ran)"
assert "B1 tilde: Sandbox weggeräumt" "0" \
  "$(find "$TMP" -maxdepth 1 -name 'lex-sbx.*' 2>/dev/null | wc -l)"

# ══ 11. Edit selbst fehlgeschlagen ⇒ KEINE Gates, Original unangetastet ═════
# Der Zweig `if (( _rc == 0 ))` war bisher ganz ohne Nadel: die Sandbox muss
# verworfen und die Suite ausgelassen werden, wenn der Edit gar nicht saß.
printf 'VORHER\n' > "$ZIEL"
before="$(sha256sum < "$ZIEL")"
set_gates 0 0
dispatch_tool edit_file "$(ejson "$ZIEL" "EXISTIERT_HIER_NICHT" "irgendwas")" >/dev/null 2>&1; rc=$?
assert "_rc!=0: rc" "1" "$rc"
assert "_rc!=0: Original byte-identisch" "$before" "$(sha256sum < "$ZIEL")"
assert "_rc!=0: KEIN Gate gelaufen" "" "$(gates_ran)"
assert "_rc!=0: Sandbox verworfen" "0" \
  "$(find "$TMP" -maxdepth 1 -name 'lex-sbx.*' 2>/dev/null | wc -l)"

# ══ 12. Sandbox nicht anlegbar ⇒ Meldung + Original unangetastet ════════════
_ZIEL_A="$_lex_script"; _REPO_A="$_lex_repo_dir"
printf 'VORHER\n' > "$ZIEL"
before="$(sha256sum < "$ZIEL")"
set_gates 0 0
_lex_repo_dir="$TMP/gibtsnicht"          # ohne lex/ und test/run_all.sh
out="$(dispatch_tool write_file "$(wjson "$ZIEL" "DARF_NICHT")" 2>&1)"; rc=$?
_lex_repo_dir="$_REPO_A"
assert "anlegen-fail: rc" "1" "$rc"
assert "anlegen-fail: Original byte-identisch" "$before" "$(sha256sum < "$ZIEL")"
assert "anlegen-fail: Meldung mit Original-Hinweis" "1" \
  "$([[ "$out" == *"Original bleibt unverändert"* ]] && echo 1 || echo 0)"
assert "anlegen-fail: kein Gate gelaufen" "" "$(gates_ran)"
assert "anlegen-fail: keine halbe Sandbox offen" "0" \
  "$(find "$TMP" -maxdepth 1 -name 'lex-sbx.*' 2>/dev/null | wc -l)"
_lex_script="$_ZIEL_A"

# ══ 13. Übernahme fehlgeschlagen ⇒ rc 1, Fehlermeldung, keine Erfolgs-Aussage ═
# Fixtur: das Elternverzeichnis des Ziels ist eine REGULÄRE DATEI → `cp` nach
# `$_lex_script.new.$$` scheitert mit ENOTDIR, unabhängig von Rechten/root.
sbx2="$(_selfedit_anlegen)"; assert "uebernehmen-fail: Sandbox anlegbar" "0" "$?"
printf 'nicht-verzeichnis\n' > "$TMP/block"
_lex_script="$TMP/block/lex"             # $TMP/block ist eine Datei, kein Dir
# stderr hier abfangen: der bewusste „Sicherung nicht schreibbar"-Hinweis
# (graceful Degradation) wäre nur Testlärm — wir prüfen die stdout-Meldung.
out="$(_selfedit_uebernehmen "$sbx2" 2>/dev/null)"; rc=$?
_lex_script="$_ZIEL_A"
assert "uebernehmen-fail: rc" "1" "$rc"
assert "uebernehmen-fail: meldet den Fehler" "1" \
  "$([[ "$out" == *"Übernahme fehlgeschlagen"* ]] && echo 1 || echo 0)"
assert "uebernehmen-fail: KEINE Erfolgsmeldung daneben" "0" \
  "$([[ "$out" == *"übernommen"* ]] && echo 1 || echo 0)"
rm -rf -- "$sbx2"

# ══ 14. Aufräumen — kein Sandbox-Müll zurückgeblieben ═════════════════════════
assert "Ende: keine Sandbox-Verzeichnisse offen" "0" \
  "$(find "$TMP" -maxdepth 1 -name 'lex-sbx.*' 2>/dev/null | wc -l)"

if (( FAIL )); then
  echo "FEHLSCHLAG: test_selfedit" >&2
  exit 1
fi
echo "test_selfedit: ok"
exit 0
