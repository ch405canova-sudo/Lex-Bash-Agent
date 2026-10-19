#!/usr/bin/env bash
# amnesie_test_setup.sh — saubere Gedächtnis-Basis für lex-Amnesie-Tests (§7/106).
#
# Warum: lex zieht Gedächtnis aus ~/.lex/mem (Notizen), ~/.lex/sessions (Logs),
# dem gemeinsamen Wiki (${_ai_dir}/wiki — INKL. des gemeinsamen Wiki-Logbuchs mit
# Experiment-Auswertungen!) und dem KV-Cache des llama-servers. Für echte
# Amnesie-Tests muss ALLES davon weg — sonst lernt lex aus Vorläufer-Läufen
# und gibt sie als eigene Arbeit aus (Fund 2026-10-14, §7/106 Lauf2).
#
# Nutzung:
#   tools/amnesie_test_setup.sh                  # räumt mem+Sessions (Keyword honeypot|dnat)
#   tools/amnesie_test_setup.sh --keyword 'x|y'  # eigenes Keyword (regex)
#   tools/amnesie_test_setup.sh --dry-run        # nur anzeigen, nichts verschieben
#   tools/amnesie_test_setup.sh --restart        # zusätzlich llama-server neu (leert Cache)
#   tools/amnesie_test_setup.sh --help           # diese Hilfe
#
# Danach lex starten mit:
#   export LEX_WIKI_DIR=<Backup-Verzeichnis>/wiki   # leeres Wiki (Wiki-Log bleibt draußen)
#   lex
#
# Rückgängig: alles liegt gesichert unter /tmp/opencode/amnesie-<ts>/ (cp zurück).
# Nichts wird gelöscht — nur verschoben.
set -euo pipefail

keyword='honeypot|dnat'
dry=0
restart=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --keyword) keyword="${2:?--keyword braucht einen Wert}"; shift 2 ;;
    --dry-run) dry=1; shift ;;
    --restart) restart=1; shift ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unbekannter Parameter: $1 (--help)" >&2; exit 2 ;;
  esac
done

mem_dir="${HOME}/.lex/mem"
ses_dir="${HOME}/.lex/sessions"
BK="/tmp/opencode/amnesie-$(date +%Y%m%d-%H%M%S)"
wiki_empty="$BK/wiki"

echo "== Amnesie-Setup (Keyword: ${keyword}) =="
[[ $dry -eq 1 ]] && echo "[dry-run] nichts wird verschoben"

# 1. mem-Notizen (sichern + entfernen)
treffer=()
while IFS= read -r f; do [[ -n "$f" ]] && treffer+=("$f"); done < <(grep -il "$keyword" "$mem_dir"/*.md 2>/dev/null || true)
echo "mem: ${#treffer[@]} Notiz(en)"
for f in "${treffer[@]:-}"; do
  [[ -z "$f" ]] && continue
  echo "  $(basename "$f")"
  if [[ $dry -eq 0 ]]; then mkdir -p "$BK/mem"; mv "$f" "$BK/mem/"; fi
done

# 2. Sessions (sichern + entfernen)
s_count=0
while IFS= read -r s; do
  [[ -z "$s" ]] && continue
  d=$(dirname "$s")
  s_count=$((s_count + 1))
  echo "  Session $(basename "$d")"
  if [[ $dry -eq 0 ]]; then mkdir -p "$BK/sessions"; mv "$d" "$BK/sessions/"; fi
done < <(grep -ril "$keyword" "$ses_dir"/*/session.jsonl 2>/dev/null || true)
echo "Sessions: $s_count"

# 3. Kontrolle + leeres Wiki anlegen
if [[ $dry -eq 0 ]]; then
  rest_mem=$(grep -ril "$keyword" "$mem_dir"/*.md 2>/dev/null | wc -l)
  rest_ses=$(grep -ril "$keyword" "$ses_dir"/*/session.jsonl 2>/dev/null | wc -l)
  echo "Kontrolle: mem ${rest_mem}, sessions ${rest_ses} (0 = sauber)"
  mkdir -p "$wiki_empty"
fi

# 4. Hinweise für den Test-Lauf (Wiki-Override + Cache)
echo
echo "== Für den Test-Lauf =="
if [[ $dry -eq 0 ]]; then
  echo "  export LEX_WIKI_DIR=${wiki_empty}    # leeres Wiki — lex findet dort kein Log"
else
  echo "  export LEX_WIKI_DIR=<Backup>/wiki"
fi
if [[ $restart -eq 0 ]]; then
  echo "  Hinweis: llama-server neu starten, damit der KV-Cache leer ist (--restart erledigt das)"
fi

# 5. optionaler Server-Neustart (leert den KV-Cache des Modells)
if [[ $restart -eq 1 && $dry -eq 0 ]]; then
  pid=$(pgrep -x -o llama-server || true)
  if [[ -n "$pid" ]]; then
    mapfile -d '' args < "/proc/$pid/cmdline"
    echo
    echo "== Server-Neustart (PID ${pid}) =="
    kill "$pid"
    for _ in $(seq 1 20); do pgrep -x llama-server >/dev/null || break; sleep 1; done
    setsid "${args[@]}" >/tmp/opencode/amnesie-llama.log 2>&1 &
    for i in $(seq 1 60); do
      if curl -s -o /dev/null --max-time 2 http://127.0.0.1:8080/health; then
        echo "  Server neu (PID $(pgrep -x -o llama-server), ${i}s) ✓"
        break
      fi
      sleep 1
    done
  else
    echo "  kein llama-server aktiv — nichts zu neustarten"
  fi
fi

if [[ $dry -eq 0 && ( ${#treffer[@]} -gt 0 || $s_count -gt 0 ) ]]; then
  echo
  echo "Backups: ${BK} (cp -r zurück nach ~/.lex für Rückkehr)"
fi
