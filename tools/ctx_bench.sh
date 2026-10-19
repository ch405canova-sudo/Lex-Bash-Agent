#!/usr/bin/env bash
# ctx_bench.sh — Kontext-Wachstums-Bench gegen llama-server (AUDIT-ctx-performance §4).
#
# Misst pro Turn: TTFT (time_starttransfer), prompt_tokens (usage), und schreibt
# eine Zeile pro Turn. Die messages-Array wächst pro Turn um einen Chat-Block
# (user+assistant) bis --target-tokens erreicht. Cache-Hit = TTFT bleibt flach,
# Cache-Miss/Reprocessing = TTFT-Sprung. prompt eval tok/s steht zusätzlich im
# Server-Log (Flag --metrics).
#
# Nutzung:
#   tools/ctx_bench.sh --label stufe0 [--target 160000] [--block-chars 40000]
#                      [--reps 3] [--max-tokens 16] [--url http://127.0.0.1:8080]
# Ausgabe: /tmp/opencode/ctx-bench/<label>/turns.tsv (TSV: rep turn ttft_s prompt_tokens http_code)
set -euo pipefail

target=160000
block=40000
reps=3
max_tokens=16
url="http://127.0.0.1:8080"
label="bench"
compact_at=0
keep_tokens=15000
block_tag=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)      target="$2"; shift 2 ;;
    --block-chars) block="$2"; shift 2 ;;
    --reps)        reps="$2"; shift 2 ;;
    --max-tokens)  max_tokens="$2"; shift 2 ;;
    --url)         url="$2"; shift 2 ;;
    --label)       label="$2"; shift 2 ;;
    --compact-at)  compact_at="$2"; shift 2 ;;
    --keep)        keep_tokens="$2"; shift 2 ;;
    --block-tag)   block_tag="$2"; shift 2 ;;
    -h|--help)     sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unbekannt: $1 (--help)" >&2; exit 2 ;;
  esac
done

out="/tmp/opencode/ctx-bench/${label}"
mkdir -p "$out"
tsv="$out/turns.tsv"
[[ -f "$tsv" ]] || printf 'rep\tturn\tttft_s\tprompt_tokens\thttp_code\n' > "$tsv"

# System-Prompt: repräsentativer Festtext (~10k Tokens), Historie ist die eigentliche Masse.
sys_block="$(head -c 40000 /dev/zero | tr '\0' 'x')"
user_block="$(head -c "$block" /dev/zero | tr '\0' 'y')"

echo "== ctx_bench label=$label target=$target block=$block reps=$reps url=$url =="

for rep in $(seq 1 "$reps"); do
  hist_file="$out/hist-$rep.json"
  compacted=0
  jq -n --arg s "$sys_block" '[{role:"system",content:$s}]' > "$hist_file"
  turn=0
  while :; do
    turn=$((turn + 1))
    # gemessener Prompt-Umfang: grobe Schätzung aus der Historiengröße (Zeichen/4)
    est=$(( $(wc -c < "$hist_file") / 4 ))
    [[ $est -ge $target ]] && break

    # Wachstum: user + assistant-Block (optionaler Turn-Tag: macht jeden Block
    # inhaltlich eindeutig — nötig, um Token-Identität bei Compaction zu prüfen)
    jq --arg u "$user_block" --argjson t "$turn" --argjson tag "$block_tag" '
      . + [{role:"user",
            content:(if $tag == 1 then "[T" + ($t|tostring) + "] " + $u else $u end)},
           {role:"assistant",content:"ok"}]' \
      "$hist_file" > "$hist_file.new" && mv "$hist_file.new" "$hist_file"

    # Payload als Datei: ein curl-ARG-String darf max. 128 KiB sein (Linux E2BIG)
    payload_file="$out/payload-$rep-$turn.json"
    jq -n --slurpfile m "$hist_file" \
      --argjson mt "$max_tokens" \
      '{model:"bench", messages:$m[0], max_tokens:$mt, temperature:0}' > "$payload_file"
    resp="$out/resp-$rep-$turn.json"
    meta=$(curl -sS -o "$resp" -w '%{time_starttransfer}\t%{http_code}' \
      --max-time 600 -H 'Content-Type: application/json' \
      --data-binary "@$payload_file" "$url/v1/chat/completions" || printf 'NA\t000')
    ttft=${meta%%$'\t'*}
    code=${meta##*$'\t'}
    ptoks=$(jq -r '.usage.prompt_tokens // 0' "$resp" 2>/dev/null || echo 0)
    printf '%s\t%s\t%s\t%s\t%s\n' "$rep" "$turn" "$ttft" "$ptoks" "$code" >> "$tsv"
    printf '[rep %s turn %2s] ttft=%ss prompt_tokens=%s http=%s\n' \
      "$rep" "$turn" "$ttft" "$ptoks" "$code"
    if [[ "$code" != "200" ]]; then
      echo "Fehler-Body: $([[ -f "$resp" ]] && head -c 300 "$resp" || echo "(keine Antwortdatei)")" >&2
      break 2
    fi
    rm -f "$resp" "$payload_file"

    # Compaction (Stufe 5): bei --compact-at die Historie kürzen (system + die
    # letzten Turns bis --keep Tokens), dann weiterwachsen bis --target.
    # Der folgende Turn misst die Compaction-Kosten (Re-Prefill) und den TTFT-Drop.
    if [[ "$compact_at" -gt 0 && "$compacted" -eq 0 && "$ptoks" -ge "$compact_at" ]]; then
      keep_chars=$((keep_tokens * 4))
      jq --argjson k "$keep_chars" '
        .[0] as $sys | .[1:] | reverse
        | reduce .[] as $m ({acc: [], sum: 0};
            if .sum < $k
            then .acc += [$m] | .sum += ((($m.content // "") | tostring) | length)
            else . end)
        | .acc | reverse | [ $sys ] + .' "$hist_file" > "$hist_file.new" \
        && mv "$hist_file.new" "$hist_file"
      compacted=1
      printf '%s\t%s\t%s\t%s\t%s\n' "$rep" "compact" "-" "-" "-" >> "$tsv"
      echo "[rep $rep] COMPACTION bei ${ptoks} Tokens → keep ${keep_tokens} Tokens (neue hist: \
$(( $(wc -c < "$hist_file") / 4 )) tok geschätzt)"
    fi
    [[ "$ptoks" -ge $target ]] && break
  done
done

echo "Ergebnis: $tsv"
awk -F'\t' 'NR>1 {n++; if ($3+0>max) max=$3+0; sum+=$3}
  END {if (n) printf "Turns: %d | TTFT min/Ø/max: - / %.2fs / %.2fs\n", n, sum/n, max}' "$tsv"
