#!/usr/bin/env bash
# werkstatt_index.sh — refresh the AUTO block in the workshop index
#
#   werkstatt_index.sh          rewrite the AUTO block
#   werkstatt_index.sh --check  only print to stdout (dry run), rc=0
#
# Target:   $LEX_HTOOLS_DIR/WERKSTATT.md  (default ${HOME}/H-Tools)
# Markers:  <!-- AUTO-START --> … <!-- AUTO-END --> (exactly one each)
# Candidates: root binary OR directory inside the workshop folder;
#   version only for executable files (no PATH lookup, full paths).
set -euo pipefail

HT="${LEX_HTOOLS_DIR:-${HOME}/H-Tools}"
TARGET="$HT/WERKSTATT.md"
CHECK=0
# M13 (audit 2026-10-08): reject foreign arguments hard. Before a typo
# (`--chek`) was silently swallowed and the run WROTE — exactly the dry run
# in question was ignored.
(( $# <= 1 )) || {
  echo "werkstatt_index: too many arguments ($#) — allowed: --check" >&2
  exit 2
}
case "${1:-}" in
  "") ;;
  --check) CHECK=1 ;;
  *) echo "werkstatt_index: unknown argument: $1 (known: --check)" >&2; exit 2 ;;
esac

# Workshop tools in the order of WERKSTATT.md; differing version flags
declare -A VER_FLAG=([ffuf]="-V" [velociraptor]="version")
CANDIDATES=(subfinder amass httpx katana ffuf naabu nuclei trivy swaks
            theHarvester spiderfoot cowrie velociraptor owasp-zap)

find_tool() {  # $1 = tool name → executable path or directory
  local t="$1"
  if [[ -f "$HT/$t" && -x "$HT/$t" ]]; then printf '%s\n' "$HT/$t"; return 0; fi
  if [[ -d "$HT/$t" ]]; then printf '%s\n' "$HT/$t/"; return 0; fi
  if command -v "$t" >/dev/null 2>&1; then command -v "$t"; return 0; fi
  return 1
}

get_version() {  # $1 = path, $2 = tool → version (72 chars, table-safe)
  local p="$1" t="$2" out="" line="" f
  if [[ -f "$p" && -x "$p" ]]; then
    local flags=("${VER_FLAG[$t]:---version}" "-V" "version")
    for f in "${flags[@]}"; do
      out="$(timeout 3 "$p" "$f" 2>&1 || true)"
      # recognise flag errors as such → next attempt
      [[ "$out" =~ flag\ provided|unknown\ (long\ )?flag|unrecognized|invalid\ option|usage: ]] && { out=""; continue; }
      [[ -n "$out" ]] && break
    done
  fi
  # strip ANSI escapes, then prefer the "Version:" line (banners without it are dropped)
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
  # markdown-table safe: remove pipes, strip control chars, truncate
  line="$(printf '%s' "$line" | tr -d '\r\000' | sed 's/|/\\|/g; s/^[[:space:]]*//; s/[[:space:]]*$//')"
  [[ ${#line} -gt 72 ]] && line="${line:0:69}…"
  printf '%s' "${line:-—}"
}

gen() {
  printf '<!-- AUTO-START -->\n'
  printf 'Recorded on %s by `tools/werkstatt_index.sh` (versions only for\nexecutable files, full paths, no PATH).\n\n' "$(date '+%F %T')"
  printf '| Tool | Version | Path |\n|---|---|---|\n'
  local t p v rel
  for t in "${CANDIDATES[@]}"; do
    if p="$(find_tool "$t")"; then
      v="$(get_version "$p" "$t")"
      rel="${p#"$HT"/}"
      printf '| `%s` | %s | `%s` |\n' "$t" "$v" "$rel"
    else
      printf '| `%s` | — | not in the workshop |\n' "$t"
    fi
  done
  printf '<!-- AUTO-END -->\n'
}

if [[ "$CHECK" == 1 ]]; then
  gen
  exit 0
fi

[[ -f "$TARGET" ]] || { echo "werkstatt_index: $TARGET not found" >&2; exit 1; }
n_start="$(grep -cF '<!-- AUTO-START -->' "$TARGET" || true)"
n_end="$(grep -cF '<!-- AUTO-END -->' "$TARGET" || true)"
[[ "$n_start" -ge 1 && "$n_end" -ge 1 ]] || {
  echo "werkstatt_index: markers missing in $TARGET (START=$n_start END=$n_end)" >&2
  exit 1
}
[[ "$n_start" == 1 && "$n_end" == 1 ]] ||
  echo "werkstatt_index: note — markers duplicated (START=$n_start END=$n_end), cleaning up" >&2
# line bounds: replace from the first START to the last END (markers stay outside)
s_line="$(grep -nF '<!-- AUTO-START -->' "$TARGET" | head -1 | cut -d: -f1)"
e_line="$(grep -nF '<!-- AUTO-END -->' "$TARGET" | tail -1 | cut -d: -f1)"
[[ "$s_line" -lt "$e_line" ]] || {
  echo "werkstatt_index: START (line $s_line) not before END (line $e_line) in $TARGET" >&2
  exit 1
}

# M13: temp file INSIDE the target directory — mktemp would otherwise land in
# /tmp (tmpfs) and `mv` across the filesystem boundary is no atomic replace
# any more (copy + delete, intermediate state readable).
tmp="$(mktemp "$HT/.werkstatt_index.XXXXXX")" || exit 1
trap 'rm -f "$tmp"' EXIT
head -n "$((s_line - 1))" "$TARGET" > "$tmp"
gen >> "$tmp"
tail -n "+$((e_line + 1))" "$TARGET" >> "$tmp"
mv "$tmp" "$TARGET"
trap - EXIT
echo "werkstatt_index: AUTO block in $TARGET refreshed (14 tool lines)"
