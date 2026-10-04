#!/usr/bin/env bash
#
# lex/test/fake_server.sh — small fake OpenAI server (pure bash + ncat).
#
# Starts an OpenAI-compatible server on a port (default 8081),
# returning one valid JSON response per request. That way the
# real curl path in call_api() can be tested, WITHOUT touching the llama-server
# (port 8080).
#
# Usage:
#   ./fake_server.sh [Port] [script file]
#
#   ./fake_server.sh 8081 responses.json
#
#   script file: one JSON response per line (OpenAI format). One line is
#   used per POST request. If empty → DEFAULT response.
#   .sse ending: the file is delivered as a WHOLE SSE stream (not consumed)
#   — that is how test_sse.sh tests the streaming path of call_api().
#   First line „STATUS:500|{json}": own HTTP status code.
#
# IMPORTANT (contracts that were broken):
#   - `ncat --listen` accepts EXACTLY ONE connection WITHOUT `-k` and
#     then exits. The port-wait check (`nc -z`) therefore consumed
#     the only connection → the server was dead before the
#     first real request arrived. → `-k` (keep-open) is mandatory.
#   - Every connection spawns a handler that pulls one response line
#     from the script file (line mode). Even `nc -z` probes
#     count as requests then. → The handler first reads the
#     request line/headers and only consumes a line for POST.
#   - The script prints the ncat PID to STDOUT and exits AFTERWARDS.
#     A caller picks up the PID via command substitution
#     (`PID="$(fake_server.sh …)"`) — which only returns once
#     STDOUT is closed. A `wait` here would hang the caller.
#   - Handler and lock sit NEXT TO the script file (i.e. in the
#     tester's TMP folder) and are removed during cleanup.
#     `ncat` executes them per connection — they must not be
#     removed beforehand. Cleanup = kill the PID first, then TMP.
#
set -u
set -o pipefail

PORT="${1:-8081}"
SCRIPT_FILE="${2:-}"
if [[ -z "${SCRIPT_FILE:-}" ]]; then
  echo "Usage: $0 [Port] [script file]" >&2
  exit 1
fi
[[ -f "$SCRIPT_FILE" ]] || { echo "Error: script file '$SCRIPT_FILE' not found." >&2; exit 1; }

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

# --- read the request: request line, then headers up to the blank line. ---
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

# "nc -z" and other probes send nothing → leave without answering at once.
# That preserves the response lines of the script file.
# (backticks would be command substitution inside this heredoc!)
if [[ "\$method" != "POST" ]]; then
  exit 0
fi

# curl waits for "100 Continue" on a >1 KB body — otherwise deadlock
if (( expect_100 )); then
  printf 'HTTP/1.1 100 Continue\r\n\r\n'
fi
# read the body completely, otherwise RST on close (curl: rc 52).
# FAKE_BODY_LOG (optional): also write the request body — test_sse.sh checks
# with it whether call_api sends stream_options/include_usage.
if (( cl > 0 )); then
  if [[ -n "\${FAKE_BODY_LOG:-}" ]]; then
    head -c "\$cl" > "\$FAKE_BODY_LOG" 2>/dev/null || true
  else
    head -c "\$cl" >/dev/null 2>&1 || true
  fi
fi

# take the response line under flock (parallel requests).
# *.sse files are delivered COMPLETELY as a stream — one line per
# event would not work, head -n1 would cut at the line break.
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
# STATUS:500|{json} → own HTTP status (covers the rc-guard of call_api)
if [[ "\$body" == STATUS:* ]]; then
  IFS='|' read -r _st _bd <<< "\$body"
  status="\${_st#STATUS:}"
  body="\$_bd"
fi
# Content-Length in BYTES: \${#body} counts characters (a UTF-8 umlaut → 1 line
# would be 1 byte too short → curl cuts the JSON → jq error).
len=\$(printf '%s' "\$body" | wc -c)
len=\${len// /}
printf 'HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s' "\$status" "\$ctype" "\$len" "\$body"
HANDLER_EOF
chmod +x "$HANDLER"

export FAKE_SCRIPT_FILE="$SCRIPT_FILE"
export FAKE_LOCK_FILE="$LOCK_FILE"
export FAKE_DEFAULT_RESP="$DEFAULT_RESP"

echo "fake server on port $PORT (script: $SCRIPT_FILE)" >&2

# -k  = keep-open (several connections)
#     = without `-k` ncat dies after the first connection
# </dev/null >/dev/null = ncat gets neither stdin nor stdout/stderr
ncat --listen "$PORT" -k --sh-exec "$HANDLER" </dev/null >/dev/null 2>&1 &
NCAT_PID=$!
disown "$NCAT_PID" 2>/dev/null || true

# wait for the port: until the server listens (with -k a probe costs no connection)
listening=1
for _ in $(seq 1 20); do
  if nc -z 127.0.0.1 "$PORT" 2>/dev/null; then
    listening=0
    break
  fi
  sleep 0.1
done
if (( listening != 0 )); then
  echo "Error: fake server is not listening on port $PORT (in use?)" >&2
  exit 1
fi

# print the PID (test_http.sh picks the value up via command substitution)
echo "$NCAT_PID"

# END — deliberately without `wait`, otherwise the caller's command substitution
# hangs. ncat survives the script (disown), the caller kills it via the
# PID, handler/lock vanish together with the TMP folder.
exit 0
