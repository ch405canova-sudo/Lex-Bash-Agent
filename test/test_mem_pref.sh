#!/usr/bin/env bash
#
# lex/test/test_mem_pref.sh — `_mem_pref_ex` (Präferenzen aus mem/ in den
# System-Prompt). Kontext: `mem/` war bisher WRITE-ONLY, in
# /status gezählt, aber nie injiziert. Sechs Präferenzen lagen still, zwei
# davon Sicherheitsregeln.
# NIE echte Requests an 127.0.0.1:8080 — nur LEX_MOCK / LEX_MOCK_FILE.
#
# shellcheck disable=SC1090,SC1111,SC2154  # Quelle wird per Variable geladen;
#                                    # Unicode-Anführungszeichen in deutschen Meldungen;
#                                    # Variablen aus lex sind shellcheck unsichtbar.
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
    printf '         erwartet: %q\n' "$expected" >&2
    printf '         ist:      %q\n' "$actual" >&2
    FAIL=1
  fi
}

contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf '  [PASS] %s\n' "$desc"
  else
    printf '  [FAIL] %s\n' "$desc" >&2
    printf '         erwartet (enthält): %q\n' "$needle" >&2
    printf '         ist:                %q\n' "$haystack" >&2
    FAIL=1
  fi
}

notcontains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf '  [PASS] %s\n' "$desc"
  else
    printf '  [FAIL] %s\n' "$desc" >&2
    printf '         darf NICHT enthalten: %q\n' "$needle" >&2
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

# --- Fixtur: isoliertes LEX_HOME, stdin=/dev/null (REPL-Pfad bricht ab) -----
export LEX_HOME="$TMP"
export LEX_MODEL="$TMP/model.gguf"
export LEX_MEM_DIR="$TMP/mem"
export LEX_WIKI_DIR="$TMP/wiki"
export LEX_SESSION=0
source "$LEX_BIN" < /dev/null > /dev/null 2>&1 || {
  echo "FEHLSCHLAG: $LEX_BIN nicht ladbar (Syntax-/Bash-Fehler)" >&2
  exit 1
}
load_config || { echo "FEHLSCHLAG: load_config" >&2; exit 1; }

mkdir -p "$LEX_MEM_DIR" "$LEX_WIKI_DIR"

# Schreibt im Format von tool_mem_add — Frontmatter wie im Produktiv-Store.
mkmem() {  # $1 = Dateiname, $2 = type, $3 = Inhalt
  printf -- '---\ndate: 2026-01-03T00:00:00+0200\ntype: %s\nslug: %s\n---\n\n%s\n' \
    "$2" "${1%.md}" "$3" > "$LEX_MEM_DIR/$1"
}

# ══ 1. Basis-Fixtur ════════════════════════════════════════════════════════
# Zeitstempel steigen → `sort -r` muss c, b, a liefern.
mkmem "20260103000001-a-aeltere.md"  preference "AELTERE Präferenz"
mkmem "20260103000002-b-mittlere.md" preference "MITTLERE Präferenz"
mkmem "20260103000003-c-neueste.md"  preference "NEUESTE Präferenz"
mkmem "20260103000004-d-fact.md"     fact       "FACT_NICHT_INJIZIEREN"
mkmem "20260103000005-e-memory.md"   memory     "MEMORY_NICHT_INJIZIEREN"
mkmem "20260103000006-f-note.md"     note       "NOTE_NICHT_INJIZIEREN"
mkmem "20260103000007-g-ignoriert.txt" preference "TXT_NICHT_INJIZIEREN"

# ══ 2. Gates, Rückgabe, Nur-preference ═════════════════════════════════════
rc=0; out="$(LEX_MEM_PREF=off _mem_pref_ex)" || rc=$?
assert "gate off: rc" "0" "$rc"
assert "gate off: leer (nichts injiziert)" "" "$out"

rc=0; out="$(_mem_pref_ex)" || rc=$?
assert "default: rc" "0" "$rc"
contains "default: Blockkopf nennt den Store-Pfad" "Deine Präferenzen" "$out"
contains "default: Pfad des Stores im Kopf" "$TMP/mem" "$out"

contains "nur preference: fact bleibt draußen" "1" \
  "$([[ "$out" == *FACT_NICHT_INJIZIEREN* ]] && echo 0 || echo 1)"
contains "nur preference: memory bleibt draußen" "1" \
  "$([[ "$out" == *MEMORY_NICHT_INJIZIEREN* ]] && echo 0 || echo 1)"
contains "nur preference: note bleibt draußen" "1" \
  "$([[ "$out" == *NOTE_NICHT_INJIZIEREN* ]] && echo 0 || echo 1)"
contains "nicht-.md-Datei wird ignoriert" "1" \
  "$([[ "$out" == *TXT_NICHT_INJIZIEREN* ]] && echo 0 || echo 1)"
contains "alle drei Präferenzen sind drin" "3" \
  "$(printf '%s' "$out" | grep -c '^- ')"

# ══ 3. Reihenfolge und Widerspruchsregel ═══════════════════════════════════
# Die Regel IST der Zweck der Reihenfolge — ohne sie neutralisieren sich zwei
# gleich laufende Präferenzen (Fall der Ton-Einträge 10-02 / 10-09).
contains "Widerspruchsregel steht als Text im Block" "NEUESTE Eintrag" "$out"

i_c="$(printf '%s' "$out" | grep -b -o 'NEUESTE Präferenz' | head -1 | cut -d: -f1)"
i_b="$(printf '%s' "$out" | grep -b -o 'MITTLERE Präferenz' | head -1 | cut -d: -f1)"
i_a="$(printf '%s' "$out" | grep -b -o 'AELTERE Präferenz'  | head -1 | cut -d: -f1)"
check "Reihenfolge: neueste zuerst (c < b < a im Byte-Offset)" \
  "$([[ -n "$i_c" && -n "$i_b" && -n "$i_a" && "$i_c" -lt "$i_b" && "$i_b" -lt "$i_a" ]] && echo 1 || echo 0)"
check "Aufzählungszeichen steht mit Text auf einer Zeile (kein »- « allein)" \
  "$(printf '%s' "$out" | grep -cE '^- $' | awk '{print ($1==0)?1:0}')"

# ══ 4. Budgets ═════════════════════════════════════════════════════════════
# Nie still kürzen — sichtbarer Marker (gleiche Klasse wie §7/89).
out="$(LEX_MEM_PREF_TOTAL=40 _mem_pref_ex)"
contains "Gesamt-Budget: sichtbarer Kürzungsmarker" "LEX_MEM_PREF_TOTAL erreicht" "$out"
notcontains "Gesamt-Budget: abgeschnittene Präferenz fehlt" "AELTERE Präferenz" "$out"

out="$(LEX_MEM_PREF_MAX=12 _mem_pref_ex)"
contains "Pro-Eintrag-Budget: sichtbarer Kürzungsmarker" "gekürzt — vollständig unter" "$out"

# ══ 5. Ausnahme-Fälle ══════════════════════════════════════════════════════
mkdir -p "$TMP/leer"
_mem_dir="$TMP/leer"
rc=0; out="$(_mem_pref_ex)" || rc=$?
assert "leeres Verzeichnis: rc" "0" "$rc"
assert "leeres Verzeichnis: leer, kein leerer Block" "" "$out"

_mem_dir="$TMP/gibtsnicht"
rc=0; out="$(_mem_pref_ex)" || rc=$?
assert "Verzeichnis fehlt: rc" "0" "$rc"
assert "Verzeichnis fehlt: leer" "" "$out"

# ══ 6. _mem_dir wird respektiert ═══════════════════════════════════════════
mkdir -p "$TMP/mem2"
printf -- '---\ndate: 2026-01-03T00:00:00+0200\ntype: preference\nslug: zweitstore\n---\n\nZWEITSTORE Präferenz\n' \
  > "$TMP/mem2/20260103000099-z-zweitstore.md"
_mem_dir="$TMP/mem2"
out="$(_mem_pref_ex)"
contains "zweiter Store: dessen Präferenz" "ZWEITSTORE Präferenz" "$out"
notcontains "zweiter Store: der erste Store bleibt draußen" "NEUESTE Präferenz" "$out"

# ══ 7. Integration: setup_messages injiziert es WIRKLICH ═══════════════════
# Der eigentliche Zweck — sonst wäre die Funktion nur ein toter Codepfad.
_mem_dir="$TMP/mem"
LEX_SESSION=0 setup_messages >/dev/null 2>&1
sys="$(printf '%s' "$_messages" | jq -r '.[0].content' 2>/dev/null)"
contains "setup_messages: Präferenz landet im System-Prompt" "NEUESTE Präferenz" "$sys"
contains "setup_messages: Widerspruchsregel landet im System-Prompt" "NEUESTE Eintrag" "$sys"
notcontains "setup_messages: fact landet NICHT im System-Prompt" "FACT_NICHT_INJIZIEREN" "$sys"
contains "setup_messages: Reihenfolge überlebt die Integration" "1" \
  "$([[ "$(printf '%s' "$sys" | grep -b -o 'NEUESTE Präferenz' | head -1 | cut -d: -f1)" \
        -lt "$(printf '%s' "$sys" | grep -b -o 'AELTERE Präferenz' | head -1 | cut -d: -f1)" ]] && echo 1 || echo 0)"

# ══ 8. stdout ist ausschließlich der Block ═════════════════════════════════
_mem_dir="$TMP/mem"
rc=0; out="$(_mem_pref_ex 2>"$TMP/err")" || rc=$?
assert "rc auch bei leerem stderr" "0" "$rc"
assert "stderr ist leer (kein Rauschen ins Prompt-Bauen)" "" "$(cat "$TMP/err")"

# ══ 9. Abschluss ═══════════════════════════════════════════════════════════
if (( FAIL )); then
  echo "FEHLSCHLAG: test_mem_pref" >&2
  exit 1
fi
echo "test_mem_pref: ok"
exit 0
