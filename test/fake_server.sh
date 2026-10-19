#!/usr/bin/env bash
#
# lex/test/fake_server.sh — kleiner Fake-OpenAI-Server (Pure Bash + ncat).
#
# Startet einen OpenAI-kompatiblen Server auf einem Port (default 8081),
# der pro Request eine gültige JSON-Response zurückgibt. Damit kann der
# echte curl-Pfad in call_api() getestet werden, OHNE den llama-server
# (Port 8080) anzurühren.
#
# Usage:
#   ./fake_server.sh [Port] [Script-Datei]
#
#   ./fake_server.sh 8081 responses.json
#
#   Script-Datei: eine JSON-Response pro Zeile (OpenAI-Format). Wird pro
#   POST-Request aufgebraucht. Wenn leer → DEFAULT-Response.
#   .sse-Endung: die Datei wird als GANZER SSE-Stream ausgeliefert (nicht
#   verbraucht) — so testet test_sse.sh den Streaming-Pfad von call_api().
#   Erste Zeile „STATUS:500|{json}": eigener HTTP-Statuscode.
#
# WICHTIG (Verträge, die defekt waren):
#   - `ncat --listen` akzeptiert OHNE `-k` GENAU EINE Verbindung und
#     beendet sich dann. Der Port-Wait-Check (`nc -z`) hat damit die
#     einzige Verbindung verbraucht → der Server war tot, bevor der
#     erste echte Request kam. → `-k` (keep-open) ist Pflicht.
#   - Jede Verbindung erzeugt einen Handler, der eine Response-Zeile
#     aus der Script-Datei zieht (Line-Modus). Auch `nc -z`-Probes
#     wären damit Requests. → Der Handler liest erst die
#     Request-Line/Header und verbraucht nur bei POST eine Zeile.
#   - Das Skript gibt die ncat-PID auf STDOUT aus und endet DANACH.
#     Ein Aufrufer holt sich die PID per Befehlsersetzung
#     (`PID="$(fake_server.sh …)"`) — die erst zurückkehrt, wenn
#     STDOUT zu ist. Ein `wait` hier würde den Aufrufer aufhängen.
#   - Port-Wait ist ein BIND-NACHWEIS, kein `nc -z` (Audit-Fund M11,
#     2026-10-08): `nc -z` trifft auch einen FREMDEN Listener, wenn
#     unser `ncat --listen` nicht binden konnte (Port belegt) — der
#     Tester redete dann mit dem falschen Server und der Test war grün,
#     obwohl hier gar nichts lief. Erfolg heißt deshalb: unsere PID
#     lauscht auf dem Port (ss), und die PID lebt (kein Zombie).
#   - Handler und Lock liegen NEBEN der Script-Datei (also im
#     TMP-Ordner des Testers) und werden mit dem Aufräumen gelöscht.
#     `ncat` führt sie pro Verbindung aus — sie dürfen nicht
#     vorher entfernt werden. Aufräumen = erst PID killen, dann TMP.
#
set -u
set -o pipefail

PORT="${1:-8081}"
SCRIPT_FILE="${2:-}"
if [[ -z "${SCRIPT_FILE:-}" ]]; then
  echo "Usage: $0 [Port] [Script-Datei]" >&2
  exit 1
fi
[[ -f "$SCRIPT_FILE" ]] || { echo "Fehler: Script-Datei '$SCRIPT_FILE' nicht gefunden." >&2; exit 1; }

DEFAULT_RESP='{"choices":[{"index":0,"message":{"role":"assistant","content":"Taugt.","reasoning_content":"","tool_calls":[]},"finish_reason":"stop"}],"usage":{"total_tokens":10}}'

BASE_DIR="$(dirname "$SCRIPT_FILE")"
HANDLER="$BASE_DIR/.fake_openai_handler.$PORT.sh"
LOCK_FILE="$BASE_DIR/.fake_openai_lock.$PORT"

cat > "$HANDLER" <<HANDLER_EOF
#!/bin/bash
set -u
set -o pipefail
SCRIPT_FILE="\$FAKE_SCRIPT_FILE"
LOCK_FILE="\$FAKE_LOCK_FILE"
DEFAULT="\$FAKE_DEFAULT_RESP"

# --- Request einlesen: Request-Line, dann Header bis zur Leerzeile. ---
method=""
cl=0
expect_100=0
if IFS= read -r req_line; then
  req_line="\${req_line%\$'\r'}"
  method="\${req_line%% *}"
fi
while IFS= read -r line; do
  line="\${line%\$'\r'}"
  [[ -z "\$line" ]] && break
  case "\${line,,}" in
    content-length:*)
      cl="\${line##*:}"
      cl="\${cl// /}"
      cl="\${cl:-0}"
      ;;
    expect:*100-continue*)
      expect_100=1
      ;;
  esac
done

# "nc -z" und andere Probes senden nichts → ohne Antwort sofort weg.
# Das schont die Response-Zeilen der Script-Datei.
# (Backticks wären in diesem Heredoc Command-Substitution!)
if [[ "\$method" != "POST" ]]; then
  exit 0
fi

# curl wartet bei >1 KB Body auf "100 Continue" — sonst Deadlock
if (( expect_100 )); then
  printf 'HTTP/1.1 100 Continue\r\n\r\n'
fi
# Body vollständig ablesen, sonst RST beim Schließen (curl: rc 52).
# FAKE_BODY_LOG (optional): den Request-Body mitschreiben — darüber prüft
# test_sse.sh, ob call_api stream_options/include_usage sendet.
if (( cl > 0 )); then
  if [[ -n "\${FAKE_BODY_LOG:-}" ]]; then
    head -c "\$cl" > "\$FAKE_BODY_LOG" 2>/dev/null || true
  else
    head -c "\$cl" >/dev/null 2>&1 || true
  fi
fi

# Response per flock entnehmen (Parallel-Requests).
# *.sse-Dateien werden KOMPLETT als Stream ausgeliefert — eine Zeile pro
# Event ginge nicht, head -n1 würde am Zeilenumbruch abschneiden.
exec 200>"\$LOCK_FILE"
flock 200
body=""
ctype="application/json"
status="200 OK"
if [[ "\$SCRIPT_FILE" == *.sse ]]; then
  body="\$(cat "\$SCRIPT_FILE" 2>/dev/null)"
  ctype="text/event-stream"
elif [[ -f "\$SCRIPT_FILE" ]] && [[ -s "\$SCRIPT_FILE" ]]; then
  body="\$(head -n1 "\$SCRIPT_FILE" 2>/dev/null)"
  tail -n +2 "\$SCRIPT_FILE" > "\${SCRIPT_FILE}.tmp" 2>/dev/null && mv "\${SCRIPT_FILE}.tmp" "\$SCRIPT_FILE" 2>/dev/null
fi
flock -u 200
[[ -z "\${body:-}" ]] && body="\$DEFAULT"
# STATUS:500|{json} → eigener HTTP-Status (deckt den rc-Guard von call_api ab)
if [[ "\$body" == STATUS:* ]]; then
  IFS='|' read -r _st _bd <<< "\$body"
  status="\${_st#STATUS:}"
  body="\$_bd"
fi
# Content-Length in BYTES: \${#body} zählt Zeichen (UTF-8-ä/ü/… → 1 Zeile
# wäre 1 Byte zu kurz → curl schneidet das JSON ab → jq-Fehler).
len=\$(printf '%s' "\$body" | wc -c)
len=\${len// /}
printf 'HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s' "\$status" "\$ctype" "\$len" "\$body"
HANDLER_EOF
chmod +x "$HANDLER"

export FAKE_SCRIPT_FILE="$SCRIPT_FILE"
export FAKE_LOCK_FILE="$LOCK_FILE"
export FAKE_DEFAULT_RESP="$DEFAULT_RESP"

echo "Fake-Server auf Port $PORT (Script: $SCRIPT_FILE)" >&2

# -k  = keep-open (mehrere Verbindungen)
#     = ohne `-k` stirbt ncat nach der ersten Verbindung
# 127.0.0.1 = NUR localhost binden — ohne Host-Bind horchte ncat auf
#     0.0.0.0 (Security-Fund 2026-10-07: zwei verwaiste Listener auf
#     allen Interfaces nach abgebrochenen Testläufen).
# </dev/null >/dev/null = ncat bekommt weder stdin noch stdout/err
ncat --listen 127.0.0.1 "$PORT" -k --sh-exec "$HANDLER" </dev/null >/dev/null 2>&1 &
NCAT_PID=$!
disown "$NCAT_PID" 2>/dev/null || true

# Prozess lebt (Hinweis: ein beendetes, noch nicht wiedergeholtes Kind
# ist ein Zombie — `kill -0` geht auf Zombies noch durch, /proc sagt Z).
_pid_alive() {
  local pid="$1" line state
  kill -0 "$pid" 2>/dev/null || return 1
  if [[ -r "/proc/$pid/stat" ]]; then
    line="$(cat "/proc/$pid/stat" 2>/dev/null || true)"
    state="${line##*) }"     # alles nach dem letzten ") " …
    state="${state%% *}"     # … erstes Feld = Prozesszustand
    [[ "$state" == "Z" ]] && return 1
  fi
  return 0
}

# True, wenn GENAU $pid auf 127.0.0.1:$port lauscht. Ohne ss bleibt nur
# die abgeschwächte Variante (lebt + Port offen) — der Normalfall auf
# allen Zielplattformen ist ss.
_port_owned_by() {
  local port="$1" pid="$2"
  if command -v ss >/dev/null 2>&1; then
    ss -Htanp "sport = :$port" 2>/dev/null | grep -qE "pid=${pid}[,)]"
    return $?
  fi
  _pid_alive "$pid" || return 1
  nc -z 127.0.0.1 "$port" 2>/dev/null
}

# Port-Wait + Bind-Nachweis (mit -k kostet die Abfrage keine Verbindung)
listening=1
for _ in $(seq 1 20); do
  if ! _pid_alive "$NCAT_PID"; then
    echo "Fehler: Fake-Server: ncat (PID $NCAT_PID) ist beendet — Bind an Port $PORT fehlgeschlagen (belegt?)" >&2
    exit 1
  fi
  if _port_owned_by "$PORT" "$NCAT_PID"; then
    listening=0
    break
  fi
  sleep 0.1
done
if (( listening != 0 )); then
  kill "$NCAT_PID" 2>/dev/null || true   # nur unseren, NIE den Fremd-Listener
  echo "Fehler: Fake-Server lauscht nicht auf Port $PORT (belegt?)" >&2
  exit 1
fi

# PID ausgeben (test_http.sh nimmt den Wert per Befehlsersetzung auf)
echo "$NCAT_PID"

# ENDE — bewusst ohne `wait`, sonst hängt die Befehlsersetzung des
# Aufrufers. ncat überlebt das Skript (disown), wird vom Caller per
# PID beendet, Handler/Lock verschwinden mit dem TMP-Ordner.
exit 0
