#!/usr/bin/env bash
#
# tools/llama-proxy.sh — debug proxy between lex and the llama-server.
#
# Purpose: see WHAT lex sends to the server and WHAT comes back.
# The proxy listens on a high port (default 24480), forwards to
# http://127.0.0.1:8080 and logs request and response
# fully (raw + pretty) to $LEX_PROXY_DIR (default: ./.proxy/).
#
# Usage:
#   ./tools/llama-proxy.sh start [Port]     # start the proxy (default 24480)
#   ./tools/llama-proxy.sh stop             # stop it
#   ./tools/llama-proxy.sh status           # running? upstream reachable?
#   ./tools/llama-proxy.sh tail [n]         # the last n traffic lines
#   ./tools/llama-proxy.sh show [n]         # n-th last exchange (req+resp)
#
# Attach lex to it (ENV overrides, see LEX.md §4):
#   LEX_API_URL=http://127.0.0.1:24480/v1/chat/completions ./lex --oneshot
#
# Rules that apply here (from wiki/errors 2026-09-28):
#   - ncat ALWAYS with -k (otherwise only one connection)
#   - Content-Length in BYTES (wc -c), never ${#var} (characters)
#   - answer Expect: 100-continue, otherwise a deadlock above a 1 KB body
#   - NEVER write to stdout/stderr while the socket is open
#     (stdout = response channel!) → everything goes to files, stderr redirected
#   - take the PID from `nohup … &`, never `PID="$(…)"` together with wait
#   - NEVER pass on the upstream Transfer-Encoding (curl already
#     dechunks it) → set our own Content-Length
#
set -u
set -o pipefail

SELF="$0"
case "$SELF" in /*) : ;; *) SELF="${PWD}/${SELF}" ;; esac
if command -v readlink >/dev/null 2>&1; then
  _rp="$(readlink -f "$0" 2>/dev/null)" && [[ -n "${_rp:-}" ]] && SELF="$_rp"
fi

PORT="${LEX_PROXY_PORT:-24480}"
UPSTREAM="${LEX_PROXY_UPSTREAM:-http://127.0.0.1:8080}"
DIR="${LEX_PROXY_DIR:-${PWD}/.proxy}"
UP_HOST_PORT="${UPSTREAM#*://}"          # 127.0.0.1:8080
UP_HOST_PORT="${UP_HOST_PORT%%/*}"

# ---------------------------------------------------------------------------
# internal: one handler process per incoming connection (ncat --sh-exec)
# ---------------------------------------------------------------------------
_handle() {
  # stdout = socket → never write anything here that does not belong into
  # the response. stderr goes into a file.
  exec 2>>"${DIR}/handler.err"

  local hdr body
  hdr="$(mktemp "${DIR}/.hdr.XXXXXX")" || exit 1
  body="$(mktemp "${DIR}/.body.XXXXXX")" || exit 1

  # --- read headers ---------------------------------------------------------
  local req_line="" line cl=0 expect=0
  while IFS= read -r line; do
    line="${line%$'\r'}"
    [[ -z "$line" ]] && break
    if [[ -z "$req_line" ]]; then
      req_line="$line"
      continue
    fi
    case "$line" in
      [Cc]ontent-[Ll]ength:*) cl="${line#*:}"; cl="${cl//[[:space:]]/}"; cl="${cl:-0}" ;;
      [Ee]xpect:*) expect=1 ;;
    esac
    printf '%s\n' "$line" >> "$hdr"
  done
  # Empty connection (port probe) → leave right away
  [[ -z "$req_line" ]] && { rm -f "$hdr" "$body"; exit 0; }

  (( expect )) && printf 'HTTP/1.1 100 Continue\r\n\r\n'
  if (( cl > 0 )); then
    head -c "$cl" > "$body" || true
  fi

  local method path
  method="${req_line%% *}"
  path="${req_line#* }"
  path="${path%% *}"
  [[ -z "${path:-}" ]] && path="/"

  # --- Authorization / Content-Type durchreichen ----------------------------
  local auth="" ctype=""
  while IFS= read -r line; do
    case "$line" in
      [Aa]uthorization:*)  auth="${line#*:}";  auth="${auth#"${auth%%[![:space:]]*}"}" ;;
      [Cc]ontent-[Tt]ype:*) ctype="${line#*:}"; ctype="${ctype#"${ctype%%[![:space:]]*}"}" ;;
    esac
  done < "$hdr"
  [[ -z "$ctype" ]] && ctype="application/json"

  local ts id
  ts="$(date +%Y%m%d-%H%M%S)"
  id="${ts}-$RANDOM"
  local in_file="${DIR}/${id}-in.json"
  local out_file="${DIR}/${id}-out.json"
  local hfile="${DIR}/${id}-headers.txt"

  # --- store the request (raw + pretty) -------------------------------------
  cp "$body" "$in_file"
  jq . "$in_file" > "${in_file%.json}.pretty.json" 2>/dev/null || rm -f "${in_file%.json}.pretty.json"
  {
    printf '== %s  %s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" "$req_line"
    cat "$hdr"
  } > "$hfile"

  # --- forward to the upstream ---------------------------------------------
  local rsp_hdr rsp_body rc
  rsp_hdr="$(mktemp "${DIR}/.rsp.XXXXXX")" || exit 1
  rsp_body="$(mktemp "${DIR}/.rspbody.XXXXXX")" || exit 1
  local t0 t1 dur
  t0="$(date +%s)"
  local -a args=(-sS --max-time 900 -D "$rsp_hdr" -o "$rsp_body"
                 -H "Content-Type: ${ctype}" --data-binary "@${body}")
  [[ -n "$auth" ]] && args+=(-H "Authorization: ${auth}")
  curl "${args[@]}" "${UPSTREAM}${path}" >/dev/null 2>&1
  rc=$?
  t1="$(date +%s)"
  dur=$((t1 - t0))

  local status ctype_out
  if (( rc != 0 )); then
    printf '{"error":"proxy: upstream not reachable","rc":%d,"url":"%s"}\n' \
      "$rc" "${UPSTREAM}${path}" > "$rsp_body"
    status="HTTP/1.1 502 Bad Gateway"
    ctype_out="application/json"
    printf 'PROXY-ERROR: curl rc=%d against %s\n' "$rc" "${UPSTREAM}${path}" >> "${DIR}/traffic.log"
  else
    # curl -D writes ALL header blocks (first "HTTP/1.1 100 Continue"
    # from the Expect handshake) → the LAST status is the real one.
    status="$(tr -d '\r' < "$rsp_hdr" 2>/dev/null | grep -a '^HTTP/' | tail -n1)"
    [[ -z "$status" ]] && status="HTTP/1.1 200 OK"
    local l
    while IFS= read -r l; do
      case "$l" in
        [Cc]ontent-[Tt]ype:*) ctype_out="${l#*:}"; ctype_out="${ctype_out#"${ctype_out%%[![:space:]]*}"}" ;;
      esac
    done < "$rsp_hdr"
    [[ -z "${ctype_out:-}" ]] && ctype_out="application/json"
    ctype_out="${ctype_out%%$'\r'}"
  fi
  cp "$rsp_body" "$out_file"
  cp "$rsp_hdr" "${DIR}/${id}-rsp-headers.txt" 2>/dev/null || true
  jq . "$out_file" > "${out_file%.json}.pretty.json" 2>/dev/null || rm -f "${out_file%.json}.pretty.json"

  # Body length in bytes — the protocol needs it (it precedes the response) AND
  # the Content-Length.
  local rlen
  rlen="$(wc -c < "$rsp_body" | tr -d ' ')"

  # --- traffic log ----------------------------------------------------------
  local req_model req_msgs req_max req_rb req_tools
  local resp_finish resp_content resp_reason resp_tools
  req_model="$(jq -r '.model // "-"' "$in_file" 2>/dev/null || printf '-')"
  req_msgs="$(jq -r '(.messages // []) | length' "$in_file" 2>/dev/null || printf '-')"
  req_max="$(jq -r '.max_tokens // "-"' "$in_file" 2>/dev/null || printf '-')"
  req_rb="$(jq -r '.reasoning_budget_tokens // "-"' "$in_file" 2>/dev/null || printf '-')"
  req_tools="$(jq -r '(.tools // []) | length' "$in_file" 2>/dev/null || printf '-')"
  resp_finish="$(jq -r '.choices[0].finish_reason // "-"' "$out_file" 2>/dev/null || printf '-')"
  resp_content="$(jq -r '(.choices[0].message.content // "") | length' "$out_file" 2>/dev/null || printf '-')"
  resp_reason="$(jq -r '(.choices[0].message.reasoning_content // "") | length' "$out_file" 2>/dev/null || printf '-')"
  resp_tools="$(jq -r '[.choices[0].message.tool_calls[]?.function.name] | join(",")' "$out_file" 2>/dev/null || printf '-')"
  [[ -z "$resp_tools" ]] && resp_tools="-"

  local roles
  roles="$(jq -r '[.messages[]?.role] | group_by(.) | map("\(.[0])×\(length)") | join(" ")' "$in_file" 2>/dev/null || printf '-')"

  printf '%s %s %s | %s | req=%sB resp=%sB %ds | REQ model=%s msgs=%s(%s) max=%s rb=%s tools=%s | RESP finish=%s content=%sB reasoning=%sB tools=%s | %s -> %s\n' \
    "$(date +%Y-%m-%dT%H:%M:%S%z)" "$method" "$path" "$status" \
    "$(wc -c < "$in_file" | tr -d ' ')" "$rlen" "$dur" \
    "$req_model" "$req_msgs" "$roles" "$req_max" "$req_rb" "$req_tools" \
    "$resp_finish" "$resp_content" "$resp_reason" "$resp_tools" \
    "$(basename "$in_file")" "$(basename "$out_file")" \
    >> "${DIR}/traffic.log"

  # --- answer the client (own Content-Length in bytes) ----------------------
  # $status already contains the HTTP version ("HTTP/1.1 200 OK") — do NOT
  # prepend "HTTP/1.1 " or the client reports "Unsupported HTTP/1 subversion".
  printf '%s\r\nContent-Type: %s\r\nContent-Length: %s\r\nConnection: close\r\n\r\n' \
    "$status" "$ctype_out" "$rlen"
  # By cat, NOT "$(cat …)": command substitution swallows the trailing
  # newline → otherwise Content-Length is 1 byte too large (curl: rc 18).
  cat "$rsp_body"

  rm -f "$hdr" "$body" "$rsp_hdr" "$rsp_body"
  exit 0
}

# ---------------------------------------------------------------------------
# Control
# ---------------------------------------------------------------------------
usage() {
  sed -n '2,26p' "$SELF" | sed 's/^# \{0,1\}//'
}

_pidfile() { printf '%s\n' "${DIR}/proxy.pid"; }

_running() {
  local pf
  pf="$(_pidfile)"
  [[ -f "$pf" ]] || return 1
  local pid
  pid="$(cat "$pf" 2>/dev/null)"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

cmd_start() {
  PORT="${1:-$PORT}"
  if [[ "$PORT" == "8080" ]]; then
    echo "Error: port 8080 is the real llama-server — use a high port." >&2
    exit 1
  fi
  if _running; then
    echo "Proxy already running on port $(cat "${DIR}/proxy.port" 2>/dev/null || echo '?') (PID $(cat "$(_pidfile)"))" >&2
    exit 1
  fi
  command -v ncat >/dev/null 2>&1 || { echo "Error: ncat is missing." >&2; exit 1; }
  command -v jq    >/dev/null 2>&1 || { echo "Error: jq is missing." >&2; exit 1; }
  mkdir -p "$DIR" || exit 1
  if command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | grep -q ":${PORT}[[:space:]]"; then
    echo "Error: port $PORT is in use." >&2
    exit 1
  fi

  export LEX_PROXY_DIR="$DIR"
  export LEX_PROXY_UPSTREAM="$UPSTREAM"
  # Deliberately loopback ONLY: the proxy must not be reachable from the network
  # (it forwards the llama server key/content unprotected).
  nohup ncat --listen 127.0.0.1 "$PORT" -k --sh-exec "$SELF __handle" </dev/null >"${DIR}/proxy.out" 2>&1 &
  local pid=$!
  disown "$pid" 2>/dev/null || true
  printf '%s\n' "$pid" > "$(_pidfile)"
  printf '%s\n' "$PORT" > "${DIR}/proxy.port"
  printf '%s\n' "$UPSTREAM" > "${DIR}/proxy.upstream"

  local listening=1
  for _ in $(seq 1 30); do
    if nc -z 127.0.0.1 "$PORT" 2>/dev/null; then listening=0; break; fi
    sleep 0.1
  done
  if (( listening != 0 )); then
    echo "Error: proxy is not listening on port $PORT (see ${DIR}/proxy.out)" >&2
    kill "$pid" 2>/dev/null
    rm -f "$(_pidfile)"
    exit 1
  fi
  echo "Proxy running: 127.0.0.1:$PORT → $UPSTREAM  (PID $pid, logs: $DIR)"
  echo "attach lex:   LEX_API_URL=http://127.0.0.1:$PORT/v1/chat/completions ./lex --oneshot"
}

cmd_stop() {
  local pid
  pid="$(cat "$(_pidfile)" 2>/dev/null)"
  if [[ -n "${pid:-}" ]]; then
    kill "$pid" 2>/dev/null && echo "Proxy stopped (PID $pid)."
  else
    echo "No PID file under $DIR."
  fi
  rm -f "$(_pidfile)" "${DIR}/proxy.port"
}

cmd_status() {
  local up port reach
  # Stored upstream URL of the running proxy (otherwise the default).
  up="$(cat "${DIR}/proxy.upstream" 2>/dev/null)"
  [[ -z "$up" ]] && up="$UPSTREAM"
  port="${up##*://}"
  port="${port##*:}"
  port="${port%%/*}"

  if _running; then
    echo "Proxy:  running (PID $(cat "$(_pidfile)"), port $(cat "${DIR}/proxy.port" 2>/dev/null || echo '?'))"
  else
    echo "Proxy:  stopped"
  fi

  if command -v ss >/dev/null 2>&1; then
    if ss -ltn 2>/dev/null | grep -q ":${port}[[:space:]]"; then
      reach="port listening"
    else
      reach="PORT NOT LISTENING"
    fi
  else
    reach="check needs ss"
  fi
  echo "Upstream: $up — $reach"

  local n
  n="$(find "$DIR" -name '*-in.json' -type f 2>/dev/null | wc -l | tr -d ' ')"
  echo "Traffic: $n exchange(s) logged in $DIR"
}

cmd_tail() {
  local n="${1:-20}"
  [[ -f "${DIR}/traffic.log" ]] || { echo "No traffic yet in $DIR/traffic.log"; exit 0; }
  tail -n "$n" "${DIR}/traffic.log"
}

cmd_show() {
  local n="${1:-1}"
  local infile
  infile="$(find "$DIR" -name '*-in.json' -type f 2>/dev/null | sort | tail -n "$n" | head -1)"
  [[ -n "$infile" ]] || { echo "No traffic yet."; exit 1; }
  local outfile="${infile%-in.json}-out.json"
  echo "########## REQUEST ($infile) ##########"
  if [[ -f "${infile%.json}.pretty.json" ]]; then cat "${infile%.json}.pretty.json"; else cat "$infile"; fi
  echo
  local rh="${infile%-in.json}-rsp-headers.txt"
  if [[ -f "$rh" ]]; then
    echo "########## UPSTREAM HEADERS ##########"
    cat "$rh"
    echo
  fi
  echo "########## RESPONSE ($outfile) ##########"
  if [[ -f "${outfile%.json}.pretty.json" ]]; then cat "${outfile%.json}.pretty.json"; else cat "$outfile"; fi
}

cmd="${1:-}"
[[ $# -gt 0 ]] && shift || true

case "$cmd" in
  __handle) _handle ;;
  start)    cmd_start "$@" ;;
  stop)     cmd_stop ;;
  status)   cmd_status ;;
  tail)     cmd_tail "$@" ;;
  show)     cmd_show "$@" ;;
  ""|-h|--help|help) usage ;;
  *) echo "Unknown command: $cmd" >&2; usage >&2; exit 1 ;;
esac
