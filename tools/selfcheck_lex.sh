#!/usr/bin/env bash
#
# tools/selfcheck_lex.sh — statische Vollständigkeitsprüfung von lex.
#
# Warum (Fund 2026-10-10): `bash -n` und `shellcheck`
# prüfen NUR Syntax/Style. Ein Aufruf einer Funktion, die es gar nicht
# gibt, ist erst zur LAUFZEIT ein Fehler („Kommando nicht gefunden") —
# beide Werkzeuge melden ihn NICHT. Genau so landete der Tor-Stealth-Bau
# mit `_tor_stealth_start` im on-Branch und ohne Definition im Skript.
#
# Was geprüft wird:
#   1. bash -n                     Syntax
#   2. shellcheck -S warning       Style/Klarheit (falls installiert)
#   3. aufgerufene, aber NIE definierte interne Funktionen  ← die Lücke
#   4. Soll-Liste kritischer Kernfunktionen (Vollständigkeit der Datei)
#
# Aufruf:  tools/selfcheck_lex.sh [pfad/zu/lex]     (Default: ../lex)
# rc 0 = sauber, rc 1 = Befund (Meldungen auf stdout).
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEX="${1:-$here/../lex}"

fail=0
say() { printf '  [SELFCHECK] %s\n' "$*"; }
bad() { printf '  [SELFCHECK-FAIL] %s\n' "$*"; fail=1; }

[[ -f "$LEX" ]] || { bad "Skript nicht gefunden: $LEX"; exit 1; }

# --- 1. Syntax ---------------------------------------------------------------
if bash -n "$LEX" 2>/tmp/selfcheck.$$.err; then
  say "bash -n: ok"
else
  bad "bash -n:"; sed 's/^/      /' /tmp/selfcheck.$$.err >&2
fi
rm -f /tmp/selfcheck.$$.err

# --- 2. shellcheck (falls vorhanden) ----------------------------------------
if command -v shellcheck >/dev/null 2>&1; then
  if sc="$(shellcheck -S warning "$LEX" 2>&1)"; then
    say "shellcheck -S warning: ok"
  else
    bad "shellcheck -S warning:"; printf '%s\n' "$sc" | sed 's/^/      /' >&2
  fi
else
  say "shellcheck nicht installiert — übersprungen"
fi

# --- 3. Aufrufe ohne Definition ---------------------------------------------
# Definitionen: `^ _name()` sowie `function _name`.
# Referenzen:   (a) `_name(` mit Wortgrenze davor, (b) Zeilen, die genau
#               `_name` alleinstehen (das war der Fund 2026-10-10).
# Bewusster Scope: nur interne `_`-Namen. Andere interne Funktionen (ohne
# `_`, z.B. `run_turn`) werden über die Soll-Liste in 4 abgesichert.
# Kommentare (# am Zeilenanfang bzw. ab " #") werden ignoriert — sonst
# melden Kommentar-Hinweise wie „siehe _foo (…" eine Falschnadel.
# Ebenso ausgeschlossen: ein `$` direkt davor. `$_var (` ist eine
# Variablen-Expansion mit Klammer-Text (z.B. Log-Meldung
# "Sandbox $_sbx (Ziel …)"), nie ein Aufruf — sonst meldet ein harmloses
# Log-Argument eine Falschnadel, genau die Klasse, die Kommentare oben
# schon abfangen. Fund 2026-10-12.
defs="$(sed -nE 's/^[[:space:]]*(function[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*\(\).*/\2/p' "$LEX" | LC_ALL=C sort -u)"
src_nocomment="$(sed 's/[[:space:]]#.*$//' "$LEX" | grep -vE '^[[:space:]]*#')"
refs_a="$(printf '%s\n' "$src_nocomment" | grep -oE '(^|[^A-Za-z0-9_$])_[A-Za-z0-9_]+[[:space:]]*\(' | grep -oE '_[A-Za-z0-9_]+' | LC_ALL=C sort -u)"
refs_b="$(printf '%s\n' "$src_nocomment" | sed -nE 's/^[[:space:]]*(_[A-Za-z0-9_]+)[[:space:]]*$/\1/p' | LC_ALL=C sort -u)"
missing="$(comm -23 <(printf '%s\n%s\n' "$refs_a" "$refs_b" | LC_ALL=C sort -u | grep -v '^$') <(printf '%s\n' "$defs" | LC_ALL=C sort -u | grep -v '^$') || true)"
if [[ -n "$missing" ]]; then
  bad "aufgerufen, aber NIE definiert (wäre Laufzeitfehler):"
  printf '%s\n' "$missing" | sed 's/^/      /' >&2
else
  say "keine aufgerufene Funktion ohne Definition"
fi

# --- 4. Soll-Liste der Kernfunktionen ----------------------------------------
# (Ergänzen, wenn eine Kernfunktion umbenannt/entfernt wird — diese Liste
# fängt halbgeschriebene oder beschädigte Skripte, die `bash -n` noch
# akzeptiert.)
kritisch=(
  main run_turn call_api dispatch_tool agent_loop setup_messages
  load_config usage oneshot install_lex session_init
  cmd_lexpen _swap_slot0 _build_tools _run_hooks _run_limited
)
for f in "${kritisch[@]}"; do
  if ! printf '%s\n' "$defs" | grep -qx "$f"; then
    bad "Kernfunktion fehlt: $f()"
  fi
done
(( fail == 0 )) && say "Kernfunktionen vollständig (${#kritisch[@]} geprüft)"

# --- Ergebnis ----------------------------------------------------------------
if (( fail )); then
  printf 'FEHLSCHLAG: selfcheck %s\n' "$LEX" >&2
  exit 1
fi
printf 'selfcheck %s: ok\n' "$LEX"
exit 0
