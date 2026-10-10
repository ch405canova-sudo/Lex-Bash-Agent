#!/usr/bin/env bash
# lurk_watch.sh — watcher rules for lex's /lexlurk mode
#
#   --start           create baseline (snapshots + counters + timestamp)
#   --check           compare against baseline: rc0 clean, rc1 new alerts,
#                     rc2 no baseline (run --start first)
#   --alerts [n]      show the last n alerts (default 10)
#   --status          baseline/alert state
#   --stop            remove the run marker (baseline and alerts stay)
#
# Rules (P1): fail2ban ban delta, auth failure delta, successful logins
# (audit H4 2026-10-08 — before the watcher only saw errors, a fresh
# root login stayed invisible), new external peers,
# new neighbours, new listening ports, changed key files.
# After every --check the snapshots are advanced (atomically, M8) —
# a deviation is therefore reported EXACTLY ONCE, even with two
# concurrent --check runs.
#
# Paths/sources redirectable via ENV (tests):
#   LEX_LURK_DIR          state directory     (default ~/.lex/lurk)
#   LEX_LURK_FAIL2BAN_LOG fail2ban log        (default /var/log/fail2ban.log)
#   LEX_LURK_AUTH_LOG     auth log            (default /var/log/auth.log)
#   LEX_LURK_SS_SNAP      file instead of `ss -Htan`
#   LEX_LURK_PORT_SNAP    file instead of `ss -Hlnt`
#   LEX_LURK_NEIGH_SNAP   file instead of `ip -br neigh show`
#   LEX_LURK_FILES        whitespace-separated hashable key files
#   LEX_LURK_NO_SNAP=1    --check does not advance snapshots (tests)
set -euo pipefail
# Uniform byte sorting — comm compares bytes, sort defaults to
# locale-aware → without the C locale comm complains about "not sorted".
export LC_ALL=C

DIR="${LEX_LURK_DIR:-${HOME}/.lex/lurk}"
FB_LOG="${LEX_LURK_FAIL2BAN_LOG:-/var/log/fail2ban.log}"
AU_LOG="${LEX_LURK_AUTH_LOG:-/var/log/auth.log}"
BASE="$DIR/baseline"
ALERTS="$DIR/alerts.jsonl"
COUNTS="$DIR/baseline.counts"
RUN="$DIR/.running"
KEY_FILES="${LEX_LURK_FILES:-${HOME}/.ssh/authorized_keys /etc/sudoers /etc/ssh/sshd_config /etc/crontab}"

die() { printf 'lurk_watch: %s\n' "$*" >&2; exit 2; }
now() { date -Is; }

# M8 (2026-10-08): advance snapshots atomically. Before it was truncated
# with `>` and rewritten — a parallel `--check` read a half-emptied file,
# `comm` treated the entire baseline as "new" and the alarm flood stood.
# Temp file in the same directory + `mv` (rename is atomic): readers only
# see the old or the new file, never a fragment.
_snap_write() { # $1 = target, content on stdin
  local dst="$1" tmp
  tmp="$(mktemp "$DIR/.snap.XXXXXX")" || die "cannot create snapshot temp: $DIR"
  cat > "$tmp"
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$dst" || { rm -f "$tmp"; die "snapshot not writable: $dst"; }
}

snap_peers() { # external ESTAB/SYN-RECV peers (IP without port)
  if [[ -n "${LEX_LURK_SS_SNAP:-}" ]]; then
    cat "${LEX_LURK_SS_SNAP}"
  else
    ss -Htan 2>/dev/null || true
  fi | awk '$1 == "ESTAB" || $1 == "SYN-RECV" { print $5 }' | sed 's/:[0-9]*$//' | sort -u
}

snap_ports() { # listening TCP ports (local)
  if [[ -n "${LEX_LURK_PORT_SNAP:-}" ]]; then
    cat "${LEX_LURK_PORT_SNAP}"
  else
    ss -Hlnt 2>/dev/null || true
  fi | awk '{ print $4 }' | sort -u
}

snap_neigh() { # neighbours: IP + MAC (without FAILED/INCOMPLETE)
  if [[ -n "${LEX_LURK_NEIGH_SNAP:-}" ]]; then
    cat "${LEX_LURK_NEIGH_SNAP}"
  else
    ip -br neigh show 2>/dev/null || true
  fi | grep -v 'FAILED\|INCOMPLETE' | awk 'NF >= 2 { print $1, $NF }' | sort -u
}

snap_hashes() {
  local f
  # shellcheck disable=SC2086  # KEY_FILES is deliberately whitespace-separated
  for f in $KEY_FILES; do
    [[ -r "$f" ]] || continue
    sha256sum "$f" 2>/dev/null || true
  done | sort
}

fb_count() { # fail2ban ban count or -1 (source unreadable)
  [[ -r "$FB_LOG" ]] || { printf '%s' "-1"; return 0; }
  local c
  c="$(grep -c ' Ban ' "$FB_LOG" 2>/dev/null || true)"
  printf '%s' "${c:-0}"
}

au_count() { # auth failure count or -1
  [[ -r "$AU_LOG" ]] || { printf '%s' "-1"; return 0; }
  local c
  c="$(grep -cE 'Failed password|authentication failure' "$AU_LOG" 2>/dev/null || true)"
  printf '%s' "${c:-0}"
}

# Successful logins (sshd: "Accepted password|publickey|keyboard-interactive
# for ..."). Audit H4 (2026-10-08): own counter instead of mixing with the
# errors — otherwise an error delta masks login success.
login_count() {
  [[ -r "$AU_LOG" ]] || { printf '%s' "-1"; return 0; }
  local c
  c="$(grep -cE 'Accepted (password|publickey|keyboard-interactive|gssapi-with-mic|hostbased)' "$AU_LOG" 2>/dev/null || true)"
  printf '%s' "${c:-0}"
}

alert() { # $1 = sev, $2 = rule, $3 = msg (into the alerts file + stdout)
  local sev="$1" rule="$2" msg="$3" line out
  # M9 (2026-10-08): the alerts file is JSONL — the hand-built format
  # escaped neither backslash nor control characters; a `"` from the auth log
  # produced an unparseable line (jq aborts, --alerts returns garbage).
  # jq builds the line — the only place that really does it right.
  line="$(jq -cn --arg ts "$(now)" --arg sev "$sev" --arg rule "$rule" \
    --arg msg "$msg" '{ts:$ts,sev:$sev,rule:$rule,msg:$msg}')" \
    || die "alert not representable as JSON: $msg"
  printf '%s\n' "$line" >> "$ALERTS"
  out="${msg//$'\n'/ }"
  out="${out//$'\r'/ }"
  printf 'ALERT [%s] %s: %s\n' \
    "$(printf '%s' "$sev" | tr '[:lower:]' '[:upper:]')" "$rule" "$out"
}

do_start() {
  mkdir -p "$DIR" || die "cannot create state directory: $DIR"
  chmod 700 "$DIR" 2>/dev/null || true
  [[ -f "$ALERTS" ]] || : > "$ALERTS"
  snap_peers | _snap_write "$BASE.peers"
  snap_ports | _snap_write "$BASE.ports"
  snap_neigh | _snap_write "$BASE.neigh"
  snap_hashes | _snap_write "$BASE.hashes"
  printf 'fb=%s\nau=%s\nlogin=%s\n' "$(fb_count)" "$(au_count)" "$(login_count)" | _snap_write "$COUNTS"
  now | _snap_write "$BASE.ts"
  : > "$RUN"
  printf 'lurk: baseline created (%s) — %s peers, %s listening ports\n' \
    "$(now)" "$(wc -l < "$BASE.peers")" "$(wc -l < "$BASE.ports")"
}

_do_delta() { # $1 = file rule name, $2 = old file, $3 = new snapshot
  local new
  new="$(comm -13 <(sort -u "$2") <(printf '%s\n' "$3" | sort -u))"
  [[ -n "$new" ]] || return 1
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    alert medium "$1" "new since baseline: $line"
  done <<< "$new"
  return 0
}

do_check() {
  [[ -f "$BASE.ts" ]] || die "no baseline — run --start first"
  local rc=0

  # R1 fail2ban ban delta
  local fb_now fb_old
  fb_now="$(fb_count)"
  fb_old="$(awk -F= '/^fb=/{print $2}' "$COUNTS" 2>/dev/null || true)"
  if [[ "$fb_now" =~ ^[0-9]+$ && "${fb_old:-}" =~ ^[0-9]+$ ]] && (( fb_now > fb_old )); then
    # FIX (2026-10-09): last "Ban" line instead of the last log line.
    # tail -n1 "$FB_LOG" grabs a "Found X" (filter) line, not the actual
    # ban (actions) line → wrong IP in the alert.
    local last_ban
    last_ban="$(grep ' Ban ' "$FB_LOG" 2>/dev/null | tail -n1 | tr -d '\n')"
    [[ -n "$last_ban" ]] || last_ban="$(tail -n1 "$FB_LOG" 2>/dev/null | tr -d '\n')"
    alert high fail2ban "$((fb_now - fb_old)) new ban(s) — last: $last_ban"
    rc=1
  fi

  # R2 auth failure delta
  local au_now au_old
  au_now="$(au_count)"
  au_old="$(awk -F= '/^au=/{print $2}' "$COUNTS" 2>/dev/null || true)"
  if [[ "$au_now" =~ ^[0-9]+$ && "${au_old:-}" =~ ^[0-9]+$ ]] && (( au_now > au_old )); then
    # FIX (2026-10-09): last auth failure instead of the last log line.
    # tail -n1 "$AU_LOG" is often "Connection closed by invalid user"
    # (not a failure line) → wrong line in the alert.
    local last_au
    last_au="$(grep -E 'Failed password|authentication failure' "$AU_LOG" 2>/dev/null | tail -n1 | tr -d '\n')"
    [[ -n "$last_au" ]] || last_au="$(tail -n1 "$AU_LOG" 2>/dev/null | tr -d '\n')"
    alert high auth "$((au_now - au_old)) new auth failures — last: $last_au"
    rc=1
  fi

  # R2b successful logins (audit H4 2026-10-08: before invisible)
  local log_now log_old
  log_now="$(login_count)"
  log_old="$(awk -F= '/^login=/{print $2}' "$COUNTS" 2>/dev/null || true)"
  if [[ "$log_now" =~ ^[0-9]+$ && "${log_old:-}" =~ ^[0-9]+$ ]] && (( log_now > log_old )); then
    # FIX (2026-10-09): last successful login instead of the last log line.
    # tail -n1 "$AU_LOG" is almost never an Accepted entry → wrong line.
    local last_login
    last_login="$(grep -E 'Accepted (password|publickey|keyboard-interactive|gssapi-with-mic|hostbased)' "$AU_LOG" 2>/dev/null | tail -n1 | tr -d '\n')"
    [[ -n "$last_login" ]] || last_login="$(tail -n1 "$AU_LOG" 2>/dev/null | tr -d '\n')"
    alert high login "$((log_now - log_old)) new successful login(s) — last: $last_login"
    rc=1
  fi

  # R3 new external peers (low: just an INFO for now)
  if _do_delta peer "$BASE.peers" "$(snap_peers)"; then rc=1; fi
  # R4 new neighbours (medium)
  if _do_delta neigh "$BASE.neigh" "$(snap_neigh)"; then rc=1; fi
  # R5 new listening ports (medium)
  if _do_delta port "$BASE.ports" "$(snap_ports)"; then rc=1; fi

  # R6 key files changed (critical)
  local hnew hdiff
  hnew="$(snap_hashes)"
  hdiff="$(comm -13 <(sort -u "$BASE.hashes") <(printf '%s\n' "$hnew" | sort -u))"
  if [[ -n "$hdiff" ]]; then
    local f
    while IFS= read -r f; do
      [[ -n "$f" ]] || continue
      alert critical keyfile "changed: $f"
    done <<< "$hdiff"
    rc=1
  fi

  # Advance snapshots → report each deviation EXACTLY ONCE
  if [[ -z "${LEX_LURK_NO_SNAP:-}" ]]; then
    snap_peers | _snap_write "$BASE.peers"
    snap_ports | _snap_write "$BASE.ports"
    snap_neigh | _snap_write "$BASE.neigh"
    printf '%s\n' "$hnew" | _snap_write "$BASE.hashes"
    printf 'fb=%s\nau=%s\nlogin=%s\n' "$fb_now" "$au_now" "$log_now" | _snap_write "$COUNTS"
    # M10 (audit 2026-10-08): the marker .running means "watcher running"
    # and belongs only to --start/--stop. Before a plain --check silently
    # recreated it after --stop and --status reported "run active".
    [[ -f "$RUN" ]] && touch "$RUN" 2>/dev/null
  fi

  if (( rc == 0 )); then
    printf 'lurk: nothing unusual (checked %s)\n' "$(now)"
  fi
  return "$rc"
}

do_alerts() {
  local n="${1:-10}"
  [[ "$n" =~ ^[0-9]+$ ]] || n=10
  [[ -f "$ALERTS" ]] || { printf 'lurk: no alerts file.\n'; return 0; }
  if [[ ! -s "$ALERTS" ]]; then printf 'lurk: no alerts.\n'; return 0; fi
  tail -n "$n" "$ALERTS"
}

do_status() {
  if [[ -f "$BASE.ts" ]]; then
    local ac
    ac="$(grep -c '' "$ALERTS" 2>/dev/null || true)"
    printf 'lurk: baseline since %s\n' "$(cat "$BASE.ts")"
    printf 'lurk: counters    %s\n' "$(tr '\n' ' ' < "$COUNTS" 2>/dev/null || echo '—')"
    printf 'lurk: alerts      %s total\n' "${ac:-0}"
    if [[ -f "$RUN" ]]; then printf 'lurk: run         active (marker .running)\n'
    else printf 'lurk: run         marker missing — repeat /lexlurk on\n'; fi
  else
    printf 'lurk: no baseline — /lexlurk on starts the watcher.\n'
  fi
}

do_stop() {
  rm -f "$RUN" 2>/dev/null || true
  printf 'lurk: marker removed (baseline and alerts remain).\n'
}

case "${1:-}" in
  --start)  do_start ;;
  --check)  do_check ;;
  --alerts) shift; do_alerts "${1:-10}" ;;
  --status) do_status ;;
  --stop)   do_stop ;;
  *)
    sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
