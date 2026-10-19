#!/usr/bin/env bash
#
# tools/llama-proxy.sh — Debug-Proxy zwischen lex und dem llama-server.
#
# Zweck: sehen, WAS lex zum Server schickt und WAS zurückkommt.
# Der Proxy lauscht auf einem hohen Port (default 24480), leitet an
# http://127.0.0.1:8080 weiter und protokolliert Request und Response
# vollständig (roh + pretty) nach $LEX_PROXY_DIR (default: ./.proxy/).
#
# Usage:
#   ./tools/llama-proxy.sh start [Port]     # Proxy starten (default 24480)
#   ./tools/llama-proxy.sh stop             # beenden
#   ./tools/llama-proxy.sh status           # läuft er? Upstream erreichbar?
#   ./tools/llama-proxy.sh tail [n]         # die letzten n Verkehr-Zeilen
#   ./tools/llama-proxy.sh show [n]         # n-te letzter Austausch (req+resp)
#
# lex daran binden (ENV überlagert):
#   LEX_API_URL=http://127.0.0.1:24480/v1/chat/completions ./lex --oneshot
#
# Regeln, die hier gelten (Fund 2026-09-28):
#   - ncat IMMER mit -k (sonst nur eine Verbindung)
#   - Content-Length in BYTES (wc -c), nie ${#var} (Zeichen)
#   - Expect: 100-continue beantworten, sonst Deadlock bei >1 KB Body
#   - NIEMALS auf stdout/stderr schreiben, solange das Socket offen ist
#     (stdout = Antwortkanal!) → alles in Dateien, stderr umgeleitet
#   - PID aus `nohup … &` nehmen, nie `PID="$(…)"` mit wait
#   - Transfer-Encoding der Upstream-NIE durchreichen (curl dechunkt
#     bereits) → eigene Content-Length setzen
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
# Intern: ein Handlervorgang pro eingehende Verbindung (ncat --sh-exec)
# ---------------------------------------------------------------------------
_handle() {
  # stdout = Socket → hier nie etwas hinschreiben, das nicht in die Antwort
  # gehört. stderr landet in einer Datei.
  exec 2>>"${DIR}/handler.err"

  local hdr body
  hdr="$(mktemp "${DIR}/.hdr.XXXXXX")" || exit 1
  body="$(mktemp "${DIR}/.body.XXXXXX")" || exit 1

  # --- Header lesen ---------------------------------------------------------
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
  # Leere Verbindung (Port-Probe) → sofort weg
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

  # --- Request sichern (roh + pretty) ---------------------------------------
  cp "$body" "$in_file"
  jq . "$in_file" > "${in_file%.json}.pretty.json" 2>/dev/null || rm -f "${in_file%.json}.pretty.json"
  {
    printf '== %s  %s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" "$req_line"
    cat "$hdr"
  } > "$hfile"

  # --- an Upstream weiterleiten --------------------------------------------
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
    printf '{"error":"proxy: upstream nicht erreichbar","rc":%d,"url":"%s"}\n' \
      "$rc" "${UPSTREAM}${path}" > "$rsp_body"
    status="HTTP/1.1 502 Bad Gateway"
    ctype_out="application/json"
    printf 'PROXY-FEHLER: curl rc=%d gegen %s\n' "$rc" "${UPSTREAM}${path}" >> "${DIR}/traffic.log"
  else
    # curl -D schreibt ALLE Header-Blöcke (zuerst "HTTP/1.1 100 Continue"
    # vom Expect-Handshake) → der LETZTE Status ist der eigentliche.
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

  # Body-Länge in Bytes — braucht das Protokoll (steht vor der Antwort) UND
  # die Content-Length.
  local rlen
  rlen="$(wc -c < "$rsp_body" | tr -d ' ')"

  # --- Verkehr-Protokoll ----------------------------------------------------
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

  # --- Antwort an den Client (eigene Content-Length in Bytes) ---------------
  # $status enthält schon die HTTP-Version („HTTP/1.1 200 OK") — NICHT noch
  # „HTTP/1.1 " davorhängen, sonst „Unsupported HTTP/1 subversion" beim Client.
  printf '%s\r\nContent-Type: %s\r\nContent-Length: %s\r\nConnection: close\r\n\r\n' \
    "$status" "$ctype_out" "$rlen"
  # Per cat, NICHT "$(cat …)": Kommando-Setzung schluckt den trailing
  # newline → sonst Content-Length 1 Byte zu groß (curl: rc 18).
  cat "$rsp_body"

  rm -f "$hdr" "$body" "$rsp_hdr" "$rsp_body"
  exit 0
}

# ---------------------------------------------------------------------------
# Steuerung
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

# Audit H5 (2026-10-08): läuft unter dieser PID wirklich unser ncat-Listener?
# Nach einem Crash liegt das PID-File weiter herum, die PID wird vom System
# wiederverwendet — ein blindes `kill` beendet dann einen Fremdprozess.
_is_our_proxy() { # $1 = pid
  local p="$1" a=""
  if [[ -r "/proc/$p/cmdline" ]]; then
    a="$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)"
  elif command -v ps >/dev/null 2>&1; then
    a="$(ps -p "$p" -o args= 2>/dev/null)"
  else
    return 0   # keine Prüfmöglichkeit → kill -0 (oben) bleibt das Mindestmaß
  fi
  [[ "$a" == *ncat* && "$a" == *--listen* ]]
}

# Audit M7 (2026-10-08): Bind-Nachweis — der Port gehört WIRKLICH dieser PID
# (gleicher Trick wie test/fake_server.sh M11). `nc -z` allein beweist nur,
# dass JEMAND antwortet, und läuft auch gegen einen fremden Listener.
_port_owned_by() { # $1 = Port, $2 = pid
  local port="$1" p="$2" own=""
  kill -0 "$p" 2>/dev/null || return 1
  command -v ss >/dev/null 2>&1 || return 0   # kein ss → mindestmaß PID lebt
  own="$(ss -Htanp "sport = :$port" 2>/dev/null | grep -oE "pid=${p}[,)]" | head -n 1)"
  [[ -n "$own" ]]
}

# Audit M6 (2026-10-08): `ncat --sh-exec` hängt je Verbindung einen Handler
# samt curl (max-time 900) an den Listener — ein reines ncat-kill ließ die
# Waisen bis zum Timeout weiterlaufen. Rekursiv, Kinder ZUERST, damit nichts
# von der Wurzel losgelöst wird.
_kill_tree() { # $1 = pid, $2 = Signal (default TERM)
  local p="$1" sig="${2:-TERM}" c
  if command -v pgrep >/dev/null 2>&1; then
    while IFS= read -r c; do
      [[ -n "$c" ]] && _kill_tree "$c" "$sig"
    done < <(pgrep -P "$p" 2>/dev/null || true)
  fi
  kill -"$sig" "$p" 2>/dev/null || true
}

cmd_start() {
  PORT="${1:-$PORT}"
  # Audit M7 (2026-10-08): PORT ging bislang UNVALIDIERT in ss/nc-Argumente
  # und die 8080-Sperre war ein reiner String-Vergleich („08080" umging sie).
  # Erst prüfen, dann normalisieren (10# gegen Oktal-Falle), dann sperren.
  if [[ ! "$PORT" =~ ^[0-9]{1,5}$ ]]; then
    echo "Fehler: Port muss 1–5 Ziffern haben (ist: $PORT)." >&2
    exit 1
  fi
  PORT="$((10#$PORT))"
  if (( PORT < 1 || PORT > 65535 )); then
    echo "Fehler: Port muss zwischen 1 und 65535 liegen (ist: $PORT)." >&2
    exit 1
  fi
  if (( PORT == 8080 )); then
    echo "Fehler: Port 8080 ist der echte llama-server — bitte einen hohen Port nehmen." >&2
    exit 1
  fi
  if _running; then
    echo "Proxy läuft bereits auf Port $(cat "${DIR}/proxy.port" 2>/dev/null || echo '?') (PID $(cat "$(_pidfile)"))" >&2
    exit 1
  fi
  command -v ncat >/dev/null 2>&1 || { echo "Fehler: ncat fehlt." >&2; exit 1; }
  command -v jq    >/dev/null 2>&1 || { echo "Fehler: jq fehlt." >&2; exit 1; }
  mkdir -p "$DIR" || exit 1
  if command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | grep -q ":${PORT}[[:space:]]"; then
    echo "Fehler: Port $PORT ist belegt." >&2
    exit 1
  fi

  export LEX_PROXY_DIR="$DIR"
  export LEX_PROXY_UPSTREAM="$UPSTREAM"
  # Bewusst NUR loopback: der Proxy darf nicht aus dem Netz erreichbar sein
  # (er leitet den llama-Server-Key/Inhalt ungeschützt weiter).
  nohup ncat --listen 127.0.0.1 "$PORT" -k --sh-exec "$SELF __handle" </dev/null >"${DIR}/proxy.out" 2>&1 &
  local pid=$!
  disown "$pid" 2>/dev/null || true
  printf '%s\n' "$pid" > "$(_pidfile)"
  printf '%s\n' "$PORT" > "${DIR}/proxy.port"
  printf '%s\n' "$UPSTREAM" > "${DIR}/proxy.upstream"

  # Audit M7 (2026-10-08): Erfolg nur mit BIND-NACHWEIS (PID + Port) — vorher
  # prüfte ein nacktes `nc -z` nur den PORT, tötete aber nie ncat auf deren
  # Fehlerpfad aus und las proxy.out unberücksichtigt: ein Fremd-Listener
  # machte den Start „grün", ein abgestürztes ncat wurde übersehen.
  local listening=1 _i
  for _i in $(seq 1 30); do
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "Fehler: ncat (PID $pid) ist beendet — Bind auf Port $PORT fehlgeschlagen (siehe ${DIR}/proxy.out):" >&2
      tail -n 3 "${DIR}/proxy.out" 2>/dev/null >&2 || true
      rm -f "$(_pidfile)"
      exit 1
    fi
    if _port_owned_by "$PORT" "$pid"; then listening=0; break; fi
    sleep 0.1
  done
  if (( listening != 0 )); then
    echo "Fehler: Proxy lauscht nicht auf Port $PORT (Port belegt? siehe ${DIR}/proxy.out)" >&2
    _kill_tree "$pid"
    for _i in $(seq 1 20); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
    done
    kill -0 "$pid" 2>/dev/null && _kill_tree "$pid" KILL
    rm -f "$(_pidfile)"
    exit 1
  fi
  echo "Proxy läuft: 127.0.0.1:$PORT → $UPSTREAM  (PID $pid, Logs: $DIR)"
  echo "lex binden:   LEX_API_URL=http://127.0.0.1:$PORT/v1/chat/completions ./lex --oneshot"
}

cmd_stop() {
  local pid
  pid="$(cat "$(_pidfile)" 2>/dev/null)"
  if [[ -z "${pid:-}" ]]; then
    echo "Kein PID-File unter $DIR."
    rm -f "$(_pidfile)" "${DIR}/proxy.port"
    return 0
  fi
  # Audit H5 (2026-10-08): vor dem kill prüfen, ob die PID überhaupt noch
  # existiert und ob sie unserem ncat gehört — sonst killt stop einen
  # wiederverwendeten Fremd-PID.
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "Proxy nicht mehr aktiv (PID $pid verwaist) — PID-File entfernt."
    rm -f "$(_pidfile)" "${DIR}/proxy.port"
    return 0
  fi
  if ! _is_our_proxy "$pid"; then
    echo "Fehler: PID $pid gehört nicht zum Proxy ($(ps -p "$pid" -o args= 2>/dev/null | tr -d '\n')) — nichts gekillt, PID-File entfernt." >&2
    rm -f "$(_pidfile)" "${DIR}/proxy.port"
    return 1
  fi
  # Audit M6 (2026-10-08): Unterbaum mitbeenden — Handler und deren curl
  # (max-time 900) überlebten das ncat-kill als Waisen. Erst TERM rekursiv,
  # dann maximal 2 s warten, dann KILL gegen Verweigerer.
  _kill_tree "$pid"
  local _i
  for _i in $(seq 1 20); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$pid" 2>/dev/null; then
    echo "Proxy reagiert nicht auf TERM — KILL (PID $pid)." >&2
    _kill_tree "$pid" KILL
  fi
  echo "Proxy gestoppt (PID $pid)."
  rm -f "$(_pidfile)" "${DIR}/proxy.port"
}

cmd_status() {
  local up port reach
  # Gespeicherte Upstream-URL des laufenden Proxys (sonst der Default).
  up="$(cat "${DIR}/proxy.upstream" 2>/dev/null)"
  [[ -z "$up" ]] && up="$UPSTREAM"
  port="${up##*://}"
  port="${port##*:}"
  port="${port%%/*}"

  if _running; then
    echo "Proxy:  läuft (PID $(cat "$(_pidfile)"), Port $(cat "${DIR}/proxy.port" 2>/dev/null || echo '?'))"
  else
    echo "Proxy:  gestoppt"
  fi

  if command -v ss >/dev/null 2>&1; then
    if ss -ltn 2>/dev/null | grep -q ":${port}[[:space:]]"; then
      reach="Port lauscht"
    else
      reach="PORT LAUSCHT NICHT"
    fi
  else
    reach="Prüfung braucht ss"
  fi
  echo "Upstream: $up — $reach"

  local n
  n="$(find "$DIR" -name '*-in.json' -type f 2>/dev/null | wc -l | tr -d ' ')"
  echo "Verkehr: $n Austausch(e) protokolliert in $DIR"
}

cmd_tail() {
  local n="${1:-20}"
  [[ -f "${DIR}/traffic.log" ]] || { echo "Noch kein Verkehr in $DIR/traffic.log"; exit 0; }
  tail -n "$n" "${DIR}/traffic.log"
}

cmd_show() {
  local n="${1:-1}"
  local infile
  infile="$(find "$DIR" -name '*-in.json' -type f 2>/dev/null | sort | tail -n "$n" | head -1)"
  [[ -n "$infile" ]] || { echo "Noch kein Verkehr."; exit 1; }
  local outfile="${infile%-in.json}-out.json"
  echo "########## REQUEST ($infile) ##########"
  if [[ -f "${infile%.json}.pretty.json" ]]; then cat "${infile%.json}.pretty.json"; else cat "$infile"; fi
  echo
  local rh="${infile%-in.json}-rsp-headers.txt"
  if [[ -f "$rh" ]]; then
    echo "########## UPSTREAM-HEADER ##########"
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
  *) echo "Unbekanntes Kommando: $cmd" >&2; usage >&2; exit 1 ;;
esac
