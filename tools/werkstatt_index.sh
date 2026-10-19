#!/usr/bin/env bash
# werkstatt_index.sh — Auto-Block im Werkstatt-Index auffrischen
#
#   werkstatt_index.sh          schreibt den AUTO-Block neu
#   werkstatt_index.sh --check  erzeugt nur auf stdout (Dry-Run), rc=0
#
# Ziel:   $LEX_HTOOLS_DIR/WERKSTATT.md  (Default $HOME/H-Tools)
# Marker: <!-- AUTO-START --> … <!-- AUTO-END --> (genau je 1×)
# Kandidaten: Wurzel-Binärdatei ODER Verzeichnis im Werkstatt-Ordner;
#   Version nur bei ausführbaren Dateien (kein PATH-Zugriff, volle Pfade).
set -euo pipefail

HT="${LEX_HTOOLS_DIR:-$HOME/H-Tools}"
TARGET="$HT/WERKSTATT.md"
CHECK=0
# M13 (Audit 2026-10-08): fremde Argumente hart abweisen. Vorher fraß ein
# Tippfehler (`--chek`) still und der Lauf SCHRIEB — genau der Dry-Run, um den
# es ging, wurde ignoriert.
(( $# <= 1 )) || {
  echo "werkstatt_index: zu viele Argumente ($#) — erlaubt: --check" >&2
  exit 2
}
case "${1:-}" in
  "") ;;
  --check) CHECK=1 ;;
  *) echo "werkstatt_index: unbekanntes Argument: $1 (bekannt: --check)" >&2; exit 2 ;;
esac

# Werkstatt-Tools in Reihenfolge der WERKSTATT.md; abweichende Versions-Flags
declare -A VER_FLAG=([ffuf]="-V" [velociraptor]="version")
CANDIDATES=(subfinder amass httpx katana ffuf naabu nuclei trivy swaks
            theHarvester spiderfoot cowrie velociraptor owasp-zap
            interactsh dnsx gau)

find_tool() {  # $1 = Toolname → ausführbarer Pfad oder Verzeichnis
  local t="$1"
  if [[ -f "$HT/$t" && -x "$HT/$t" ]]; then printf '%s\n' "$HT/$t"; return 0; fi
  if [[ -d "$HT/$t" ]]; then printf '%s\n' "$HT/$t/"; return 0; fi
  if command -v "$t" >/dev/null 2>&1; then command -v "$t"; return 0; fi
  return 1
}

get_version() {  # $1 = Pfad, $2 = Tool → Version (72 Zeichen, Tabelle-sicher)
  local p="$1" t="$2" out="" line="" f
  if [[ -f "$p" && -x "$p" ]]; then
    local flags=("${VER_FLAG[$t]:---version}" "-V" "version")
    for f in "${flags[@]}"; do
      out="$(timeout 3 "$p" "$f" 2>&1 || true)"
      # Flag-Fehler als solche erkennen → nächster Versuch
      [[ "$out" =~ flag\ provided|unknown\ (long\ )?flag|unrecognized|invalid\ option|usage: ]] && { out=""; continue; }
      [[ -n "$out" ]] && break
    done
  fi
  # ANSI-Escapes raus, dann bevorzugt die „Version:"-Zeile (Banner ohne sie verwerfen)
  out="$(printf '%s' "$out" | sed $'s/\x1b\\[[0-9;]*[A-Za-z]//g')"
  local n
  n="$(printf '%s\n' "$out" | grep -c -v '^[[:space:]]*$' || true)"
  if [[ "$n" == 1 ]]; then
    line="$(printf '%s\n' "$out" | grep -m1 -v '^[[:space:]]*$')"
  else
    line="$(printf '%s\n' "$out" | grep -im1 'version' || true)"
    if [[ -z "$line" ]]; then
      line="$(printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | tail -1 || true)"
    fi
  fi
  # Markdown-Tabelle sicher: Pipe weg, Steuerzeichen raus, kürzen
  line="$(printf '%s' "$line" | tr -d '\r\000' | sed 's/|/\\|/g; s/^[[:space:]]*//; s/[[:space:]]*$//')"
  [[ ${#line} -gt 72 ]] && line="${line:0:69}…"
  printf '%s' "${line:-—}"
}

gen() {
  printf '<!-- AUTO-START -->\n'
  printf 'Erfasst am %s von `tools/werkstatt_index.sh` (Versionen nur bei\nausführbaren Dateien, volle Pfade, kein PATH).\n\n' "$(date '+%F %T')"
  printf '| Tool | Version | Pfad |\n|---|---|---|\n'
  local t p v rel
  for t in "${CANDIDATES[@]}"; do
    if p="$(find_tool "$t")"; then
      v="$(get_version "$p" "$t")"
      rel="${p#"$HT"/}"
      printf '| `%s` | %s | `%s` |\n' "$t" "$v" "$rel"
    else
      printf '| `%s` | — | nicht in der Werkstatt |\n' "$t"
    fi
  done
  printf '<!-- AUTO-END -->\n'
}

if [[ "$CHECK" == 1 ]]; then
  gen
  exit 0
fi

[[ -f "$TARGET" ]] || { echo "werkstatt_index: $TARGET nicht gefunden" >&2; exit 1; }
n_start="$(grep -cF '<!-- AUTO-START -->' "$TARGET" || true)"
n_end="$(grep -cF '<!-- AUTO-END -->' "$TARGET" || true)"
[[ "$n_start" -ge 1 && "$n_end" -ge 1 ]] || {
  echo "werkstatt_index: Marker fehlen in $TARGET (START=$n_start END=$n_end)" >&2
  exit 1
}
[[ "$n_start" == 1 && "$n_end" == 1 ]] ||
  echo "werkstatt_index: Hinweis — Marker doppelt (START=$n_start END=$n_end), wird bereinigt" >&2
# Zeilengrenzen: ab erstem START bis letztem END wird ersetzt (Marker bleiben draußen)
s_line="$(grep -nF '<!-- AUTO-START -->' "$TARGET" | head -1 | cut -d: -f1)"
e_line="$(grep -nF '<!-- AUTO-END -->' "$TARGET" | tail -1 | cut -d: -f1)"
[[ "$s_line" -lt "$e_line" ]] || {
  echo "werkstatt_index: START (Z.$s_line) nicht vor END (Z.$e_line) in $TARGET" >&2
  exit 1
}

# M13: Tempdatei IM Zielverzeichnis — mktemp landet sonst in /tmp (tmpfs) und
# `mv` über die Filesystemgrenze ist keine atomare Ersetzung mehr (kopieren +
# löschen, Zwischenstand lesbar).
tmp="$(mktemp "$HT/.werkstatt_index.XXXXXX")" || exit 1
trap 'rm -f "$tmp"' EXIT
head -n "$((s_line - 1))" "$TARGET" > "$tmp"
gen >> "$tmp"
tail -n "+$((e_line + 1))" "$TARGET" >> "$tmp"
mv "$tmp" "$TARGET"
trap - EXIT
echo "werkstatt_index: AUTO-Block in $TARGET erneuert (14 Tool-Zeilen)"
