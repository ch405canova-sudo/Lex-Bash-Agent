#!/usr/bin/env bash
#
# ai.sh — launcher for the local llama-server that lex talks to.
#
# Every path is configurable through the environment, so this script works
# on any machine without editing it. Defaults are shown below.
#
#   AI_MODE_DIR   model directory        (default: $HOME/ai-models)
#   AI_MODEL      file name of the GGUF  (default: Ternary-Bonsai-2-27B-PQ2_0.gguf)
#   AI_MODEL_PATH full path to the GGUF  (default: $AI_MODE_DIR/$AI_MODEL)
#   AI_LLAMA_BIN  llama-server binary    (default: $HOME/llama.cpp-prism/build/bin/llama-server)
#   AI_CTX        total context size     (default: 262144)
#   AI_PORT       listen port            (default: 8080)
#   AI_RUN_DIR    pid + logs             (default: $HOME/.lex/ai)
#   AI_WIKI_DIR   wiki root for `ai wiki`(default: $HOME/wiki)
#
# Commands:
#   ./ai.sh [start [1|2]]   start llama-server (1 = one 262k slot, 2 = split 2x128k)
#   ./ai.sh stop            stop every llama-server
#   ./ai.sh status          what is running
#   ./ai.sh chat            endpoint + curl smoke test
#   ./ai.sh wiki            list the wiki markdown files
#
set -u

HOST="${AI_HOST:-127.0.0.1}"
LLAMA_PORT="${AI_PORT:-8080}"
MODEL_DIR="${AI_MODE_DIR:-$HOME/ai-models}"
MODEL="${AI_MODEL:-Ternary-Bonsai-2-27B-PQ2_0.gguf}"
MODEL_PATH="${AI_MODEL_PATH:-$MODEL_DIR/$MODEL}"
CTX="${AI_CTX:-262144}"          # total context; per slot = CTX / slots
LLAMA_BIN="${AI_LLAMA_BIN:-$HOME/llama.cpp-prism/build/bin/llama-server}"
RUN_DIR="${AI_RUN_DIR:-$HOME/.lex/ai}"
LOGDIR="$RUN_DIR/logs"
PIDFILE="$RUN_DIR/ai.pid"
ASN_BIN="${AI_ASN_BIN:-$HOME/.local/bin/asn}"
WIKI_DIR="${AI_WIKI_DIR:-$HOME/wiki}"
CHAT_TEMPLATE="${AI_CHAT_TEMPLATE:-$MODEL_DIR/chat_template.jinja}"
KV_MEAN_CENTER="${AI_KV_MEAN_CENTER:-$MODEL_DIR/kv-mean-center-bonsai.gguf}"
REASONING_MSG="${AI_REASONING_MESSAGE:-Budget reached - give the best answer now, do not hesitate or doubt.}"

mkdir -p "$LOGDIR"

check_llama() { ss -tlnp 2>/dev/null | grep -q ":$LLAMA_PORT"; }

# --- start mode: 1 = standard (262k, 1 slot), 2 = split (2 x 128k) --------
AI_MODE=1   # menu selection (1|2), used by start_llama
R_NP=""     # slots of the running server
R_CTX=""    # total context of the running server

_mode_label() {
    local np="${1:-1}" ctx="${2:-$CTX}"
    if [ "$np" -gt 1 ]; then
        printf 'Split — %d slots x %d ctx, separate KV cache per slot, parallel requests' \
            "$np" "$((ctx / np))"
    else
        printf 'Standard — %d ctx, 1 slot (one client with the full context)' "$ctx"
    fi
}

# Read the running mode from /proc/<pid>/cmdline (no HTTP).
# Sets R_NP/R_CTX; returns 1 when no server is running.
_running_np() {
    R_NP=""
    R_CTX=""
    local pid i
    local -a args
    pid=$(pgrep -x -o llama-server 2>/dev/null) || return 1
    [ -n "$pid" ] && [ -r "/proc/$pid/cmdline" ] || return 1
    mapfile -d '' -t args < "/proc/$pid/cmdline" || return 1
    R_NP=1
    R_CTX=$CTX
    for ((i = 0; i < ${#args[@]}; i++)); do
        case "${args[i]}" in
            -np|--parallel) R_NP="${args[i + 1]:-1}" ;;
            -c|--ctx-size)  R_CTX="${args[i + 1]:-$CTX}" ;;
        esac
    done
    return 0
}

_menu_cursor_off() { printf '\033[?25l'; }
_menu_cursor_on()  { printf '\033[?25h'; }

# three-line block; $1 = 1 on the first call (otherwise move 3 lines up)
_menu_paint() {
    local m1=' ' m2=' '
    [ "$AI_MODE" = 1 ] && m1='>' || m2='>'
    [ "${1:-0}" = 1 ] || printf '\033[3A'
    printf '\r\033[2KSelect start mode  (up/down, Enter, 1/2, Esc)\n'
    printf '\r\033[2K%s 1  Standard   %d ctx, 1 slot\n' "$m1" "$CTX"
    printf '\r\033[2K%s 2  Split      2 x %d (128k), separate, parallel\n' "$m2" "$((CTX / 2))"
}

# Selection via cursor keys. Result in AI_MODE; return 1 = cancelled.
_pick_mode() {
    AI_MODE=1
    if [ ! -t 0 ] || [ ! -t 1 ]; then
        printf '  (not interactive -> mode 1: %s)\n' "$(_mode_label 1)"
        return 0
    fi
    local key rest
    _menu_cursor_off
    trap '_menu_cursor_on; trap - INT TERM; exit 130' INT TERM
    _menu_paint 1
    while true; do
        key=""
        if ! IFS= read -rsn1 key; then
            break
        fi
        if [ "$key" = $'\e' ]; then
            rest=""
            if IFS= read -rsn2 -t 0.2 rest 2>/dev/null; then
                key="$key$rest"
            fi
        fi
        case "$key" in
            $'\e[A'|$'\e[B') AI_MODE=$((3 - AI_MODE)); _menu_paint ;;
            1|2)             AI_MODE=$key; _menu_paint; break ;;
            ''|$'\r')        break ;;
            $'\e'|q|Q)
                _menu_cursor_on
                trap - INT TERM
                printf '  cancelled.\n'
                return 1
                ;;
        esac
    done
    _menu_cursor_on
    trap - INT TERM
    printf '  -> %s\n' "$(_mode_label "$AI_MODE")"
    return 0
}

start_llama() {
    local np="${1:-1}"
    if check_llama; then
        echo "ok  llama-server already running (port $LLAMA_PORT)"
        if _running_np; then
            echo "    active: $(_mode_label "$R_NP" "$R_CTX")"
            [ "$R_NP" != "$np" ] && echo "    to switch modes: ai stop, then ai start"
        fi
        return 0
    fi
    if [ ! -x "$LLAMA_BIN" ]; then
        echo "err llama-server binary not found: $LLAMA_BIN"
        echo "    set AI_LLAMA_BIN or build llama.cpp first"
        return 1
    fi
    if [ ! -f "$MODEL_PATH" ]; then
        echo "err model file not found: $MODEL_PATH"
        echo "    set AI_MODEL_PATH (or AI_MODE_DIR + AI_MODEL)"
        return 1
    fi

    # Model specific extras — only passed when the file is actually there.
    local -a extra=()
    [ -f "$CHAT_TEMPLATE" ]   && extra+=(--chat-template-file "$CHAT_TEMPLATE")
    [ -f "$KV_MEAN_CENTER" ]  && extra+=(--kv-mean-center "$KV_MEAN_CENTER")

    echo "starting llama-server (port $LLAMA_PORT) — $(_mode_label "$np")"
    "$LLAMA_BIN" -m "$MODEL_PATH" \
    -ngl 99 \
    -fa on \
    -c "$CTX" \
    -np "$np" \
    -b 2048 \
    -ub 1024 \
    -ctk q4_0 \
    -ctv q4_0 \
    --ctx-checkpoints 32 \
    --cache-ram 8192 \
    --cache-idle-slots \
    --spec-type ngram-mod \
    --spec-ngram-mod-n-match 24 \
    --spec-ngram-mod-n-min 48 \
    --spec-ngram-mod-n-max 64 \
    --temp 1.0 \
    --top-p 0.95 \
    --top-k 20 \
    --min-p 0.05 \
    --predict 8192 \
    --repeat-penalty 1.0 \
    --presence-penalty 0.0 \
    --reasoning on \
    --reasoning-effort medium \
    --reasoning-budget 4096 \
    --reasoning-budget-message "$REASONING_MSG" \
    --reasoning-preserve \
    --jinja \
    --host "$HOST" \
    --port "$LLAMA_PORT" \
    ${extra[@]+"${extra[@]}"} > "$LOGDIR/llama.log" 2>&1 &
    local llama_pid=$!

    for _ in {1..30}; do
        if check_llama; then
            echo "ok  llama-server is up (PID $llama_pid, $np slot(s))"
            return 0
        fi
        kill -0 "$llama_pid" 2>/dev/null || break
        sleep 1
    done

    echo "err llama-server did not come up on port $LLAMA_PORT (see $LOGDIR/llama.log)"
    return 1
}

stop_all() {
    echo "stopping everything..."
    local p
    for p in $(pgrep -f "llama-server" 2>/dev/null); do kill -9 "$p" 2>/dev/null; done
    sleep 1
    rm -f "$PIDFILE"
    echo "ok  everything stopped"
}

status() {
    echo "=== system status ==="
    if check_llama; then
        echo "llama-server: ok  running (port $LLAMA_PORT)"
        if _running_np; then
            echo "start mode:    $(_mode_label "$R_NP" "$R_CTX")"
        fi
    else
        echo "llama-server: --  not started"
    fi
    echo "model:         $MODEL"
    [ -x "$ASN_BIN" ] && echo "asn (recon):   ok  available" || echo "asn (recon):   --  not found"
    echo "wiki:          $(find "$WIKI_DIR" -name '*.md' -type f 2>/dev/null | wc -l) pages"
}

start() {
    echo "============================================"
    echo "  lex llama-server manager"
    echo "============================================"
    AI_MODE=1
    case "${2:-}" in
        '')            _pick_mode || return 1 ;;
        1|standard|full) AI_MODE=1 ;;
        2|split|128k)    AI_MODE=2 ;;
        *)
            echo "err unknown mode: $2"
            echo "  usage: ai start [1|standard|2|split]"
            return 1
            ;;
    esac
    start_llama "$AI_MODE" || return 1
    echo ""
    echo "Endpoint: http://$HOST:$LLAMA_PORT"
    echo "Stop:     ./ai.sh stop"
}

stop() { stop_all; }

chat() {
    echo "============================================"
    echo "  lex llama-server — server info"
    echo "============================================"
    if ! check_llama; then echo "warn llama-server is not running! First: ./ai.sh start"; return 1; fi
    echo "ok  llama-server is up: http://$HOST:$LLAMA_PORT (OpenAI compatible)"
    echo ""
    echo "Test: curl http://$HOST:$LLAMA_PORT/v1/models"
}

case "${1:-}" in
    start)   start "$@" ;;
    stop)    stop_all ;;
    restart) bash "$0" stop; sleep 2; bash "$0" start ;;
    status)  status ;;
    chat)    chat ;;
    asn)     [ -x "$ASN_BIN" ] && "$ASN_BIN" "${2:-}" || { echo "asn not found: $ASN_BIN"; exit 1; } ;;
    wiki)    echo "Wiki: $WIKI_DIR"; find "$WIKI_DIR" -type f -name '*.md' 2>/dev/null | sort ;;
    *) start "$@" && chat ;;
esac
