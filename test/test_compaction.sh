#!/usr/bin/env bash
#
# lex/test/test_compaction.sh — Context-Compaction + Kontext-HUD (Schritt 42)
#
# Fixiert:
#   1. Inert-by-Threshold: mit Defaults wird NICHT kompaktiert (die 591
#      Alt-Checks laufen unverändert weiter).
#   2. Trigger unter erzwungener Schwelle (LEX_CTX_LIMIT/LEX_COMPACT_KEEP).
#   3. Fail-safe: leeres/kaputtes Summary → _messages byte-identisch.
#   4. Paarungs-Gate (_pairing_ok), Einheiten-Gruppierung, Serialize,
#      Schwellen-Rechnung — als Unit-Tests über source (Muster test_sse).
#   5. Slash /compact in REPL (PTY) und oneshot, HUD ctx%, Config-Tier.
#
# NUR Mock/Fake — der echte llama-server (8080) wird nicht angerührt.
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
    printf '         erwartet: %q\n' "$expected" >&2
    printf '         ist:      %q\n' "$actual" >&2
    FAIL=1
  fi
}
contains() {
  local desc="$1" needle="$2" hay="$3"
  if [[ "$hay" == *"$needle"* ]]; then
    printf '  [PASS] %s\n' "$desc"
  else
    printf '  [FAIL] %s (suche: %q)\n' "$desc" "$needle" >&2
    printf '         Text: %q\n' "$hay" >&2
    FAIL=1
  fi
}
not_contains() {
  local desc="$1" needle="$2" hay="$3"
  if [[ "$hay" != *"$needle"* ]]; then
    printf '  [PASS] %s\n' "$desc"
  else
    printf '  [FAIL] %s (nicht enthalten: %q)\n' "$desc" "$needle" >&2
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
# grep -c liefert 0 bei Fehlern — normalisiert auf eine Zahl.
count_of() {   # "muster" "datei"
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
echo "[INFO] statische Checks (Quell-Anker)"

# Der Run-Hook MUSS vor dem user-append sitzen (einziger sicherer Punkt).
hook_line="$(grep -n '^\s*_compact_run$' "$LEX_BIN" | head -1 | cut -d: -f1)"
append_line="$(grep -n 'append_message "user" "\$input"' "$LEX_BIN" | head -1 | cut -d: -f1)"
check "quelle (_compact_run vor user-append)" \
  "$([[ -n "$hook_line" && -n "$append_line" && "$hook_line" -lt "$append_line" ]] && echo 1 || echo 0)"
check "quelle (G6-Gate im Swap-Pfad)" \
  "$(grep -qF '_pairing_ok <<< "$new"' "$LEX_BIN" && echo 1 || echo 0)"
check "quelle (_msg_override in call_api)" \
  "$(grep -qF '${_msg_override:-${_messages:-}}' "$LEX_BIN" && echo 1 || echo 0)"
check "quelle (_tools_off in _build_tools)" \
  "$(grep -qF '_tools_off:-}' "$LEX_BIN" && echo 1 || echo 0)"
help_out="$(LEX_MOCK="done" "$LEX_BIN" --help 2>&1)"
contains "help (nennt /compact)" "/compact" "$help_out"
contains "help (nennt LEX_COMPACT ENV)" "LEX_COMPACT" "$help_out"

echo "[INFO] Config-Tier + /status"
st="$(LEX_MOCK="done" "$LEX_BIN" --status 2>&1)"
contains "status (compact-Zeile Default)" "compact   : on · schwelle 160224 · keep 15000 · buffer 20000" "$st"
contains "status (ctx-Zeile Default)" "ctx       : ?/180224" "$st"
st2="$(LEX_MOCK="done" LEX_CTX_LIMIT=50000 LEX_COMPACT_KEEP=1234 LEX_COMPACT=off "$LEX_BIN" --status 2>&1)"
contains "status (ENV ctx 50000 → schwelle 30000)" "schwelle 30000" "$st2"
contains "status (ENV keep 1234)" "keep 1234" "$st2"
contains "status (ENV compact off)" "compact   : off" "$st2"
st3="$(LEX_MOCK="done" LEX_CTX_LIMIT=xyz LEX_COMPACT_KEEP=abc LEX_COMPACT=vielleicht "$LEX_BIN" --status 2>&1)"
contains "status (kaputtes ctx → Default-Schwelle)" "schwelle 160224" "$st3"
contains "status (kaputtes keep → 15000)" "keep 15000" "$st3"
contains "status (kaputtes compact → on)" "compact   : on" "$st3"

echo "[INFO] Inert: Defaults lösen KEINE Compaction aus"
out="$(LEX_MOCK="done" "$LEX_BIN" --oneshot <<< 'hallo' 2>"$TMP/inert.err")"
assert "inert (Antwort)" "Taugt." "$out"
not_contains "inert (keine 🗜-Meldung)" "kompaktiert" "$(cat "$TMP/inert.err")"
rec="$(grep -h '"type":"compaction"' "$LEX_HOME"/sessions/*/session.jsonl 2>/dev/null | wc -l | tr -d ' ')"
assert "inert (kein compaction-Record)" "0" "$rec"

echo "[INFO] /compact force (oneshot, leerer Kontext)"
rc=0
out="$(LEX_MOCK="done" "$LEX_BIN" --oneshot <<< '/compact' 2>"$TMP/force.err")" || rc=$?
assert "force (rc)" "0" "$rc"
contains "force (Meldung)" "Nichts zu kompaktieren" "$(cat "$TMP/force.err")"

echo "[INFO] /compact force (REPL unter PTY)"
repl_out="$(printf '/compact\n/exit\n' | LEX_MOCK="done" \
  timeout 30 script -qec "bash '$LEX_BIN'" /dev/null 2>&1 | tr -d '\r')"
contains "pty /compact (Meldung)" "Nichts zu kompaktieren" "$repl_out"
contains "pty /compact (Tschüss)" "Tschüss" "$repl_out"
not_contains "pty /compact (kein Modell-Call)" "Taugt." "$repl_out"

echo "[INFO] Auto-Trigger unter erzwungener Schwelle (PTY, 2 Turns)"
export LEX_HOME="$TMP/trig"
export LEX_MOCK="done" LEX_CTX_LIMIT=100 LEX_COMPACT_KEEP=10 LEX_TRACE=1
trig_out="$(printf 'Das ist eine längere erste Frage mit reichlich Inhalt damit der Kopf messbar größer wird und die Zusammenfassung ihn ersetzen kann, bitte ausführen.\nDie zweite Frage nach der ersten: geht der Tausch sauber durch?\n/exit\n' \
  | timeout 30 script -qec "bash '$LEX_BIN'" /dev/null 2>&1 | tr -d '\r')"
unset LEX_MOCK LEX_CTX_LIMIT LEX_COMPACT_KEEP LEX_TRACE
contains "trigger (🗜-Meldung)" "Kontext kompaktiert" "$trig_out"
sfile="$(ls "$LEX_HOME"/sessions/*/session.jsonl 2>/dev/null | head -1)"
check "trigger (session.jsonl existiert)" "$([[ -s "$sfile" ]] && echo 1 || echo 0)"
rec="$(grep -h '"type":"compaction"' "$sfile" 2>/dev/null | head -1)"
contains "trigger (Record-Typ)" '"type":"compaction"' "$rec"
if jq -e '.type == "compaction" and (.estimate_before > 0) and (.kept_units >= 1)
          and (.estimate_after > 0) and (.summary_chars > 0)' \
       >/dev/null 2>&1 <<< "$rec"; then
  printf '  [PASS] trigger (Record-Felder plausibel)\n'
else
  printf '  [FAIL] trigger (Record-Felder plausibel): %s\n' "$rec" >&2; FAIL=1
fi
contains "trigger (beide Turns beantwortet)" "Taugt." "$trig_out"
c_count="$(grep -c 'Kontext kompaktiert' <<< "$trig_out" 2>/dev/null || true)"
[[ "$c_count" =~ ^[0-9]+$ ]] || c_count=0
check "trigger (genau EINE Kompaktierung)" "$([[ "$c_count" == "1" ]] && echo 1 || echo 0)"
logc="$(count_of 'compact: ~' "$LEX_HOME/log/lex.log")"
check "trigger (Logzeile geschrieben)" "$([[ "$logc" -ge 1 ]] && echo 1 || echo 0)"

echo "[INFO] Fail-safe: leeres Summary (PTY + Mock-File)"
export LEX_HOME="$TMP/failsafe"
mf="$TMP/failsafe_mock.jsonl"
printf '%s\n%s\n%s\n' \
  '{"choices":[{"index":0,"message":{"role":"assistant","content":"Erste Antwort ok.","tool_calls":[]},"finish_reason":"stop"}]}' \
  '{"choices":[{"index":0,"message":{"role":"assistant","content":"","tool_calls":[]},"finish_reason":"stop"}]}' \
  '{"choices":[{"index":0,"message":{"role":"assistant","content":"Zweite Antwort trotz Fehler.","tool_calls":[]},"finish_reason":"stop"}]}' \
  > "$mf"
export LEX_MOCK_FILE="$mf" LEX_CTX_LIMIT=100 LEX_COMPACT_KEEP=10 LEX_TRACE=1
fs_out="$(printf 'Längere erste Frage mit genug Inhalt, damit der Kopf beim Tausch eine Rolle spielt und ersetzt werden soll, bitte ausführen.\nZweite Frage nach dem fehlgeschlagenen Swap — läuft die Antwort noch?\n/exit\n' \
  | timeout 30 script -qec "bash '$LEX_BIN'" /dev/null 2>&1 | tr -d '\r')"
unset LEX_MOCK_FILE LEX_CTX_LIMIT LEX_COMPACT_KEEP LEX_TRACE
contains "failsafe (klare Meldung)" "lieferte keinen Inhalt" "$fs_out"
sfile="$(ls "$LEX_HOME"/sessions/*/session.jsonl 2>/dev/null | head -1)"
rec="$(grep -h '"type":"compaction"' "$sfile" 2>/dev/null | wc -l | tr -d ' ')"
assert "failsafe (KEIN compaction-Record)" "0" "$rec"
contains "failsafe (Turn 2 läuft weiter)" "Zweite Antwort trotz Fehler." "$fs_out"
not_contains "failsafe (kein 🗜)" "Kontext kompaktiert" "$fs_out"
logc="$(count_of 'leeres Summary' "$LEX_HOME/log/lex.log")"
check "failsafe (Log: leeres Summary)" "$([[ "$logc" -ge 1 ]] && echo 1 || echo 0)"

echo "[INFO] Unit-Tests (source, Muster test_sse)"
export LEX_HOME="$TMP/units"
export LEX_MODEL="$TMP/model.gguf"
mkdir -p "$LEX_HOME"
mf2="$TMP/units_mock.jsonl"
printf '%s\n%s\n%s\n%s\n' \
  '{"choices":[{"index":0,"message":{"role":"assistant","content":"## Ziel\n- Zusammenfassung aus Mock.","tool_calls":[]},"finish_reason":"stop"}]}' \
  '{"choices":[{"index":0,"message":{"role":"assistant","content":"","tool_calls":[]},"finish_reason":"stop"}]}' \
  '{"choices":[{"index":0,"message":{"role":"assistant","content":"## Ziel\n- Zweite Zusammenfassung.","tool_calls":[]},"finish_reason":"stop"}]}' \
  '{"choices":[{"index":0,"message":{"role":"assistant","content":"## Ziel\n- Dritte Zusammenfassung nach auto.","tool_calls":[]},"finish_reason":"stop"}]}' \
  > "$mf2"
export LEX_MOCK_FILE="$mf2"
source "$LEX_DIR/lex" < /dev/null > /dev/null 2>&1 || {
  echo "FEHLSCHLAG: $LEX_DIR/lex nicht ladbar" >&2
  exit 1
}

# Audit-Lücke 2026-10-08: der Quell-Anker oben prüft nur das Schlüsselwort
# `_tools_off:-}` — der BODY war nie geprüft. Funktional hier, nach dem Source:
# der Summary-Request der Compaction darf EXAKT [] liefern, der Normal-
# Request muss die Werkzeug-Schemata enthalten.
tb_on="$(_build_tools)"
_tools_off=1
tb_off="$(_build_tools)"
_tools_off=""
assert "tools_off (Summary-Request exakt [])" "[]" "$tb_off"
contains "tools_off (Normal-Request enthält Werkzeuge)" '"name": "browser"' "$tb_on"

# --- _pairing_ok -----------------------------------------------------------
pair_ok='[{"role":"system","content":"s"},{"role":"user","content":"u"},{"role":"assistant","content":"a"}]'
_pairing_ok <<< "$pair_ok" >/dev/null 2>&1 && check "pairing (gültig) " 1 || check "pairing (gültig)" 0
bad1='[{"role":"system","content":"s"},{"role":"assistant","content":"a","tool_calls":[{"id":"c1","type":"function","function":{"name":"bash","arguments":"{}"}}]},{"role":"tool","tool_call_id":"c9","content":"x"}]'
_pairing_ok <<< "$bad1" >/dev/null 2>&1 && check "pairing (tool ohne call → 1)" 0 || check "pairing (tool ohne call → 1)" 1
bad2='[{"role":"system","content":"s"},{"role":"user","content":"u"},{"role":"assistant","content":"","tool_calls":[{"id":"c1","type":"function","function":{"name":"bash","arguments":"{}"}}]}]'
_pairing_ok <<< "$bad2" >/dev/null 2>&1 && check "pairing (offenes tool_calls am Ende → 1)" 0 || check "pairing (offenes tool_calls am Ende → 1)" 1
nudge='[{"role":"system","content":"s"},{"role":"assistant","content":"","tool_calls":[{"id":"c1","type":"function","function":{"name":"bash","arguments":"{}"}}]},{"role":"user","content":"nudge"},{"role":"assistant","content":"fertig"}]'
_pairing_ok <<< "$nudge" >/dev/null 2>&1 && check "pairing (Nudge-Case erlaubt)" 1 || check "pairing (Nudge-Case erlaubt)" 0
answered='[{"role":"system","content":"s"},{"role":"assistant","content":"","tool_calls":[{"id":"c1","type":"function","function":{"name":"bash","arguments":"{}"}}]},{"role":"tool","tool_call_id":"c1","content":"ok"}]'
_pairing_ok <<< "$answered" >/dev/null 2>&1 && check "pairing (beantwortetes Paar)" 1 || check "pairing (beantwortetes Paar)" 0
check "pairing (zu kurz → 1)" "$(_pairing_ok <<< '[{"role":"system","content":"s"}]' >/dev/null 2>&1; echo $?)"
dbl='[{"role":"system","content":"s"},{"role":"assistant","content":"","tool_calls":[{"id":"c1","type":"function","function":{"name":"bash","arguments":"{}"}}]},{"role":"tool","tool_call_id":"c1","content":"a"},{"role":"tool","tool_call_id":"c1","content":"b"}]'
_pairing_ok <<< "$dbl" >/dev/null 2>&1 && check "pairing (doppelte Antwort → 1)" 0 || check "pairing (doppelte Antwort → 1)" 1

# --- _compact_units --------------------------------------------------------
units_in='[{"role":"user","content":"frage"},{"role":"assistant","content":"","tool_calls":[{"id":"c1","type":"function","function":{"name":"bash","arguments":"{}"}}]},{"role":"tool","tool_call_id":"c1","content":"r1"},{"role":"tool","tool_call_id":"c2","content":"r2"},{"role":"assistant","content":"fertig"}]'
units_out="$(printf '%s' "$units_in" | _compact_units)"
assert "units (3 Einheiten, pair=1..3)" \
  '[{"s":0,"e":0,"k":"user"},{"s":1,"e":3,"k":"pair"},{"s":4,"e":4,"k":"assistant"}]' \
  "$units_out"

# --- _compact_threshold ----------------------------------------------------
_ctx_limit=180224 _max_tokens=16384 _compact_buffer=20000
assert "schwelle (Default 160224)" "160224" "$(_compact_threshold)"
_ctx_limit=0
assert "schwelle (ctx 0 → 0)" "0" "$(_compact_threshold)"
_ctx_limit=180224 _max_tokens=30000
assert "schwelle (out > buffer)" "150224" "$(_compact_threshold)"

# --- _compact_estimate -----------------------------------------------------
assert "estimate (400 Bytes → 133)" "133" "$(_compact_estimate "$(printf 'x%.0s' {1..400})")"

# --- _compact_serialize ----------------------------------------------------
ser="$(_compact_serialize "$units_in" 2000)"
contains "serialize ([Nutzer])" "[Nutzer]: frage" "$ser"
contains "serialize ([Modell])" "[Modell]: fertig" "$ser"
contains "serialize ([Werkzeugaufruf])" "[Werkzeugaufruf]: bash({})" "$ser"
contains "serialize ([Werkzeug-Ergebnis])" "[Werkzeug-Ergebnis]: r1" "$ser"
big_tool="$(jq -cn --arg c "$(printf 'y%.0s' {1..3000})" '[{"role":"system","content":"s"},{"role":"tool","tool_call_id":"c1","content":$c}]')"
ser2="$(_compact_serialize "$big_tool" 2000)"
contains "serialize (Kürzung > 2000 → [abgeschnitten])" "[abgeschnitten]" "$ser2"

# --- _compact_run: force-Swap --------------------------------------------
_ctx_limit=100 _max_tokens=16384 _compact_buffer=20000 _compact_keep=10
_compact=on _compact_count=0 _turn_count=7
_messages="$(jq -cn '[{role:"system",content:"SYS-PROMPT-SEHR-LANG"},
  {role:"user",content:"Längere erste Frage mit reichlich Inhalt, damit der Kopf messbar größer wird und eindeutig ersetzt werden muss."},
  {role:"assistant",content:"Antwort eins."}]')"
tc_before="$_turn_count"
_compact_run force; rc=$?
assert "swap (rc 0)" "0" "$rc"
assert "swap (turn_count unverändert)" "$tc_before" "$_turn_count"
assert "swap (count +1)" "1" "$_compact_count"
slot1="$(jq -r '.[1].content' <<< "$_messages" 2>/dev/null)"
contains "swap (Marker in Slot 1)" "<!--lex-compact-->" "$slot1"
check "swap (pairing_ok nach dem Swap)" "$(_pairing_ok <<< "$_messages" >/dev/null 2>&1 && echo 1 || echo 0)"
assert "swap (Länge 3 = sys+summary+tail)" "3" "$(jq 'length' <<< "$_messages")"
assert "swap (system unverändert)" "system" "$(jq -r '.[0].role' <<< "$_messages")"
contains "swap (Summary-Inhalt drin)" "Zusammenfassung aus Mock" "$slot1"
logc="$(count_of 'compact: ~' "$LEX_HOME/log/lex.log")"
check "swap (Log geschrieben)" "$([[ "$logc" -ge 1 ]] && echo 1 || echo 0)"
spanc="$(count_of '"name":"compact"' "$LEX_HOME/log/spans.jsonl")"
check "swap (span geschrieben)" "$([[ "$spanc" -ge 1 ]] && echo 1 || echo 0)"

# --- G4: leeres Summary → _messages byte-identisch ------------------------
# Erst anreichern: ohne Kopf würde force vor dem Call an G2 abbrechen.
append_message user "Zwischenfrage mit etwas mehr Text, damit beim nächsten force-Versuch garantiert ein Kopf existiert."
append_message assistant "Zwischen-Antwort."
snap="$(md5sum <<< "$_messages" | cut -d' ' -f1)"
_compact=on _compact_run force; rc=$?
assert "G4 (rc 1 bei leerem Summary)" "1" "$rc"
assert "G4 (_messages byte-identisch)" "$snap" "$(md5sum <<< "$_messages" | cut -d' ' -f1)"
assert "G4 (count unverändert)" "1" "$_compact_count"

# --- Zweite Kompaktierung: Prior-Summary wird ersetzt, nie gestapelt ------
append_message user "Zweite Runde: weitermachen mit dem Plan, das Vorhaben ist noch nicht fertig und braucht mehr Kontext."
append_message assistant "Erledigt — zweite Antwort steht."
_compact_run force; rc=$?
assert "recompact (rc 0)" "0" "$rc"
assert "recompact (count 2)" "2" "$_compact_count"
markers="$(grep -o '<!--lex-compact-->' <<< "$_messages" | wc -l | tr -d ' ')"
assert "recompact (genau EIN Marker)" "1" "$markers"
contains "recompact (Marker bleibt Slot 1)" "<!--lex-compact-->" "$(jq -r '.[1].content' <<< "$_messages" | head -c 40)"
check "recompact (pairing_ok)" "$(_pairing_ok <<< "$_messages" >/dev/null 2>&1 && echo 1 || echo 0)"
assert "recompact (Slot 0 bleibt system)" "system" "$(jq -r '.[0].role' <<< "$_messages")"

# --- Auto-Weg: LEX_COMPACT=off spart, force arbeitet trotzdem -------------
# Zustand so anreichern, dass der Auto-Weg echt etwas zu tun hätte.
append_message user "Dritte Runde: jetzt brauche ich wieder mehr Kontext, bitte erneut zusammenfassen und weitermachen."
append_message assistant "Erledigt — dritte Antwort steht."
snap="$(md5sum <<< "$_messages" | cut -d' ' -f1)"
_compact=off
_compact_run; rc=$?
assert "off (auto rc 0, nichts passiert)" "0" "$rc"
assert "off (_messages unverändert)" "$snap" "$(md5sum <<< "$_messages" | cut -d' ' -f1)"
assert "off (count unverändert)" "2" "$_compact_count"
_compact=on
_compact_run; rc=$?
check "off (auto mit on → Swap)" "$([[ "$rc" == "0" && "$_compact_count" == "3" ]] && echo 1 || echo 0)"

# --- HUD ctx% (funktionell) ------------------------------------------------
export LEX_TRACE=1
_ctx_limit=180224 _last_prompt_tokens=65536 _last_completion_tokens=42
hud="$({ _trace_hud 0; } 2>&1)"
contains "hud (ctx 65536/180224 = 36%)" "tokens 65536/180224 (36%) prompt + 42 completion" "$hud"
_ctx_limit=0
_last_prompt_tokens=999
hud2="$({ _trace_hud 0; } 2>&1)"
contains "hud (ohne Limit → alte Formel)" "tokens 999 prompt + 42 completion" "$hud2"
_ctx_limit=180224 _last_prompt_tokens=""
hud3="$({ _trace_hud 0; } 2>&1)"
contains "hud (ohne usage → ?/limit)" "tokens ?/180224 prompt" "$hud3"
unset LEX_TRACE

echo ""
if (( FAIL > 0 )); then
  printf 'FEHLSCHLAG: %s Test(s) in test_compaction.sh\n' "$FAIL" >&2
  exit 1
fi
echo "test_compaction.sh grün. ✓"
exit 0
