#!/usr/bin/env bash
#
# lex — a pure-Bash LLM terminal agent
#
# Pure Bash + jq + curl. No Node, no Python.
#
# Modes:
#   lex                    -> interactive REPL
#   lex --oneshot          -> single shot (stdin -> stdout, exit)
#   lex --install          -> create ~/.lex/ + settings.json + symlink
#   lex --version          -> version
#   lex --help             -> help
#
# Config (4 tiers, ENV overrides everything):
#   defaults -> ~/.lex/settings.json -> .lex/settings.json -> ENV
# ENV: LEX_API_URL, LEX_API_KEY, LEX_MODEL, LEX_MAX_TOKENS,
#      LEX_REASONING_BUDGET, LEX_TEMPERATURE, LEX_MAX_TURNS,
#      LEX_MAX_NUDGES, LEX_API_TIMEOUT, LEX_TOOL_TIMEOUT,
#      LEX_TOOL_MAX_OUTPUT, LEX_LOG_DIR,
#      LEX_MOCK, LEX_MOCK_FILE
#
set -u
set -o pipefail

# ---------------------------------------------------------------------------
# Version & paths
# ---------------------------------------------------------------------------
readonly LEX_VERSION="${LEX_VERSION:-0.1.0}"
readonly LEX_NAME="lex"

# Portability (bug #8): `readlink -f`/`realpath` are GNU-only -> fallbacks.
_lex_script="$0"
if command -v readlink >/dev/null 2>&1; then
  _rp="$(readlink -f "$0" 2>/dev/null)" && [[ -n "${_rp:-}" ]] && _lex_script="$_rp"
fi
[[ "$_lex_script" = /* ]] || _lex_script="${PWD}/${_lex_script}"
_lex_repo_dir="$(dirname "$_lex_script")"
_lex_home="${LEX_HOME:-$HOME/.lex}"
_ai_dir="$(dirname "$_lex_repo_dir")"
_mem_dir="${LEX_MEM_DIR:-$_lex_home/mem}"
# Root of the LLM wiki (Karpathy layout raw/ + wiki/), see the docs.
_wiki_dir="${LEX_WIKI_DIR:-${_lex_home}/wiki}"
# Tool/software directory (step 18): downloads, extraction and execution all
# happen here — override with LEX_HTOOLS_DIR.
_htools_dir="${LEX_HTOOLS_DIR:-${HOME}/H-Tools}"

# Absolute path without GNU tools (fallback chain used by safe_path).
_abs_path() {
  local p="$1" out=""
  if command -v realpath >/dev/null 2>&1; then
    out="$(realpath -m "$p" 2>/dev/null || realpath "$p" 2>/dev/null)"
  fi
  if [[ -z "${out:-}" ]] && command -v readlink >/dev/null 2>&1; then
    out="$(readlink -f "$p" 2>/dev/null)"
  fi
  if [[ -z "${out:-}" ]]; then
    [[ "$p" = /* ]] || p="${PWD}/${p}"
    # -P resolves symlinked directories so that e.g. /tmp/etclink -> /etc
    # still ends up in safe_path (P3, 2026-09-28).
    out="$(cd -P "$(dirname "$p")" 2>/dev/null && printf '%s/%s' "$PWD" "$(basename "$p")")"
    [[ -z "${out:-}" ]] && out="$p"
  fi
  printf '%s\n' "$out"
}

# Time limit for tool_bash — without `timeout` (BSD/macOS legacy) call directly.
_run_limited() {
  local secs="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  else
    "$@"
  fi
}

# LEX_MOCK_FILE: shadow copy so the source file is not destroyed (bug #10).
# Sequence is preserved across runs (shadow is only refreshed when the source
# is newer).
_mock_shadow() {
  local src="$1" key dir shadow
  [[ -f "$src" ]] || { printf '%s\n' "$src"; return 0; }
  key="$(printf '%s' "$src" | cksum | tr -c '0-9' '_')"
  dir="${_lex_home}/mock"
  shadow="${dir}/mock-${key}.jsonl"
  if ! mkdir -p "$dir" 2>/dev/null; then
    printf '%s\n' "$src"
    return 0
  fi
  if [[ ! -f "$shadow" || "$src" -nt "$shadow" ]]; then
    if ! cp "$src" "$shadow" 2>/dev/null; then
      printf '%s\n' "$src"
      return 0
    fi
  fi
  printf '%s\n' "$shadow"
}

# Defaults (tier 1)
_default_api_url="http://127.0.0.1:8080/v1/chat/completions"
# No baked-in model path: set LEX_MODEL or "model" in settings.json.
# Recommended model: Ternary-Bonsai-2-27B-PQ2_0.gguf (see README).
_default_model=""
_default_max_tokens=16384
# Budget = server flag from ai.sh; the request field wins. 2026-09-29 (live
# review, "large tasks"): 8192/4096 cut visible answers at ~4096 tokens and
# produced finish=length aborts -> now 16384/8192.
_default_reasoning_budget=8192
_default_temperature=0.7
_default_max_turns=200
_default_tool_timeout=300
_default_tool_max_output=50000
# Nudge limit (finish=length): was hard-coded to 2 — too strict for large
# tasks (every nudge costs a turn, afterwards a hard rc-1). Configurable via
# LEX_MAX_NUDGES.
_default_max_nudges=4
_default_log_dir="${_lex_home}/log"

# Loaded config (tier 2-4)
_api_url=""
_api_key=""
_model=""
_max_tokens=""
_reasoning_budget=""
_temperature=""
_max_turns=""
_tool_timeout=""
_tool_max_output=""
_max_nudges=""
_log_dir=""
_mock="${LEX_MOCK:-}"
_mock_file=""
if [[ -n "${LEX_MOCK_FILE:-}" ]]; then
  _mock_file="$(_mock_shadow "${LEX_MOCK_FILE}")"
fi
_approve="${LEX_APPROVE:-0}"
_sudo="${LEX_SUDO:-1}"
_sudo_approve="${LEX_SUDO_APPROVE:-1}"
_session_enabled="${LEX_SESSION:-1}"
_session_id=""
_session_file=""

# Runtime-State
_messages='[]'
_turn_count=0
_last_prompt_tokens=""
_last_completion_tokens=""

# ---------------------------------------------------------------------------
# Config (4 tiers)
# ---------------------------------------------------------------------------
_load_settings() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  local v
  v="$(jq -r '.api_url // empty' "$file" 2>/dev/null)"   && [[ -n "${v:-}" ]] && _api_url="$v"
  v="$(jq -r '.api_key // empty' "$file" 2>/dev/null)"   && [[ -n "${v:-}" ]] && _api_key="$v"
  v="$(jq -r '.model // empty' "$file" 2>/dev/null)"     && [[ -n "${v:-}" ]] && _model="$v"
  v="$(jq -r '.max_tokens // empty' "$file" 2>/dev/null)" && [[ -n "${v:-}" ]] && _max_tokens="$v"
  v="$(jq -r '.reasoning_budget_tokens // empty' "$file" 2>/dev/null)" && [[ -n "${v:-}" ]] && _reasoning_budget="$v"
  v="$(jq -r '.temperature // empty' "$file" 2>/dev/null)" && [[ -n "${v:-}" ]] && _temperature="$v"
  v="$(jq -r '.max_turns // empty' "$file" 2>/dev/null)" && [[ -n "${v:-}" ]] && _max_turns="$v"
  v="$(jq -r '.tool_timeout // empty' "$file" 2>/dev/null)" && [[ -n "${v:-}" ]] && _tool_timeout="$v"
  v="$(jq -r '.tool_max_output // empty' "$file" 2>/dev/null)" && [[ -n "${v:-}" ]] && _tool_max_output="$v"
  v="$(jq -r '.log_dir // empty' "$file" 2>/dev/null)" && [[ -n "${v:-}" ]] && _log_dir="$v"
}

# Config values come from user input (P2, 2026-09-28): without this check a
# text value inside (( )) raises an arithmetic error and aborts lex.
_int_or() {
  case "$1" in
    ''|*[!0-9]*) printf '%s\n' "$2" ;;
    *) printf '%s\n' "$1" ;;
  esac
}
_float_or() {
  case "$1" in
    ''|*[!0-9.]*|*.*.*) printf '%s\n' "$2" ;;
    *) printf '%s\n' "$1" ;;
  esac
}
# Carry the template's file mode over to the temp file (mktemp gives 600):
# otherwise edit_file/todo would strip world-readable permissions (P2).
_copy_mode() {
  local src="$1" dst="$2" mode=""
  if mode="$(stat -c '%a' "$src" 2>/dev/null)" && [[ "$mode" =~ ^[0-7]{3,4}$ ]]; then
    chmod "$mode" "$dst" 2>/dev/null || true
  elif mode="$(stat -f '%Lp' "$src" 2>/dev/null)" && [[ "$mode" =~ ^[0-7]{3}$ ]]; then
    chmod "$mode" "$dst" 2>/dev/null || true
  fi
  return 0
}

load_config() {
  # tier 1: defaults
  _api_url="$_default_api_url"
  _api_key=""
  _model="$_default_model"
  _max_tokens="$_default_max_tokens"
  _reasoning_budget="$_default_reasoning_budget"
  _temperature="$_default_temperature"
  _max_turns="$_default_max_turns"
  _tool_timeout="$_default_tool_timeout"
  _tool_max_output="$_default_tool_max_output"
  _max_nudges="$_default_max_nudges"
  _log_dir="$_default_log_dir"
  # tier 2: ~/.lex/settings.json
  _load_settings "${_lex_home}/settings.json"
  # tier 3: .lex/settings.json (cwd)
  _load_settings "${PWD}/.lex/settings.json"
  # tier 4: ENV (overrides everything)
  _api_url="${LEX_API_URL:-$_api_url}"
  _api_key="${LEX_API_KEY:-$_api_key}"
  _model="${LEX_MODEL:-$_model}"
  _max_tokens="${LEX_MAX_TOKENS:-$_max_tokens}"
  _reasoning_budget="${LEX_REASONING_BUDGET:-$_reasoning_budget}"
  _temperature="${LEX_TEMPERATURE:-$_temperature}"
  _max_turns="${LEX_MAX_TURNS:-$_max_turns}"
  _tool_timeout="${LEX_TOOL_TIMEOUT:-$_tool_timeout}"
  _tool_max_output="${LEX_TOOL_MAX_OUTPUT:-$_tool_max_output}"
  _max_nudges="${LEX_MAX_NUDGES:-$_max_nudges}"
  _log_dir="${LEX_LOG_DIR:-$_log_dir}"
  _approve="${LEX_APPROVE:-$_approve}"
  _sudo="${LEX_SUDO:-$_sudo}"
  _sudo_approve="${LEX_SUDO_APPROVE:-$_sudo_approve}"
  _session_enabled="${LEX_SESSION:-$_session_enabled}"
  _mem_dir="${LEX_MEM_DIR:-$_mem_dir}"
  _wiki_dir="${LEX_WIKI_DIR:-$_wiki_dir}"
  _htools_dir="${LEX_HTOOLS_DIR:-$_htools_dir}"
  # validation: neutralise numeric values (non-numeric -> default)
  _max_tokens="$(_int_or "$_max_tokens" "$_default_max_tokens")"
  _reasoning_budget="$(_int_or "$_reasoning_budget" "$_default_reasoning_budget")"
  _max_turns="$(_int_or "$_max_turns" "$_default_max_turns")"
  _tool_timeout="$(_int_or "$_tool_timeout" "$_default_tool_timeout")"
  _tool_max_output="$(_int_or "$_tool_max_output" "$_default_tool_max_output")"
  _max_nudges="$(_int_or "$_max_nudges" "$_default_max_nudges")"
  _temperature="$(_float_or "$_temperature" "$_default_temperature")"
  # mock mode needs no model (canned answers, nothing is sent)
  if [[ -z "${_model:-}" && "${_need_model:-1}" = 1 && -z "${_mock:-}" && -z "${_mock_file:-}" ]]; then
    echo "Error: no LLM model configured (set LEX_MODEL or \"model\" in ~/.lex/settings.json — see README)." >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log() {
  local msg="$1"
  mkdir -p "$_log_dir" 2>/dev/null
  local ts
  ts="$(date +%Y-%m-%dT%H:%M:%S%z)"
  printf '%s %s\n' "$ts" "$msg" >> "${_log_dir}/lex.log" 2>/dev/null
}

# ---------------------------------------------------------------------------
# System prompt
# ---------------------------------------------------------------------------
_system_prompt="You are Lex — a locally running terminal agent: alert, direct, English-speaking. You think briefly, act precisely and never guess.

Role & expertise (ethical hacker):
You are a brilliant and highly intelligent ethical hacker with comprehensive knowledge of cybersecurity, network security and penetration testing. Your abilities cover spotting and exploiting security weaknesses, writing exploits and developing strategies that improve IT security.

Your goal is to help organisations protect their systems against cyber attacks by identifying and assessing weaknesses. You work ethically and responsibly so that your methods are legal and in the best interest of your clients.

Your expertise covers:
- Network security: you understand how networks are architected and how they work, and you can identify weaknesses in firewalls, routers and switches.
- Penetration testing: you carry out thorough penetration tests to find and assess potential entry points for attackers.
- Exploit development: you write custom exploits that take advantage of specific security weaknesses.
- Real-time detection: you recognise attacks in progress and raise immediate warnings as soon as a threat is identified. Your systems watch network traffic continuously and analyse anomalies so attacks are caught early.
- Security awareness: you stay current on cybersecurity trends and threats and adapt your methods accordingly.
- Reporting: you write detailed reports of your findings and give practical recommendations for fixing the weaknesses you identified.

Your ethical approach guarantees that all of your activities are transparent and in line with legal requirements. You work closely with your clients so their security measures stay current and effectively protect against today's threats.

Personality & style:
- **ALWAYS in English** — answers, intermediate steps, files, log entries. No exceptions.
- **Short and effective:** think first, then act. No filler words, no empty pleasantries, no long preamble. An answer as short as it is correct — and not shorter.
- **Think decisively, then commit:** reason the matter through once properly and stand by the result — no self-doubt phrasing ('actually I'm not sure', 'maybe that's wrong after all') about things you have just verified yourself.
- **You verify with tools, not in your head:** \`bash -n\`, \`./test/run_all.sh\`, \`search\`, \`read_file\` and the logs are where certainty comes from — not from rethinking. If something is open, say clearly as a fact what is missing; that is a finding, not uncertainty.
- **Never guess, look it up:** for commands and flags use \`bash\` with \`<command> --help\`, for facts \`search\` (project and wiki) or \`web_search(query)\`/\`web_fetch(url)\`, for libraries and frameworks \`context7(...)\`. Only when research turns up nothing do you say openly what you don't know — a clear gap beats a fabricated answer.
- **Errors are material:** when something fails, first find the cause (\`search\`, log files, \`mem_search\` for earlier failures), then the fix. Write the fix down: one line in ${_wiki_dir}/wiki/log.md, and for recurring problems a page at ${_wiki_dir}/wiki/errors/YYYY-MM-DD-<short>.md. Next time look there first instead of reinventing it.
- **For humans at a terminal:** structure where it helps (short bullets, tables for comparisons and values), otherwise two to five sentences. No how-to tone, no repeating the question.

You have 17 tools:
- read_file(path): reads a file and returns its contents.
- write_file(path, content): writes a file (overwrites an existing file).
- edit_file(path, old, new, all=false): replaces the first occurrence of 'old' with 'new'; with all:true it replaces every occurrence.
- append_file(path, content): appends text to the END of a file without overwriting — exactly right for append-only files such as wiki/log.md.
- bash(command): runs a shell command and returns stdout/stderr. There is a hard deny list (deleting at the root, block devices, pipes into shells, su, reboots) — those commands are refused. \`sudo\` is NOT forbidden, it is released through a gate: the human at the terminal sees exactly one prompt showing the command and types their password straight into the sudo prompt. If that is aborted, or there is no terminal, the command is refused — say so plainly in your answer.
- list_files(path, pattern?, recursive?): lists files. pattern is a glob matched against the file name (e.g. *.md), recursive=true searches recursively.
- search(query, path?, glob?, regex?): searches files and returns matches as path:line:text. The default is a literal search (safe); regex=true searches with a regular expression. path starts the search (a file or directory; **without path the wiki ${_wiki_dir} is searched**), glob filters file names (*.md).
- mem_add(type, content): stores a memory under ~/.lex/mem/ as Markdown with YAML frontmatter. type ∈ memory|fact|preference|note.
- mem_list(type?): lists stored memories (optionally filtered by type).
- mem_search(query): searches all memories and returns matches with file and line.
- todo(action, text?, index?): persistent task list under ~/.lex/plans/. add appends a step, done ticks it off by index (1-based), list shows the plan — including its current content, so you don't have to ask again.
- web_search(query): searches the web via DuckDuckGo and returns title, URL and snippet — for the question of whether something still holds true, with no API key involved.
- web_fetch(url, max_length?): pulls a known page as plain text via a crawler (MCP defuddle) — cleaner and faster than fetch, but WITHOUT saving it. If you want to keep the source: fetch(url, topic).
- context7(query, library?): current documentation for libraries/frameworks (MCP context7) — the counterweight to your trained, possibly stale knowledge. library is optional; without it the matching library is searched for.
- browser(action, url?, ref?, element?, text?, key?, index?): drives a real browser (MCP playwright, system Chrome) — clicks, typing, navigation, freely usable. Most important cycle: navigate(url) → snapshot() (returns elements with a ref, e.g. ref=s1e44) → click/ref or type/ref from that. action ∈ navigate|snapshot|click|type|press|back|tabs|close|wait; tabs picks a tab by index (no index = list). Refs are only valid until the page changes: AFTER back/click/press(Enter) and on a ref-not-found error take a fresh snapshot first (use action=wait with seconds if the page still loads), then use the new ref.
- mcp(server, tool, arguments?): generic MCP access to any configured server. Order: first mcp(server, '__tools') to read the tool list, then mcp(server, tool, arguments) with the JSON of the arguments. A server error tells you which servers are configured.
- fetch(url, topic): downloads a web page and stores it as a raw source under <wiki>/raw/<topic>/YYYY-MM-DD-slug.md (metadata header per the wiki template). Returns the path and the beginning of the content so you can triage immediately. topic is an existing folder under raw/ (check existing ones with list_files).

Wiki under ${_wiki_dir} (Karpathy layout):
- raw/ is IMMUTABLE — read and create new entries only, never modify an existing raw source.
- wiki/log.md is append-only: always append_file, NEVER write_file (otherwise the log is gone).
- New articles append one line to wiki/index.md (append_file).
- Link sources with [[wikilinks]], write everything in English, no invented facts (grounding: every number/claim must appear in a raw/ file).

Rules:
- Use the tools to solve your task.
- **Larger tasks (more than 3 steps):** first record the steps in a sensible order with todo(action=add), then execute them step by step, ticking each off with todo(action=done, index=N). Only answer when everything is ticked off (VERIFY) — then briefly summarise what was done.
- Before editing, read what already exists (mem_list/mem_search, read_file).
- Be precise and focused. Always answer in English.
- **No doubt loops:** don't ask 'are you sure?' when the information is sufficient, and don't renegotiate the whole task after a single error — find the cause, apply the fix, continue. Verification replaces self-introspection.
- **Your wiki is your memory:** for every NEW task you first read the wiki state at the end of this prompt (index.md + recent log entries) or refresh it: \`read_file ${_wiki_dir}/wiki/index.md\` plus the newest entries from ${_wiki_dir}/wiki/log.md, together with \`mem_search\`. Only after that may you say you don't know something — don't guess before. What you find new and need later gets appended as a line to ${_wiki_dir}/wiki/log.md (append_file); new lasting artefacts become articles with a line in wiki/index.md. That way the memory grows.
- **Back up untrained knowledge:** if something counts as outdated or uncertain (versions, prices, new APIs), first substantiate it with \`web_search\`/\`web_fetch\`/\`context7\`, then pull the source into \`raw/\` and anchor it in the \`wiki/\` article — afterwards you rely on your own wiki instead of searching again every time.
- **Security / pen-test tasks:** before you scan, read packets or assess suspicious IPs, read ${_wiki_dir}/wiki/concepts/security-playbook.md — best practices (permission/scope first), the tool pipeline (nmap → Wireshark in parallel → Follow Stream), the Wireshark display filters and the IP check chain live there; it is your standard procedure.
- **Maintain your own playbooks:** recurring procedures (already done ≥2×, or ≥3 steps with ordering risk) you record following the template in ${_wiki_dir}/wiki/concepts/playbook-erstellen.md as \`wiki/concepts/<name>.md\` — with an index.md line, a log.md line and a \`raw/\` source for claimed facts; the point: continuity across sessions, consistency and a reservoir of fixes instead of flying blind.
- **Browser tasks:** always work in the cycle navigate(url) → read snapshot() → pick the matching ref → click/ref or type/ref with element (a short description of the target) → new snapshot. Never guess where something sits — the snapshot is the truth; when done, append the result to the log.
- **Desktop tasks (GUI without a CLI):** server \`desktop\` — first mcp(desktop, '__tools') for the REAL tool list (never guess names!), then read the screen state/state, only then send mouse/keyboard input, and append the result to the log. Window focus/query (window targeting) is still limited until the next login — don't repeat failures stubbornly, take state/screenshot as the evidence.
- **Database tasks (Postgres, local):** server \`postgres\` — first mcp(postgres, '__tools') for the REAL tool list (execute_sql, search_objects), then SQL. The target is your own \`lex\` database on 127.0.0.1:5432 (user-space under ~/.lex/pg, start/stop: ~/.lex/pg/start.sh) with full rights — do not touch other databases or users.
- **Record what you learn after success:** one line in the log (done and learned), maintain the matching wiki article for new insights (\`write_file\` plus an index line) and use \`mem_add\` for comparisons you keep needing. That way your knowledge grows from session to session.
- **Software & tools ALWAYS in ${_htools_dir}:** when you download, install, unpack or run software, tools or repositories, use ${_htools_dir} exclusively as target and base directory (mkdir -p if it is missing) — never \$HOME, never /tmp. Paths in your scripts and answers about tools lead from there.
- Avoid endless loops: once you have completed the task, answer with text (no tool call)."

# ---------------------------------------------------------------------------
# Session JSONL (spec §6.5): append-only, one message per line
# ---------------------------------------------------------------------------
session_init() {
  _session_file=""
  case "${_session_enabled:-1}" in
    0|false|no|off|"") return 0 ;;
  esac
  mkdir -p "${_lex_home}/sessions" 2>/dev/null || return 0
  _session_id="$(date +%Y%m%d-%H%M%S)-$$-${RANDOM}"
  local dir="${_lex_home}/sessions/${_session_id}"
  mkdir -p "$dir" 2>/dev/null || return 0
  _session_file="${dir}/session.jsonl"
  local ts project
  ts="$(date +%Y-%m-%dT%H:%M:%S%z)"
  project="$(basename "$PWD")"
  jq -c -n --arg ts "$ts" --arg model "${_model:-}" --arg project "$project" \
    '{type:"session",ts:$ts,model:$model,project:$project}' >> "$_session_file" 2>/dev/null
}

session_write() {
  [[ -n "${_session_file:-}" ]] || return 0
  printf '%s\n' "$1" >> "$_session_file" 2>/dev/null
}

# ---------------------------------------------------------------------------
# message helpers (JSON array as a string)
# ---------------------------------------------------------------------------
append_message_json() {
  local msg="$1" reasoning="${2:-}"
  local new
  new="$(jq -c --argjson m "$msg" '. + [$m]' <<< "$_messages")" || {
    log "append_message_json: invalid msg (${#msg} chars) — context kept"
    return 1
  }
  _messages="$new"
  [[ -n "${_session_file:-}" ]] || return 0
  local ts rec
  ts="$(date +%Y-%m-%dT%H:%M:%S%z)"
  if [[ -n "$reasoning" ]]; then
    rec="$(jq -c -n --arg ts "$ts" --argjson m "$msg" --arg r "$reasoning" \
      '{type:"message",ts:$ts,message:$m,reasoning:$r}')" || return 1
  else
    rec="$(jq -c -n --arg ts "$ts" --argjson m "$msg" '{type:"message",ts:$ts,message:$m}')" || return 1
  fi
  session_write "$rec"
}

append_message() {
  local role="$1" content="$2"
  # E2BIG guard (step 17b): Linux caps shell arguments at 128 KB — larger
  # payloads made `jq --arg` fail, msg came out empty and the following
  # --argjson call wiped the whole context.
  if (( ${#content} > 100000 )); then
    content="${content:0:100000}"$'\n... (truncated, '"${#content}"' bytes total)'
  fi
  local msg
  msg="$(jq -n --arg role "$role" --arg content "$content" '{role:$role,content:$content}')" || {
    log "append_message: jq error for $role (${#content} chars) — not appended"
    return 1
  }
  append_message_json "$msg"
}

append_tool_message() {
  local tci="$1" content="$2"
  # E2BIG guard like append_message: without a cap jq --arg failed silently,
  # the tool message went missing and the tool_call stayed unanswered (protocol
  # break) — now truncated, with a byte-count placeholder as a last resort.
  if (( ${#content} > 100000 )); then
    content="${content:0:100000}"$'\n... (truncated, '"${#content}"' bytes total)'
  fi
  local msg
  msg="$(jq -n --arg tci "$tci" --arg content "$content" '{role:"tool",tool_call_id:$tci,content:$content}')" || {
    log "append_tool_message: jq error (${#content} chars) — placeholder"
    msg="$(jq -n --arg tci "$tci" --arg content "(tool result could not be embedded: ${#content} bytes)" '{role:"tool",tool_call_id:$tci,content:$content}')" || return 1
  }
  append_message_json "$msg"
}

setup_messages() {
  session_init
  # O2 (step 17, 2026-09-29): wiki state always in context — index.md and
  # the newest log lines hang off the system prompt so that learning from the
  # Karpathy wiki does not depend on the model's random tool calls.
  local mem_ex=""
  if [[ -f "$_wiki_dir/wiki/index.md" ]]; then
    mem_ex+=$'\n\n# — Wiki state (automatic: '"$_wiki_dir"') —\n'
    mem_ex+="$(cat "$_wiki_dir/wiki/index.md" 2>/dev/null)"
  fi
  if [[ -f "$_wiki_dir/wiki/log.md" ]]; then
    mem_ex+=$'\n\n## recent entries from wiki/log.md\n'
    mem_ex+="$(tail -n 40 "$_wiki_dir/wiki/log.md" 2>/dev/null)"
  fi
  # Guard (review 2026-09-29): --arg is limited to 128 KB per argument;
  # an oversized wiki block would have emptied _messages -> startup abort.
  local sys="${_system_prompt}${mem_ex}"
  if (( ${#sys} > 100000 )); then
    sys="${sys:0:100000}"$'\n... (wiki state truncated, '"${#sys}"' bytes total)'
  fi
  _messages="$(jq -c -n --arg content "$sys" '[{role:"system",content:$content}]')" || {
    log "setup_messages: jq error (${#sys} chars) — system prompt without wiki"
    _messages="$(jq -c -n --arg content "$_system_prompt" '[{role:"system",content:$content}]')" || _messages='[]'
  }
}

# ---------------------------------------------------------------------------
# API call (OpenAI protocol, local LLM)
# ---------------------------------------------------------------------------
_build_tools() {
  jq -n '[
    {type:"function",function:{name:"read_file",description:"Reads a file and returns its contents.",parameters:{type:"object",properties:{path:{type:"string",description:"Path to the file"}},required:["path"]}}},
    {type:"function",function:{name:"write_file",description:"Writes a file (overwrites an existing one).",parameters:{type:"object",properties:{path:{type:"string",description:"Path to the file"},content:{type:"string",description:"File contents"}},required:["path","content"]}}},
    {type:"function",function:{name:"edit_file",description:"Replaces the first occurrence of a text block; with all:true it replaces every occurrence.",parameters:{type:"object",properties:{path:{type:"string",description:"Path to the file"},old:{type:"string",description:"Old text block"},new:{type:"string",description:"New text block"},all:{type:"boolean",description:"Replace every occurrence (default false)"}},required:["path","old","new"]}}},
    {type:"function",function:{name:"bash",description:"Runs a shell command and returns stdout/stderr (hard deny list; sudo goes through an approval gate).",parameters:{type:"object",properties:{command:{type:"string",description:"Command"}},required:["command"]}}},
    {type:"function",function:{name:"list_files",description:"Lists files. Without a pattern like ls -la; with pattern/recursive a file listing.",parameters:{type:"object",properties:{path:{type:"string",description:"Path to the directory"},pattern:{type:"string",description:"Glob against the file name, e.g. *.md"},recursive:{type:"boolean",description:"Recurse into subdirectories (default false)"}},required:["path"]}}},
    {type:"function",function:{name:"append_file",description:"Appends text to the end of a file without overwriting. For append-only files such as wiki/log.md.",parameters:{type:"object",properties:{path:{type:"string",description:"Path to the file"},content:{type:"string",description:"Text to append (own line)"}},required:["path","content"]}}},
    {type:"function",function:{name:"search",description:"Searches files and returns matches as path:line:text (locate before you write).",parameters:{type:"object",properties:{query:{type:"string",description:"Search term"},path:{type:"string",description:"Start path: file or directory (default: the project wiki)"},glob:{type:"string",description:"Filter on file names, e.g. *.md"},regex:{type:"boolean",description:"true = regular expression, default false = literal"}},"required":["query"]}}},
    {type:"function",function:{name:"fetch",description:"Downloads a web page and stores it as a raw source under <wiki>/raw/<topic>/YYYY-MM-DD-slug.md. Returns path, format and the beginning of the content.",parameters:{type:"object",properties:{url:{type:"string",description:"http(s) address of the page"},topic:{type:"string",description:"Target folder under raw/ (short name, no slashes)"},title:{type:"string",description:"Heading for the raw file (otherwise the page <title>)"}},required:["url","topic"]}}},
    {type:"function",function:{name:"todo",description:"Persistent task list. Plan a larger task completely first (add), then work through it step by step and tick it off (done); list shows the plan.",parameters:{type:"object",properties:{action:{type:"string",enum:["add","done","list"],description:"add = append a step, done = tick off a step, list = show the plan"},text:{type:"string",description:"Text of the step (required for add, optional search text for done)"},index:{type:"integer",description:"1-based index of the step (for done)"}},required:["action"]}}},
    {type:"function",function:{name:"mem_add",description:"Stores a memory as Markdown with YAML frontmatter under ~/.lex/mem/.",parameters:{type:"object",properties:{type:{type:"string",enum:["memory","fact","preference","note"],description:"Kind of memory"},content:{type:"string",description:"Content (first line = heading)"}},required:["type","content"]}}},
    {type:"function",function:{name:"mem_list",description:"Lists stored memories, optionally filtered by type.",parameters:{type:"object",properties:{type:{type:"string",enum:["memory","fact","preference","note"],description:"Optional filter"}}}}},
    {type:"function",function:{name:"mem_search",description:"Searches all memories and returns matches.",parameters:{type:"object",properties:{query:{type:"string",description:"Search term"}},required:["query"]}}},
    {type:"function",function:{name:"web_search",description:"Searches the web (DuckDuckGo) and returns title, URL and snippet — no API key involved.",parameters:{type:"object",properties:{query:{type:"string",description:"Search term or question"}},required:["query"]}}},
    {type:"function",function:{name:"web_fetch",description:"Pulls a known URL as plain text via a crawler (MCP), WITHOUT saving it. For lasting sources use fetch(url, topic).",parameters:{type:"object",properties:{url:{type:"string",description:"http(s) address of the page"},max_length:{type:"integer",description:"Maximum length in characters (default 8000, at most 50000)"}},required:["url"]}}},
    {type:"function",function:{name:"context7",description:"Current documentation for libraries and frameworks (context7) — the counterweight to stale model knowledge.",parameters:{type:"object",properties:{query:{type:"string",description:"Question for the docs, e.g. curl retries"},library:{type:"string",description:"Optional library, e.g. react or bash"}},required:["query"]}}},
    {type:"function",function:{name:"browser",description:"Drives a real browser (Playwright-MCP, system Chrome): navigate → snapshot (ARIA refs) → click/type by ref. Full control, no screenshot needed — the snapshot is text.",parameters:{type:"object",properties:{action:{type:"string",enum:["navigate","snapshot","click","type","press","back","tabs","close","wait"],description:"navigate=url | snapshot=page picture as refs | click/type=ref from snapshot | press=key | back | tabs (index?) | close | wait (text=seconds until the page has loaded)"},url:{type:"string",description:"Target URL (action=navigate)"},ref:{type:"string",description:"Element ref from the snapshot (click/type) — take a fresh snapshot after navigation first"},element:{type:"string",description:"Short description of the target element (for click/type, e.g. submit button)"},text:{type:"string",description:"Input text (action=type) | seconds (action=wait)"},key:{type:"string",description:"Key or combination (action=press, e.g. Enter, Tab, Control+a)"},index:{type:"integer",description:"Tab number (action=tabs, without index = tab list)"}},required:["action"]}}},
    {type:"function",function:{name:"mcp",description:"Generic MCP access: calls tools of any configured server (defuddle, context7, playwright, desktop, postgres + everything from mcp.json). FIRST tool empty or __tools to fetch the tool list, THEN call tool+arguments.",parameters:{type:"object",properties:{server:{type:"string",description:"Server name, e.g. playwright or defuddle"},tool:{type:"string",description:"Tool name of the server, or __tools / empty for the discovery list"},arguments:{type:"object",description:"Arguments as a JSON object, e.g. {\"url\":\"https://example.com\"}"}},required:["server"]}}}
  ]'
}

call_api() {
  # Nudge override (P2, live test 2026-09-29): single-use — set to 0 on the
  # truncation/empty nudge so visible text is guaranteed to come through
  # instead of reasoning eating all tokens again.
  local _rb="${_rb_override:-$_reasoning_budget}"
  _rb_override=""
  # Mock: file-based sequence (for tests)
  if [[ -n "${_mock_file:-}" && -f "${_mock_file}" ]]; then
    local line
    line="$(head -n1 "${_mock_file}" 2>/dev/null)"
    tail -n +2 "${_mock_file}" > "${_mock_file}.tmp" 2>/dev/null && mv "${_mock_file}.tmp" "${_mock_file}"
    if [[ -z "${line:-}" ]]; then
      echo '{"choices":[{"index":0,"message":{"role":"assistant","content":"Works.","reasoning_content":"","tool_calls":[]}}],"usage":{"total_tokens":10}}'
      return 0
    fi
    printf '%s\n' "$line"
    return 0
  fi
  # Mock: static
  if [[ "${_mock:-}" == "done" ]]; then
    echo '{"choices":[{"index":0,"message":{"role":"assistant","content":"Works.","reasoning_content":"","tool_calls":[]}}],"usage":{"total_tokens":10}}'
    return 0
  fi
  # Real server
  local tools_json mtf body_tf rc
  tools_json="$(_build_tools)"
  # Context via file (not --argjson): _messages grows monotonically; from
  # ~128 KiB onwards even jq becomes an exec argument (E2BIG) -> empty body -> API error.
  # --slurpfile reads the history without an argv limit (review finding 2026-09-29).
  mtf="$(mktemp)" || { echo "Error: cannot create temp file."; return 1; }
  printf '%s' "$_messages" >"$mtf" || { rm -f "$mtf"; return 1; }
  body_tf="$(mktemp)" || { rm -f "$mtf"; echo "Error: cannot create temp file."; return 1; }
  jq -n \
    --slurpfile m "$mtf" \
    --argjson t "$tools_json" \
    --arg model "$_model" \
    --argjson max_tokens "$_max_tokens" \
    --argjson rb "$_rb" \
    --argjson temp "$_temperature" \
    '{model:$model,messages:$m[0],tools:$t,max_tokens:$max_tokens,reasoning_budget_tokens:$rb,temperature:$temp}' >"$body_tf"
  rc=$?
  rm -f "$mtf"
  if (( rc != 0 )); then
    rm -f "$body_tf"
    echo "Error: could not build the request body (jq)." >&2
    return 1
  fi
  # ENV is evaluated at runtime so tests/REPL can still change the URL
  # after load_config() ran (docs: "ENV overrides everything").
  # body via file: from ~128 KiB an exec argument is too long (E2BIG —
  # multi-turn runs push the history past the kernel limit, live finding
  # 2026-09-29). curl reads @file without an argv limit; the timeout is now
  # controllable because higher max_tokens means longer generations.
  local url="${LEX_API_URL:-${_api_url:-$_default_api_url}}"
  curl -sf --max-time "${LEX_API_TIMEOUT:-1800}" "$url" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${_api_key:-}" \
    -d @"$body_tf"
  rc=$?
  rm -f "$body_tf"
  return "$rc"
}

# ---------------------------------------------------------------------------
# Tools
# ---------------------------------------------------------------------------
safe_path() {
  local p="$1"
  local resolved real
  # Tilde expansion (P3, review 2026-09-29): realpath does not know ~ — otherwise
  # ~/x would resolve to $PWD/~/x and every tilde file would say "not found".
  # shellcheck disable=SC2088  # the tilde arrives unexpanded from the model
  if [[ "$p" == "~" ]]; then
    p="$HOME"
  elif [[ "$p" == "~/"* ]]; then
    p="$HOME/${p#\~/}"
  fi
  resolved="$(_abs_path "$p")"
  [[ -z "${resolved:-}" ]] && resolved="$p"
  # resolve the symlink target if realpath/readlink -f are missing: a link to
  # /etc/passwd must not slip past the permission check (P1, 2026-09-28).
  if [[ -L "$resolved" ]]; then
    real="$(readlink -f "$resolved" 2>/dev/null || realpath "$resolved" 2>/dev/null)"
    [[ -n "${real:-}" ]] && resolved="$real"
  fi
  case "$resolved" in
    /etc|/etc/*|/usr|/usr/*|/bin|/bin/*|/sbin|/sbin/*|/boot|/boot/*|/dev|/dev/*|\
    /proc|/proc/*|/sys|/sys/*|/var|/var/*|/lib|/lib/*|/lib64|/lib64/*|/root|/root/*)
      echo "safe_path: access to $resolved is not allowed." >&2
      return 1
      ;;
  esac
  printf '%s\n' "$resolved"
}

tool_read_file() {
  local path="$1"
  local resolved
  resolved="$(safe_path "$path")" || return 1
  if [[ ! -f "$resolved" ]]; then
    echo "Error: file '$resolved' not found."
    return 1
  fi
  # Cap like tool_bash/tool_search (step 17b): Linux limits arguments
  # to 128 KB (MAX_ARG_STRLEN) — a 135 KB file made jq fail with E2BIG
  # and afterwards emptied the whole context.
  local content max_len="${_tool_max_output:-50000}" len
  content="$(cat "$resolved")"
  len=${#content}
  if (( len > max_len )); then
    content="${content:0:max_len}"
    content+=$'\n... (truncated, '"${len}"' bytes total)'
  fi
  printf '%s\n' "$content"
}

tool_write_file() {
  local path="$1" content="$2"
  local resolved dir tmp mode
  resolved="$(safe_path "$path")" || return 1
  dir="$(dirname "$resolved")"
  if ! mkdir -p "$dir" 2>/dev/null; then
    echo "Error: cannot create directory '$dir'."
    return 1
  fi
  # Atomic (P2, review 2026-09-29): temp file inside the target directory, then mv —
  # an aborted write never leaves a half-written file.
  tmp="$(mktemp "${dir}/.lex-write.XXXXXX")" || {
    echo "Error: cannot create temp file."
    return 1
  }
  if ! printf '%s\n' "$content" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    echo "Error: file '$resolved' is not writable."
    return 1
  fi
  if [[ -f "$resolved" ]]; then
    _copy_mode "$resolved" "$tmp"
  else
    # New file: mode as with a plain > (0666 & ~umask), otherwise it stays 600.
    mode="$(umask)"
    if [[ "$mode" =~ ^0?[0-7]{3,4}$ ]]; then
      printf -v mode '%o' $(( 0666 & ~0$mode ))
      chmod "$mode" "$tmp" 2>/dev/null || true
    else
      chmod 644 "$tmp" 2>/dev/null || true
    fi
  fi
  if mv "$tmp" "$resolved" 2>/dev/null; then
    echo "File '$resolved' written."
  else
    rm -f "$tmp"
    echo "Error: file '$resolved' is not writable."
    return 1
  fi
}

tool_edit_file() {
  local path="$1" old="$2" new="$3" all="${4:-false}"
  local resolved content out rest count n do_all raw tnl
  resolved="$(safe_path "$path")" || return 1
  if [[ ! -f "$resolved" ]]; then
    echo "Error: file '$resolved' not found."
    return 1
  fi
  if [[ -z "$old" ]]; then
    echo "Error: search text must not be empty."
    return 1
  fi
  # count trailing newlines before $(cat) strips them (P2, review
  # 2026-09-29): otherwise the file loses its trailing blank lines or
  # ends up with exactly one — both describe the original state wrongly.
  raw="$(cat "$resolved"; printf x)"
  raw="${raw%x}"
  content="$raw"
  tnl=0
  while [[ "$content" == *$'\n' ]]; do
    content="${content%$'\n'}"
    tnl=$((tnl + 1))
  done
  if [[ "$content" != *"$old"* ]]; then
    echo "Error: search text not found in '$resolved'."
    return 1
  fi
  # count occurrences (feedback for the model)
  count=0
  rest="$content"
  while [[ "$rest" == *"$old"* ]]; do
    rest="${rest#*"$old"}"
    count=$((count + 1))
  done
  do_all=0
  case "$all" in true|1|yes|on) do_all=1 ;; esac
  out=""
  n=0
  if (( do_all )); then
    rest="$content"
    while [[ "$rest" == *"$old"* ]]; do
      out+="${rest%%"$old"*}${new}"
      rest="${rest#*"$old"}"
      n=$((n + 1))
    done
    out+="$rest"
  else
    out="${content%%"$old"*}${new}${content#*"$old"}"
    n=1
  fi
  local tmp dir
  # temp file INSIDE the target directory (atomic mv, no cross-device) — and with
  # the mode of the template, otherwise the file ends up at 600 after edit_file (P2).
  dir="$(dirname "$resolved")"
  tmp="$(mktemp "${dir}/.lex-edit.XXXXXX")" || {
    echo "Error: cannot create temp file."; return 1
  }
  {
    printf '%s' "$out"
    while (( tnl > 0 )); do
      printf '\n'
      tnl=$((tnl - 1))
    done
  } > "$tmp"
  _copy_mode "$resolved" "$tmp"
  if mv "$tmp" "$resolved" 2>/dev/null; then
    echo "File '$resolved' edited ($n of $count occurrences replaced)."
  else
    rm -f "$tmp"
    echo "Error: file '$resolved' cannot be edited."
    return 1
  fi
}

# Hard deny list for tool_bash (bug #11) — ALWAYS active, independent of --approve.
# Split the command into segments (line end, &&, ||, | ;) for the deny list.
# Heuristic: quotes stay part of the segment — harmless, because the
# deny list only catches catastrophic patterns.
_bash_segments() {
  local c="$1"
  c="${c//$'\n'/;}"
  c="${c//&&/$'\n'}"
  c="${c//||/$'\n'}"
  # A single & is also a command separator (`curl … & sh f.sh` — P1,
  # review 2026-09-29); && was already replaced above.
  c="${c//&/$'\n'}"
  c="${c//|/$'\n'}"
  c="${c//;/$'\n'}"
  printf '%s\n' "$c"
}

# check rm targets: catastrophic targets even in variants that slip past the
# Forms that passed the check (P1, 2026-09-28): `rm -rf -- /`, `rm -Rf /`,
# `rm --no-preserve-root -rf /`, `sudo rm -rf /`, `xargs rm -rf /`.
_rm_targets_catastrophic() {
  local seg a i h rest
  local -a w
  while IFS= read -r seg; do
    [[ "$seg" =~ (^|[[:space:]])rm([[:space:]]|$) ]] || continue
    read -r -a w <<< "$seg" || true
    (( ${#w[@]} >= 2 )) || continue
    for a in "${w[@]}"; do
      [[ "$a" == -* ]] && continue
      [[ "$a" =~ ^[0-9]+$ ]] && continue
      a="${a//\"/}"
      a="${a//\'/}"
      # shellcheck disable=SC2088  # tilde compared as a LITERAL token
      if [[ "$a" == "/" || "$a" == "/*" || "$a" == "." || "$a" == "./" ||
            "$a" == "~" || "$a" == "~/" || "$a" == '$HOME' || "$a" == '$HOME/' ||
            "$a" == "${HOME:-__lex_no_home__}" ]]; then
        return 0
      fi
      # $HOME deletion in expanded AND literal form (P1, review
      # 2026-09-29): `rm -rf ${HOME}`, `"$HOME"/.`, `~/.` delete
      # the whole home — the exact comparisons slipped past those.
      # Blocked is the home ROOT (incl. .-/..-components and
      # trailing slash), subtrees like ~/project stay allowed.
      if [[ "$a" == '$HOME'* || "$a" == '${HOME}'* ]]; then
        rest="${a#\$HOME}"
        rest="${rest#\$\{HOME\}}"
        if [[ "$rest" =~ ^(/\.*)*$ ]]; then
          return 0
        fi
      fi
      h="${HOME:-__lex_no_home__}"
      if [[ "$a" == "$h" || "$a" == "$h/"* ]]; then
        rest="${a#"$h"}"
        if [[ "$rest" =~ ^(/\.*)*$ ]]; then
          return 0
        fi
      fi
      # shellcheck disable=SC2088  # tilde compared as a LITERAL token
      if [[ "$a" == "~" || "$a" == "~/"* ]]; then
        rest="${a#\~}"
        if [[ "$rest" =~ ^(/\.*)*$ ]]; then
          return 0
        fi
      fi
    done
  done <<< "$(_bash_segments "$1")"
  return 1
}

# su as command word of a segment (possibly behind sudo/env/… wrappers) —
# covers `su postgres -c …` without matching `grep su - …` (P2).
_su_is_command() {
  local seg i
  local -a w
  while IFS= read -r seg; do
    read -r -a w <<< "$seg" || true
    (( ${#w[@]} >= 1 )) || continue
    i=0
    while (( i < ${#w[@]} )); do
      case "${w[i]}" in
        sudo|env|command|builtin|nohup|nice|ionice|time|setsid|eval|exec|xargs|-*)
          i=$((i + 1)) ;;
        *) break ;;
      esac
    done
    (( i < ${#w[@]} )) || continue
    if [[ "${w[i]}" == "su" ]]; then
      return 0
    fi
  done <<< "$(_bash_segments "$1")"
  return 1
}

_bash_denied() {
  local c
  c="$(printf '%s' "$1" | tr -s '[:space:]' ' ')"
  if _rm_targets_catastrophic "$c"; then
    printf '%s\n' "Deleting with rm on the filesystem root or home" ; return 0
  fi
  case "$c" in
    *mkfs*|*wipefs*|*blkdiscard*|*"shred /dev"*|*hdparm*|*badblocks*|*"dd if="*"of=/dev/"*)
      printf '%s\n' "Formatting or destroying storage media" ; return 0 ;;
    *"of=/dev/"*|*"> /dev/sd"*|*"> /dev/nvme"*|*"> /dev/mmcblk"*)
      printf '%s\n' "Writing to a block device" ; return 0 ;;
    *":|:&"*)
      printf '%s\n' "Fork bomb" ; return 0 ;;
    *shutdown*|*reboot*|*poweroff*|*"halt -"*)
      printf '%s\n' "Shutting down/restarting the system" ; return 0 ;;
    *"kill -9 1"*|*"kill -9 -1"*|*"killall -9"*|*"kill -s KILL -1"*)
      printf '%s\n' "Force-killing system processes" ; return 0 ;;
    *"chmod -R 777 /"*|*"chown -R /"*|*"chown -R ./"*)
      printf '%s\n' "Recursively loosening permissions" ; return 0 ;;
    *"history -c"*|*"unset HISTFILE"*)
      printf '%s\n' "Wiping traces" ; return 0 ;;
  esac
  if _su_is_command "$c"; then
    printf '%s\n' "Privilege escalation via su (sudo goes through _sudo_gate)" ; return 0
  fi
  # curl|sh pattern: check ALL segments, not just the last one — otherwise
  # `curl …|sh|cat` and `curl … && sh x.sh` bypass the check (P1).
  # Wrappers (sudo/env/nohup/…) and direct execution (eval "$(curl …)",
  # `bash <(curl …)`) cover the further bypasses (review 2026-09-29).
  if [[ "$c" == *curl* || "$c" == *wget* || "$c" == *http* ]]; then
    local seg a idx=0 wi
    local -a w
    while IFS= read -r seg; do
      idx=$((idx + 1))
      read -r -a w <<< "$seg" || true
      (( ${#w[@]} >= 1 )) || continue
      wi=0
      while (( wi < ${#w[@]} )); do
        case "${w[wi]}" in
          sudo|env|command|builtin|nohup|nice|ionice|time|setsid|xargs|-*)
            wi=$((wi + 1)) ;;
          *) break ;;
        esac
      done
      (( wi < ${#w[@]} )) || continue
      a="${w[wi]}"; a="${a//\"/}"
      case "$a" in
        sh|bash|zsh|ash|ksh|/bin/sh|/bin/bash|/bin/zsh|/bin/ash|\
        /usr/bin/sh|/usr/bin/bash|/usr/bin/zsh)
          if (( idx > 1 )); then
            printf '%s\n' "Piping a download into a shell" ; return 0
          fi
          if [[ "$seg" == *'<('* ]]; then
            printf '%s\n' "process substitution of a download" ; return 0
          fi
          ;;
        eval|exec|source|.)
          if [[ "$seg" == *curl* || "$seg" == *wget* ]]; then
            printf '%s\n' "Executing a download directly (eval/source)" ; return 0
          fi
          ;;
      esac
    done <<< "$(_bash_segments "$c")"
  fi
  return 1
}

# Opt-in approval (bug #11): only with --approve/LEX_APPROVE=1 and a controlling TTY.
_approve_request() {
  local cmd="$1" ans=""
  [[ -e /dev/tty ]] || return 1
  printf 'Approve command (y/N): %s\n' "$cmd" > /dev/tty 2>/dev/null || return 1
  IFS= read -r ans < /dev/tty || ans=""
  case "$ans" in
    y|Y|yes|YES|j|J|ja|JA) return 0 ;;
  esac
  return 1
}

# ---------------------------------------------------------------------------
# sudo gate (§6 #13) — a gate instead of a ban, ALWAYS EXACTLY ONE prompt:
#   * no valid sudo ticket -> _sudo_ask(): show the command on the controlling
#     TTY, then `sudo -v`. The password goes STRAIGHT to sudo — it never runs
#     through lex (no variable, no log, tool_bash stdin stays
#     </dev/null and is not used for sudo).
#   * valid ticket           -> _approve_request() asks y/N.
# No controlling TTY -> refusal. LEX_SUDO=0 switches sudo off completely.
# ---------------------------------------------------------------------------
_sudo_gate_reason=""

_needs_sudo() {
  local c
  c="$(printf '%s' "$1" | tr -s '[:space:]' ' ')"
  case "$c" in
    *"sudo "*) return 0 ;;
  esac
  return 1
}

_tty_ok() {
  [[ -e /dev/tty && -r /dev/tty && -w /dev/tty ]] || return 1
  # /dev/tty exists even without a controlling terminal (containers) — real test:
  { : < /dev/tty; } 2>/dev/null || return 1
  return 0
}

_sudo_ticket_valid() {
  sudo -n true 2>/dev/null
}

_sudo_ask() {
  local cmd="$1"
  _tty_ok || return 1
  printf 'lex needs root rights for:\n  %s\n' "$cmd" > /dev/tty 2>&1 || return 1
  # sudo reads the password itself over the controlling TTY (explicit input),
  # the message goes to stderr = terminal. Deliberately NO `>` here: such
  # file redirections are applied by the calling shell, not sudo (warning SC2024
  # would be legitimate here).
  sudo -v < /dev/tty || return 1
  _sudo_ticket_valid
}

_sudo_gate() {
  local cmd="$1"
  _sudo_gate_reason=""
  if [[ "${_sudo:-1}" != "1" ]]; then
    _sudo_gate_reason="sudo disabled (LEX_SUDO=0)"
    return 1
  fi
  if ! _sudo_ticket_valid; then
    if ! _sudo_ask "$cmd"; then
      _sudo_gate_reason="sudo ticket not obtained (no TTY, wrong password or aborted)"
      return 1
    fi
    return 0
  fi
  if [[ "${_sudo_approve:-1}" == "1" ]] && ! _approve_request "$cmd"; then
    _sudo_gate_reason="no approval granted"
    return 1
  fi
  return 0
}

tool_bash() {
  local command="$1"
  local output rc deny
  deny="$(_bash_denied "$command")"
  if [[ -n "${deny:-}" ]]; then
    echo "Refused: ${deny} (deny list)."
    log "tool: bash refused — ${deny}"
    return 1
  fi
  # bug #13 — sudo is no longer a ban but a gate with EXACTLY ONE
  # prompt. Deliberately in the current shell instead of $(...), so the ticket
  # fetched by _sudo_ask applies in the same context as the execution.
  if _needs_sudo "$command"; then
    if ! _sudo_gate "$command"; then
      echo "Refused: sudo — ${_sudo_gate_reason}."
      log "tool: bash sudo refused — ${_sudo_gate_reason}"
      return 1
    fi
  elif [[ "${_approve:-0}" == "1" ]] && ! _approve_request "$command"; then
    echo "Refused: no approval granted."
    log "tool: bash without approval"
    return 1
  fi
  output="$(_run_limited "${_tool_timeout:-60}" bash -c "$command" </dev/null 2>&1)"; rc=$?
  local max_len="${_tool_max_output:-50000}"
  local len=${#output}
  if (( len > max_len )); then
    output="${output:0:max_len}"
    output+=$'\n... (truncated, '"${len}"' bytes total)'
  fi
  if (( rc != 0 )); then
    printf 'Exit code: %s\n%s\n' "$rc" "$output"
  else
    printf '%s\n' "$output"
  fi
}

tool_list_files() {
  local path="$1" pattern="${2:-}" recursive="${3:-false}"
  local resolved f base
  resolved="$(safe_path "$path")" || return 1
  if [[ ! -d "$resolved" ]]; then
    echo "Error: directory '$resolved' not found."
    return 1
  fi

  # Without a pattern and without recursion the old behaviour remains (ls -la).
  if [[ -z "$pattern" && "$recursive" != "true" ]]; then
    ls -la "$resolved" 2>/dev/null || return 1
    return 0
  fi

  local out="" count=0
  if [[ "$recursive" == "true" ]]; then
    # find without -maxdepth (GNU extension, bug #8): portability first.
    while IFS= read -r f; do
      [[ -f "$f" ]] || continue
      if [[ -n "$pattern" ]]; then
        base="$(basename "$f")"
        # shellcheck disable=SC2053  # glob matching is intentional here.
        [[ "$base" == $pattern ]] || continue
      fi
      out+="$f"$'\n'
      count=$((count + 1))
      (( count >= 500 )) && { out+="... (truncated at 500 files)"$'\n'; break; }
    done < <(find "$resolved" -type f 2>/dev/null | LC_ALL=C sort)
  else
    shopt -s nullglob
    local -a entries
    entries=( "$resolved"/* )
    shopt -u nullglob
    for f in "${entries[@]}"; do
      [[ -f "$f" ]] || continue
      if [[ -n "$pattern" ]]; then
        base="$(basename "$f")"
        # shellcheck disable=SC2053  # glob matching is intentional here.
        [[ "$base" == $pattern ]] || continue
      fi
      out+="$f"$'\n'
      count=$((count + 1))
    done
  fi
  if (( count == 0 )); then
    echo "No file found in '$resolved' (pattern: ${pattern:-<all>})."
    return 1
  fi
  printf '%s' "$out"
}

# Append-only write (wiki/log.md, wiki/index.md) — the counterpart to write_file.
tool_append_file() {
  local path="$1" content="$2"
  local resolved dir
  resolved="$(safe_path "$path")" || return 1
  dir="$(dirname "$resolved")"
  if ! mkdir -p "$dir" 2>/dev/null; then
    echo "Error: cannot create directory '$dir'."
    return 1
  fi
  if ! printf '%s\n' "$content" >> "$resolved" 2>/dev/null; then
    echo "Error: file '$resolved' is not writable."
    return 1
  fi
  echo "Appended to '$resolved' (${#content} characters)."
}

# Full-text search for triage/grounding (locate before you write).
tool_search() {
  local query="$1" path="${2:-$_wiki_dir}" glob="${3:-}" regex="${4:-false}"
  local resolved out rc max_lines len max_len
  if [[ -z "$query" ]]; then
    echo "Error: search term must not be empty."
    return 1
  fi
  resolved="$(safe_path "$path")" || return 1
  if [[ ! -e "$resolved" ]]; then
    echo "Error: path '$resolved' not found."
    return 1
  fi
  local -a grep_args=(-rIn --binary-files=without-match --exclude-dir=.git)
  case "$regex" in
    true|1|yes|on) grep_args+=(-E) ;;
    *)             grep_args+=(-F) ;;
  esac
  if [[ -n "$glob" ]]; then
    grep_args+=(--include="$glob")
  fi
  out="$(grep "${grep_args[@]}" -- "$query" "$resolved" 2>/dev/null)"
  rc=$?
  if (( rc == 1 )) || [[ -z "$out" ]]; then
    echo "No matches for '$query' in '$resolved'."
    return 1
  elif (( rc > 1 )); then
    echo "Error: search in '$resolved' failed (grep rc=$rc)."
    return 1
  fi
  max_lines=200
  len="$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
  if (( len > max_lines )); then
    out="$(printf '%s\n' "$out" | head -n "$max_lines")"
    out+=$'\n... ('"$len"' matches total, truncated to 200)'
  fi
  max_len="${_tool_max_output:-50000}"
  len=${#out}
  if (( len > max_len )); then
    out="${out:0:max_len}"
    out+=$'\n... (truncated, '"${len}"' bytes total)'
  fi
  printf '%s\n' "$out"
}

# ---------------------------------------------------------------------------
# Planning: persistent task list for ALL runs (larger tasks)
# Deliberately session-independent (decision 2026-09-28): the plan runs like
# the wiki and the mem tools across sessions — one stable path
# instead of <session-id>.md, so a new run keeps reading the old plan.
# ---------------------------------------------------------------------------
_todo_file() {
  printf '%s\n' "${_lex_home}/plans/plan.md"
}

tool_todo() {
  local action="$1" text="${2:-}" index="${3:-}"
  local file dir line out i found n tmp done_n rest_n
  file="$(_todo_file)"
  dir="$(dirname "$file")"

  case "$action" in
    list)
      if [[ ! -f "$file" ]]; then
        echo "No plan yet (nothing planned)."
        return 0
      fi
      printf 'Plan (%s):\n' "$file"
      cat "$file"
      return 0
      ;;
    add)
      if [[ -z "$text" ]]; then
        echo "Error: text must not be empty for action=add."
        return 1
      fi
      mkdir -p "$dir" 2>/dev/null || { echo "Error: cannot create '$dir'."; return 1; }
      printf -- '- [ ] %s\n' "$text" >> "$file" || { echo "Error: plan is not writable."; return 1; }
      n="$(grep -c '^- \[' "$file" 2>/dev/null || true)"
      printf 'Plan: step %s appended.\n' "${n:-1}"
      printf 'Plan (%s):\n' "$file"
      cat "$file"
      return 0
      ;;
    done)
      if [[ ! -f "$file" ]]; then
        echo "Error: no plan yet."
        return 1
      fi
      if [[ -z "$index" && -z "$text" ]]; then
        echo "Error: for action=done give an index (1-based) or text."
        return 1
      fi
      if [[ -n "$index" && ! "$index" =~ ^[0-9]+$ ]]; then
        echo "Error: index must be a number (got: '$index')."
        return 1
      fi
      # index refers to the DISPLAY order (all lines, including completed ones)
      i=0 found=0 already=0 out=""
      while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
          '- [ ] '*|'- [x] '*)
            i=$((i + 1))
            if [[ -n "$index" && "$i" == "$index" ]] ||
               [[ -z "$index" && -n "$text" && "$line" == *"$text"* ]]; then
              found=1
              index="$i"
              if [[ "$line" == '- [x] '* ]]; then
                already=1
              else
                line="- [x]${line#- \[ \]}"
              fi
            fi
            ;;
        esac
        out+="$line"$'\n'
      done < "$file"
      if (( ! found )); then
        echo "Error: step not found (index: ${index:-<none>}, text: ${text:-<empty>})."
        return 1
      fi
      if (( already )); then
        printf 'Step %s is already done.\n' "$index"
        printf 'Plan (%s):\n' "$file"
        cat "$file"
        return 0
      fi
      tmp="$(mktemp "${dir}/plan.XXXXXX")" || { echo "Error: cannot create temp file."; return 1; }
      if ! printf '%s' "$out" > "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        echo "Error: plan '$file' is not writable."
        return 1
      fi
      _copy_mode "$file" "$tmp"
      if ! mv "$tmp" "$file" 2>/dev/null; then
        rm -f "$tmp"
        echo "Error: plan '$file' is not writable."
        return 1
      fi
      done_n="$(grep -c '^- \[x\]' "$file" 2>/dev/null || true)"
      rest_n="$(grep -c '^- \[ \]' "$file" 2>/dev/null || true)"
      printf 'Plan: step %s done (%s of %s).\n' "$index" "${done_n:-0}" "$(( ${done_n:-0} + ${rest_n:-0} ))"
      printf 'Plan (%s):\n' "$file"
      cat "$file"
      return 0
      ;;
    *)
      echo "Error: action must be add, done or list (got: '$action')."
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Input readline (step C, 2026-09-28): arrow keys, history, tab
# ---------------------------------------------------------------------------
# Pure Bash, no new dependency: `read -e` uses the built-in
# readline of bash (arrow keys, Ctrl-A/E/W/U, tab = path completion),
# the history lives as a file under ~/.lex/history (max. 500 entries).
_hist_file=""

_hist_init() {
  _hist_file="${_lex_home}/history"
  mkdir -p "$_lex_home" 2>/dev/null || return 0
  # Without emacs mode `bind` complains in non-interactive shells.
  set -o emacs 2>/dev/null || true
  bind 'set completion-ignore-case on' 2>/dev/null || true
  bind 'set show-all-if-ambiguous on' 2>/dev/null || true
  if [[ -f "$_hist_file" ]]; then
    local lines
    lines="$(wc -l < "$_hist_file" | tr -d ' ')"
    if [[ "$lines" =~ ^[0-9]+$ ]] && (( lines > 500 )); then
      tail -n 500 "$_hist_file" > "${_hist_file}.tmp" 2>/dev/null && mv "${_hist_file}.tmp" "$_hist_file"
    fi
    history -r "$_hist_file" 2>/dev/null || true
  fi
}

_hist_add() {
  [[ -n "${_hist_file:-}" ]] || return 0
  history -s "$1" 2>/dev/null || true
  history -a "$_hist_file" 2>/dev/null || true
}

# fetch (spec §6.6): raw source into <wiki>/raw/<topic>/YYYY-MM-DD-slug.md
# fetch (spec §6.6): raw source to <wiki>/raw/<topic>/YYYY-MM-DD-slug.md
# Generic slug (same rules as memory: lowercase, a-z0-9, max 48).
_slug() {
  local s
  s="$(_mem_slug "$1")"
  while [[ "$s" == *--* ]]; do s="${s//--/-}"; done
  printf '%s\n' "$s"
}

# HTML → plain text, pure awk (no new dependency). We keep headings,
# lists and link targets, drop tags/navigation/scripts and resolve entities
# back. Deliberately NOT a Markdown converter: raw/ is raw material, it gets
# formatted only during the compile step into wiki/.
_html_to_text() {
  awk '
  function repl(s, pat, rep,   out) {
    out = ""
    while (match(s, pat)) {
      out = out substr(s, 1, RSTART - 1) rep
      s = substr(s, RSTART + RLENGTH)
    }
    return out s
  }
  function clean(s) {
    gsub(/<[^>]*>/, "", s)
    s = repl(s, "&amp;",  "&")
    s = repl(s, "&lt;",   "<")
    s = repl(s, "&gt;",   ">")
    s = repl(s, "&quot;", "\"")
    s = repl(s, "&#39;",  sprintf("%c", 39))
    s = repl(s, "&#x27;", sprintf("%c", 39))
    s = repl(s, "&nbsp;", " ")
    s = repl(s, "&auml;", "ä")
    s = repl(s, "&ouml;", "ö")
    s = repl(s, "&uuml;", "ü")
    s = repl(s, "&Auml;", "Ä")
    s = repl(s, "&Ouml;", "Ö")
    s = repl(s, "&Uuml;", "Ü")
    s = repl(s, "&szlig;", "ß")
    s = repl(s, "&euro;", "€")
    s = repl(s, "&hellip;", "…")
    s = repl(s, "&mdash;", "—")
    gsub(/[ \t]+/, " ", s)
    sub(/^[ \t]+/, "", s)
    sub(/[ \t]+$/, "", s)
    return s
  }
  # <a href="x">Text</a> → Text (x) — the target belongs on the link text,
  # not at the end of the paragraph.
  function linkify(s,   out, tag, ltag, rest, href, cpos, inner) {
    out = ""
    while (match(s, /<a[ >][^>]*>/)) {
      out = out substr(s, 1, RSTART - 1)
      tag = substr(s, RSTART, RLENGTH)
      rest = substr(s, RSTART + RLENGTH)
      ltag = tolower(tag)
      href = ""
      if (match(ltag, /href="[^"]*"/)) href = substr(tag, RSTART + 6, RLENGTH - 7)
      cpos = index(rest, "</a>")
      if (cpos > 0) {
        inner = substr(rest, 1, cpos - 1)
        rest = substr(rest, cpos + 4)
      } else {
        inner = rest
        rest = ""
      }
      inner = clean(inner)
      if (inner != "" && href != "") out = out inner " (" href ")"
      else if (inner != "")           out = out inner
      s = rest
    }
    return out s
  }
  function plain(s) { return clean(linkify(s)) }
  function emit(raw,   low, lvl, t, pre, i) {
    low = tolower(raw)
    if (low ~ /<script/ || low ~ /<style/ || low ~ /<!--/) return
    if (low ~ /<title/) return
    if (low ~ /<nav[ >]/ || low ~ /<footer[ >]/) return
    lvl = 0
    for (i = 1; i <= 6; i++) if (low ~ ("<h" i "[ >]")) lvl = i
    if (lvl > 0) {
      t = plain(raw)
      if (t != "") {
        pre = ""
        for (i = 1; i <= lvl; i++) pre = pre "#"
        print pre " " t
      }
      return
    }
    if (low ~ /<li[ >]/) { t = plain(raw); if (t != "") print "- " t; return }
    t = plain(raw)
    if (t ~ /[^ \t]/) print t
  }
  {
    # the formatter packs several <li> into one line — split them up first,
    # otherwise the items stick together.
    n = split($0, parts, /<\/li>/)
    for (i = 1; i <= n; i++) if (parts[i] ~ /[^ \t]/) emit(parts[i])
  }' "$1"
}

# Decode a single line/heading (for the page title),
# so slug and heading do not keep HTML entities.
_html_decode() {
  printf '<p>%s</p>' "$1" | _html_to_text -
}

tool_fetch() {
  local url="$1" topic="$2" title="${3:-}"
  local tmp err rc size ct fmt body today slug dir target i orig_topic

  if [[ -z "$url" ]]; then
    echo "Error: url is missing."
    return 1
  fi
  case "$url" in
    http://*|https://*) ;;
    *) echo "Error: only http(s) URLs are allowed (got: '$url')."; return 1 ;;
  esac
  if [[ -z "$topic" ]]; then
    echo "Error: topic missing — raw/<topic>/ is required (check existing folders with list_files)."
    return 1
  fi
  orig_topic="$topic"
  topic="$(_slug "$topic")"
  if [[ -z "$topic" ]]; then
    echo "Error: '$orig_topic' does not yield a valid folder name."
    return 1
  fi

  tmp="$(mktemp)" || { echo "Error: cannot create temp file."; return 1; }
  err="${tmp}.err"
  ct="$(curl -fsSL --max-time 30 --max-filesize 5000000 -A 'lex-wiki-ingest/0.1' -w '%{content_type}' -o "$tmp" "$url" 2>"$err")"
  rc=$?
  if (( rc != 0 )); then
    printf 'Error: download failed (curl rc=%s): %s\n' "$rc" "$(tr '\n' ' ' < "$err" 2>/dev/null | cut -c1-200)"
    rm -f "$tmp" "$err"
    return 1
  fi
  size="$(wc -c < "$tmp" | tr -d ' ')"
  if [[ ! "$size" =~ ^[0-9]+$ ]] || (( size == 0 )); then
    echo "Error: empty response from '$url'."
    rm -f "$tmp" "$err"
    return 1
  fi
  if (( size > 5000000 )); then
    echo "Error: response too large (${size} bytes > 5000000)."
    rm -f "$tmp" "$err"
    return 1
  fi

  fmt="text"
  if grep -a -qi '<html\|<!doctype html' "$tmp" || [[ "$ct" == *html* ]]; then
    fmt="html"
  fi
  if [[ "$fmt" == "html" ]]; then
    body="$(_html_to_text "$tmp")"
  else
    body="$(cat "$tmp")"
  fi
  if [[ -z "${body//[$' \t\n']/}" ]]; then
    echo "Error: no content left after cleanup."
    rm -f "$tmp" "$err"
    return 1
  fi

  if [[ -z "$title" ]]; then
    title="$(grep -a -io '<title[^>]*>[^<]*' "$tmp" 2>/dev/null | head -n1 || true)"
    title="${title#*>}"
  fi
  if [[ -z "${title//[$' \t']/}" ]]; then
    title="${url##*/}"
    title="${title%%\?*}"
  fi
  [[ -n "$title" ]] || title="Page"
  title="$(_html_decode "$title")"
  title="$(printf '%s' "$title" | tr '\r\n' '  ' | cut -c1-120)"

  slug="$(_slug "$title")"
  [[ -n "$slug" ]] || slug="$(_slug "$(basename "$url")")"
  [[ -n "$slug" ]] || slug="page"
  today="$(date +%F)"
  dir="${_wiki_dir}/raw/${topic}"
  mkdir -p "$dir" 2>/dev/null || { echo "Error: cannot create '$dir'."; rm -f "$tmp" "$err"; return 1; }

  target="${dir}/${today}-${slug}.md"
  i=2
  while [[ -e "$target" && $i -le 50 ]]; do
    target="${dir}/${today}-${slug}-${i}.md"
    i=$((i + 1))
  done
  if [[ -e "$target" ]]; then
    echo "Error: target name taken (50 attempts, '$target')."
    rm -f "$tmp" "$err"
    return 1
  fi

  if ! {
    printf '# %s\n\n' "$title"
    printf '> Source: %s\n' "$url"
    printf '> Collected: %s\n' "$today"
    printf '> Published: Unknown\n\n'
    printf '%s\n' "$body"
  } > "$target" 2>/dev/null; then
    echo "Error: '$target' is not writable."
    rm -f "$tmp" "$err"
    return 1
  fi
  rm -f "$tmp" "$err"

  printf 'Raw file: %s\n' "$target"
  printf 'Format: %s · Type: %s · Bytes: %s · Title: %s\n' "$fmt" "${ct:-unknown}" "$size" "$title"
  printf 'Beginning:\n%.1500s\n' "$body"
}

# ---------------------------------------------------------------------------
# Memory (Spec §6.4): Markdown + YAML-Frontmatter in ~/.lex/mem/
# ---------------------------------------------------------------------------
_mem_valid_type() {
  case "$1" in memory|fact|preference|note) return 0 ;; esac
  return 1
}

_mem_slug() {
  local s
  s="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | cut -c1-48)"
  while [[ "$s" == -* ]]; do s="${s#-}"; done
  while [[ "$s" == *- ]]; do s="${s%-}"; done
  printf '%s\n' "$s"
}

# ---------------------------------------------------------------------------
# MCP (stdio, JSON-RPC 2.0): crawler (defuddle), docs (context7) and
# Browser control (playwright, step 22 — system Chrome, no download).
# ---------------------------------------------------------------------------
# Server locations: ${LEX_HOME}/mcp.json — if the file is missing the
# bundled defaults apply (all three work on this machine).
_mcp_config() {
  if [[ -f "${LEX_HOME:-$HOME/.lex}/mcp.json" ]]; then
    cat "${LEX_HOME:-$HOME/.lex}/mcp.json"
  else
    jq -cn --arg h "$HOME" '{
      defuddle: {command: "node", args: ["\($h)/.mcp/node_modules/defuddle-stdio-mcp/index.js"]},
      context7: {command: "\($h)/.local/bin/context7-mcp", args: []},
      playwright: {command: "npx", args: ["-y", "@playwright/mcp@0.0.83", "--cdp-endpoint", "http://127.0.0.1:9222"]},
      desktop: {command: "computer-use-linux", args: ["mcp"]},
      postgres: {command: "\($h)/.lex/pg/dbhub.sh", args: ["--dsn", "postgres://lex@127.0.0.1:5432/lex?sslmode=disable"]}
    }'
  fi
}

# argv (JSON array) for a server name; rc 1 when not configured.
_mcp_argv() {
  _mcp_config | jq -ce --arg n "$1" '.[$n] | select(.command != null) | [.command] + (.args // [])' 2>/dev/null
}

# Last error line of the server (for messages), otherwise empty.
_mcp_errline() {
  local l
  l="$(tail -n 1 "$1" 2>/dev/null)" || l=""
  printf '%s' "$l"
}

# Waits for the response line with id=$1 ($2 = timeout in seconds).
# Prints the line: rc 1 = server gone/no response, rc 2 = timeout.
_mcp_wait() {
  local want="$1" t="$2" i line id rrc
  # the coproc FD can be gone if the server dies immediately (P2).
  [[ -n "${MCPSRV[0]:-}" ]] || return 1
  for (( i = 0; i < 40; i++ )); do
    IFS= read -r -t "$t" line <&"${MCPSRV[0]}" 2>/dev/null
    rrc=$?
    if (( rrc != 0 )); then
      # >128 = timeout (response still on its way?), 1 = EOF/server gone
      (( rrc > 128 )) && return 2
      return 1
    fi
    [[ -z "$line" ]] && continue
    id="$(jq -r '.id // empty' <<< "$line" 2>/dev/null)" || id=""
    [[ "$id" == "$want" ]] && { printf '%s' "$line"; return 0; }
  done
  return 1
}

# Close the session (release FDs and process).
_mcp_close() {
  if [[ -n "${MCPSRV_PID:-}" ]]; then
    kill "$MCPSRV_PID" 2>/dev/null
    wait "$MCPSRV_PID" 2>/dev/null
  fi
  MCPSRV_KEY=""
}

# Write a JSON-RPC line to the MCP server. If the server dies during startup,
# the coproc FD is gone: printf fails with "bad file descriptor" or an
# unset variable — P2 (2026-09-28): this was not detected before.
_mcp_send() {
  local msg="$1"
  [[ -n "${MCPSRV[1]:-}" ]] || return 1
  # check the process before writing — if it dies right after, the
  # group with 2>/dev/null swallows the "bad file descriptor" error.
  if [[ -n "${MCPSRV_PID:-}" ]] && ! kill -0 "$MCPSRV_PID" 2>/dev/null; then
    return 1
  fi
  { printf '%s\n' "$msg" >&"${MCPSRV[1]}"; } 2>/dev/null || return 1
  return 0
}

# A complete call: start → initialize → initialized → request.
# $1 = server, $2 = tool, $3 = arguments (JSON), $4 = mode (call|list).
# list = tools/list discovery (step 23) — $2 is ignored then.
_mcp_call() {
  local server="$1" tool="$2" args="${3:-}" mode="${4:-call}" argv wrc=0
  local label="$tool"
  [[ "$mode" == "list" ]] && label="tools/list"
  [[ -z "$args" ]] && args="{}"
  if [[ "${LEX_MCP:-1}" == "0" ]]; then
    echo "MCP is disabled (LEX_MCP=0)." >&2
    return 1
  fi
  if ! argv="$(_mcp_argv "$server")"; then
    echo "MCP server '$server' is not configured (file: ${LEX_HOME:-$HOME/.lex}/mcp.json)." >&2
    return 1
  fi
  if ! jq -e . >/dev/null 2>&1 <<< "$args"; then
    echo "MCP: arguments are not valid JSON: $args" >&2
    return 1
  fi
  local -a mcp_cmd=()
  local a
  while IFS= read -r a; do mcp_cmd+=("$a"); done < <(jq -r '.[]' <<< "$argv")
  if (( ${#mcp_cmd[@]} == 0 )); then
    echo "MCP: empty configuration for '$server'." >&2
    return 1
  fi
  if [[ "${mcp_cmd[0]}" == */* ]]; then
    if [[ ! -x "${mcp_cmd[0]}" ]]; then
      echo "MCP: start file not executable: ${mcp_cmd[0]}" >&2
      return 1
    fi
  elif ! command -v "${mcp_cmd[0]}" >/dev/null 2>&1; then
    echo "MCP: command not found: ${mcp_cmd[0]}" >&2
    return 1
  fi

  local tout="${LEX_MCP_TIMEOUT:-60}" errfile line resp text rid
  # Own errfile per server (P3, review 2026-09-29): a shared mcp.err
  # overwritten by the next server start — error messages then
  # point into the log of the wrong server.
  errfile="${LEX_HOME:-$HOME/.lex}/mcp.${server//[^[:alnum:]_.-]/_}.err"
  # Session reuse (live finding 2026-09-29): the same server AND
  # same argv configuration + live process → the second call skips
  # initialize and keeps the state (browser tab, desktop session). Earlier
  # every call was ended with _mcp_close → navigate → snapshot landed on
  # about:blank. argv in the key: if the command changes (new mcp.json), it must
  # be restarted even if the name stays the same.
  if [[ -n "${MCPSRV_PID:-}" && "${MCPSRV_KEY:-}" == "$server|$argv" ]] \
      && kill -0 "$MCPSRV_PID" 2>/dev/null; then
    :
  else
    _mcp_close
    coproc MCPSRV { "${mcp_cmd[@]}" 2>"$errfile"; }
    MCPSRV_KEY="$server|$argv"
    MCPSRV_NEXTID=1

    line="$(jq -cn --arg v "${LEX_VERSION:-0}" '{jsonrpc:"2.0",id:1,method:"initialize",params:{protocolVersion:"2024-11-05",capabilities:{},clientInfo:{name:"lex",version:$v}}}')" || {
      _mcp_close; echo "MCP '$server': initialize step failed." >&2; return 1
    }
    if ! _mcp_send "$line"; then
      _mcp_close
      echo "MCP '$server': server cannot be started. $(_mcp_errline "$errfile")" >&2
      return 1
    fi
    wrc=0
    line="$(_mcp_wait 1 "$tout")" || wrc=$?
    if (( wrc != 0 )); then
      if (( wrc == 2 )); then
        echo "MCP '$server': initialize without a response after ${tout}s (timeout)." >&2
      else
        echo "MCP '$server': server cannot be started. $(_mcp_errline "$errfile")" >&2
      fi
      _mcp_close
      return 1
    fi
    if ! _mcp_send '{"jsonrpc":"2.0","method":"notifications/initialized"}'; then
      _mcp_close
      echo "MCP '$server': server cannot be started. $(_mcp_errline "$errfile")" >&2
      return 1
    fi
  fi

  # unique request id across the session — stale responses
  # (e.g. after a timeout) can then no longer be confused
  # with the next request.
  rid=$(( ${MCPSRV_NEXTID:-1} + 1 )); MCPSRV_NEXTID=$rid

  if [[ "$mode" == "list" ]]; then
    line="$(jq -cn --argjson i "$rid" '{jsonrpc:"2.0",id:$i,method:"tools/list",params:{}}')" || {
      _mcp_close; echo "MCP '$server': tools/list step failed." >&2; return 1
    }
  else
    line="$(jq -cn --argjson i "$rid" --arg t "$tool" --argjson a "$args" '{jsonrpc:"2.0",id:$i,method:"tools/call",params:{name:$t,arguments:$a}}')" || {
      _mcp_close; echo "MCP '$server': tools/call step failed." >&2; return 1
    }
  fi
  if ! _mcp_send "$line"; then
    _mcp_close
    echo "MCP '$server': connection to '$label' aborted. $(_mcp_errline "$errfile")" >&2
    return 1
  fi
  resp=""
  wrc=0
  resp="$(_mcp_wait "$rid" "$tout")" || wrc=$?
  if (( wrc != 0 )); then
    if (( wrc == 2 )); then
      echo "MCP '$server': '$label' without a response after ${tout}s (timeout)." >&2
    else
      echo "MCP '$server': connection to '$label' aborted. $(_mcp_errline "$errfile")" >&2
    fi
    _mcp_close
    return 1
  fi
  if jq -e '.error != null' >/dev/null 2>&1 <<< "$resp"; then
    echo "MCP '$server': $(jq -r '.error.message // "unknown error"' <<< "$resp")" >&2
    _mcp_close
    return 1
  fi
  if [[ "$mode" == "list" ]]; then
    text="$(jq -r '[.result.tools[]? | "\(.name) — \(.description // "no description")"] | join("\n")' <<< "$resp" 2>/dev/null)"
    printf '%s\n' "$text"
    return 0
  fi
  text="$(jq -r '[.result.content[]? | select(.type == "text") | .text] | join("\n")' <<< "$resp" 2>/dev/null)"
  local is_err
  is_err="$(jq -r '.result.isError // false' <<< "$resp" 2>/dev/null)"
  if [[ "$is_err" == "true" ]]; then
    printf '%s\n' "${text:-MCP error without text.}" >&2
    return 1
  fi
  printf '%s\n' "$text"
}

# _mcp_out_var <varname> <server> <tool> <args> [mode] — _mcp_call without
# command substitution. A subshell breaks the coproc session: refs and
# tab state only lived per call, navigate → snapshot landed on about:blank
# or "ref not found" (live findings 2026-09-29). With temp file redirection
# _mcp_call runs in the main shell; stderr passes straight through as before.
_mcp_out_var() {
  local _v="$1" _tf _rc=0
  shift
  _tf="$(mktemp)" || return 1
  _mcp_call "$@" >"$_tf" || _rc=$?
  if (( _rc == 0 )); then
    printf -v "$_v" '%s' "$(cat "$_tf")"
  else
    printf -v "$_v" '%s' ""
  fi
  rm -f "$_tf"
  return "$_rc"
}

# web_fetch — fetch a known page as plain text via a crawler (MCP defuddle).
# Not a persistence replacement for fetch(url, topic), just the fast read path.
tool_web_fetch() {
  local url="$1" max="${2:-8000}" out rc=0
  if [[ -z "$url" ]]; then
    echo "web_fetch: url is missing." >&2
    return 1
  fi
  [[ "$max" =~ ^[0-9]+$ ]] || max=8000
  (( max > 50000 )) && max=50000
  # _mcp_out_var instead of $(…): subshells break the coproc session and the
  # NEXTID counter (P2, review 2026-09-29).
  _mcp_out_var out defuddle fetch "$(jq -cn --arg u "$url" --argjson m "$max" '{url:$u,max_length:$m}')" || rc=$?
  if (( rc != 0 )); then
    echo "web_fetch not possible — use fetch(url, topic) (curl with saving) or bash instead." >&2
    return "$rc"
  fi
  printf '%s\n' "$out"
}

# context7 — resolve a library, pull a doc excerpt (counterweight to model knowledge).
tool_context7() {
  local query="$1" library="${2:-}" qargs resolve libid docs
  if [[ -z "$query" && -z "$library" ]]; then
    echo "context7: query is missing (e.g. curl options)." >&2
    return 1
  fi
  [[ -z "$query" ]] && query="$library"
  qargs="$(jq -cn --arg l "${library:-$query}" --arg q "$query" '{libraryName:$l,query:$q}')"
  # _mcp_out_var instead of $(…) — subshells break coproc session/NEXTID (P2).
  _mcp_out_var resolve context7 resolve-library-id "$qargs" || return $?
  libid="$(printf '%s\n' "$resolve" | sed -n 's/.*Context7-compatible library ID: *//p' | head -n 1)"
  if [[ -z "$libid" ]]; then
    printf '%s\n' "$resolve"
    printf '\nNo library found — sharpen the search term or set library=.\n'
    return 0
  fi
  _mcp_out_var docs context7 query-docs "$(jq -cn --arg i "$libid" --arg q "$query" '{libraryId:$i,query:$q}')" || return $?
  printf 'Library (context7): %s\n\n%s\n' "$libid" "$docs"
}

# Browser control (step 22): Microsoft Playwright-MCP against system Chrome.
# Workflow for the model: navigate → snapshot (ARIA refs) → click/type by ref.
# No write gate (user: full trust). Output cap like tool_read_file —
# Snapshots of large pages would otherwise flood the context.
#
# Chrome as a CDP service (127.0.0.1:9222): dispatch runs in a command
# substitution, the MCP session dies per call — without an external browser
# snapshot after navigate ended up on about:blank (live finding 2026-09-29).
# The service survives every call; configuration without --cdp-endpoint
# (own browser per server start) ignores this function.
_ensure_browser() {
  local pf="${LEX_HOME:-$HOME/.lex}/browser.pid" i pid=""
  if command -v ss >/dev/null 2>&1 && ss -H -ltn 2>/dev/null | grep -q ':9222 '; then
    return 0
  fi
  # pid check (P3, review 2026-09-29): throw away a dead pid file; wait for a live
  # Chrome without an open port instead of blindly starting a second one
  # (same profile → "Profile in use", the restart dies immediately).
  if [[ -f "$pf" ]]; then
    read -r pid < "$pf" 2>/dev/null || pid=""
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
      if command -v curl >/dev/null 2>&1; then
        for (( i = 0; i < 20; i++ )); do
          curl -s -m 1 http://127.0.0.1:9222/json/version >/dev/null 2>&1 && return 0
          sleep 0.3
        done
      fi
      echo "browser: Chrome (pid $pid) is running but not answering on :9222." >&2
      return 1
    fi
    rm -f "$pf"
  fi
  command -v google-chrome >/dev/null 2>&1 || {
    echo "browser: google-chrome is missing." >&2; return 1; }
  mkdir -p "${LEX_HOME:-$HOME/.lex}/chrome-profile"
  nohup google-chrome \
    --remote-debugging-port=9222 \
    --user-data-dir="${LEX_HOME:-$HOME/.lex}/chrome-profile" \
    --no-first-run --no-default-browser-check >/dev/null 2>&1 &
  echo $! > "$pf"
  for (( i = 0; i < 40; i++ )); do
    if command -v curl >/dev/null 2>&1; then
      curl -s -m 1 http://127.0.0.1:9222/json/version >/dev/null 2>&1 && return 0
    elif command -v ss >/dev/null 2>&1 && ss -H -ltn 2>/dev/null | grep -q ':9222 '; then
      return 0
    fi
    sleep 0.2
  done
  echo "browser: CDP port 9222 did not come up (Chrome failed to start)." >&2
  return 1
}
tool_browser() {
  local action="${1:-}" url="${2:-}" ref="${3:-}" element="${4:-}" text="${5:-}" key="${6:-}" index="${7:-}"
  local mtool args out len max_len="${_tool_max_output:-50000}"
  case "$action" in
    navigate)
      mtool="browser_navigate"
      if [[ -z "$url" ]]; then
        echo "browser: url is missing (action=navigate)." >&2
        return 1
      fi
      args="$(jq -cn --arg u "$url" '{url:$u}')" || return 1
      ;;
    snapshot)
      mtool="browser_snapshot"; args='{}'
      ;;
    click)
      mtool="browser_click"
      if [[ -z "$ref" ]]; then
        echo "browser: ref missing — take a snapshot first, then use a ref from it." >&2
        return 1
      fi
      # target = ref-ID (Schema 0.0.83+, "reference or unique selector"),
      # ref/element both stay: older versions only know element+ref,
      # the test stub reads .element/.ref.
      args="$(jq -cn --arg r "$ref" --arg e "${element:-Element}" '{target:$r,ref:$r,element:$e}')" || return 1
      ;;
    type)
      mtool="browser_type"
      if [[ -z "$ref" || -z "$text" ]]; then
        echo "browser: ref and text are missing (action=type)." >&2
        return 1
      fi
      args="$(jq -cn --arg r "$ref" --arg t "$text" --arg e "${element:-input field}" '{target:$r,ref:$r,element:$e,text:$t}')" || return 1
      ;;
    press)
      mtool="browser_press_key"
      if [[ -z "$key" ]]; then
        echo "browser: key missing (e.g. Enter, Tab, Escape)." >&2
        return 1
      fi
      args="$(jq -cn --arg k "$key" '{key:$k}')" || return 1
      ;;
    wait)
      # pages load asynchronously (back/click/Enter): refs go stale until the
      # page settles. action=wait keeps playwright's browser_wait_for available.
      mtool="browser_wait_for"
      if [[ -n "$text" && ! "$text" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        echo "browser: text must be seconds (action=wait, e.g. 1)." >&2
        return 1
      fi
      args="$(jq -cn --argjson t "${text:-1}" '{time:$t}')" || return 1
      ;;
    back)
      mtool="browser_navigate_back"; args='{}'
      ;;
    tabs)
      mtool="browser_tabs"
      if [[ -n "$index" ]]; then
        [[ "$index" =~ ^[0-9]+$ ]] || { echo "browser: index must be a number." >&2; return 1; }
        args="$(jq -cn --argjson i "$index" '{action:"select",index:$i}')" || return 1
      else
        args='{"action":"list"}'
      fi
      ;;
    close)
      mtool="browser_close"; args='{}'
      ;;
    *)
      echo "browser: action missing or unknown: '${action}' — navigate|snapshot|click|type|press|back|tabs|close|wait" >&2
      return 1
      ;;
  esac
  # CDP config → make sure the service exists (otherwise playwright uses its own browser).
  if _mcp_argv playwright 2>/dev/null | grep -q 'cdp-endpoint'; then
    _ensure_browser || return $?
  fi
  _mcp_out_var out playwright "$mtool" "$args" || return $?
  len=${#out}
  if (( len > max_len )); then
    out="${out:0:max_len}"$'\n... (truncated, '"${len}"' bytes total)'
  fi
  printf '%s\n' "$out"
}

# Generic MCP access (step 23): any configured server,
# discovery first (tool empty or __tools → tools/list), then tools/call.
# Turns every new mcp.json entry into a model tool — no code per server.
tool_mcp() {
  local server="${1:-}" tool="${2:-}" args="${3:-}" out names len max_len="${_tool_max_output:-50000}"
  if [[ -z "$server" ]]; then
    names="$(_mcp_config | jq -r 'keys | join(", ")' 2>/dev/null)" || names=""
    echo "mcp: server missing. Configured servers: ${names:-unknown} — or add one to ${LEX_HOME:-$HOME/.lex}/mcp.json." >&2
    return 1
  fi
  if [[ -z "$tool" || "$tool" == "__tools" ]]; then
    _mcp_out_var out "$server" "" "{}" list || return $?
    if [[ -z "$out" ]]; then
      echo "mcp: server '$server' reports no tools." >&2
      return 1
    fi
    printf 'Tools from %s (name — description):\n%s\n' "$server" "$out"
    return 0
  fi
  [[ -z "$args" ]] && args="{}"
  _mcp_out_var out "$server" "$tool" "$args" || return $?
  len=${#out}
  if (( len > max_len )); then
    out="${out:0:max_len}"$'\n... (truncated, '"${len}"' bytes total)'
  fi
  printf '%s\n' "$out"
}

# format the DuckDuckGo result list (title, URL, snippet, max. 10).
_ddg_parse() {
  local q="$1"
  LC_ALL=C awk -v q="$q" '
    BEGIN {
      for (i = 32; i < 256; i++) DEC[sprintf("%%%02X", i)] = sprintf("%c", i)
    }
    function ent(s) {
      gsub(/&amp;/, "\\&", s); gsub(/&lt;/, "<", s); gsub(/&gt;/, ">", s)
      gsub(/&quot;/, "\"", s); gsub(/&#39;|&#x27;/, "\x27", s); gsub(/&nbsp;/, " ", s)
      gsub(/&uuml;/, "\303\274", s); gsub(/&ouml;/, "\303\266", s); gsub(/&auml;/, "\303\244", s)
      gsub(/&Uuml;/, "\303\234", s); gsub(/&Ouml;/, "\303\226", s); gsub(/&Auml;/, "\303\204", s)
      gsub(/&szlig;/, "\303\237", s); gsub(/&ndash;/, "\342\200\223", s); gsub(/&mdash;/, "\342\200\224", s)
      gsub(/&hellip;/, "\342\200\246", s)
      return s
    }
    function decode(u,   rep) {
      while (match(u, /%[0-9A-Fa-f][0-9A-Fa-f]/)) {
        rep = toupper(substr(u, RSTART, RLENGTH))
        u = substr(u, 1, RSTART - 1) DEC[rep] substr(u, RSTART + RLENGTH)
      }
      return u
    }
    { html = html " " $0 }
    END {
      n = split(html, parts, /class="result__a"/)
      if (n < 2) {
        print "No matches for \"" q "\" — try different wording or web_fetch for known URLs."
        exit
      }
      cnt = 0
      for (i = 2; i <= n && cnt < 10; i++) {
        chunk = parts[i]
        url = ""
        if (match(chunk, /href="[^"]*"/)) url = substr(chunk, RSTART + 6, RLENGTH - 7)
        title = ""
        rest = chunk
        if (match(rest, /^[^>]*>/)) {
          rest = substr(rest, RSTART + RLENGTH)
          if (match(rest, /<\/a>/)) { title = substr(rest, 1, RSTART - 1); rest = substr(rest, RSTART + 4) }
        }
        snippet = ""
        if (match(rest, /class="result__snippet"/)) {
          c2 = substr(rest, RSTART + RLENGTH)
          if (match(c2, /^[^>]*>/)) {
            c3 = substr(c2, RSTART + RLENGTH)
            if (match(c3, /<\/a>/)) snippet = substr(c3, 1, RSTART - 1)
          }
        }
        url = ent(url)
        if (match(url, /uddg=[^&]*/)) url = substr(url, RSTART + 5, RLENGTH - 5)
        url = decode(url)
        if (url ~ /^\/\//) url = "https:" url
        title = ent(title); gsub(/<[^>]*>/, "", title)
        snippet = ent(snippet); gsub(/<[^>]*>/, "", snippet)
        if (title == "" && url == "") continue
        cnt++
        printf "%d) %s\n   %s\n", cnt, (title == "") ? url : title, url
        if (snippet != "") printf "   %s\n", snippet
      }
      if (cnt == 0) print "No matches for \"" q "\" — try different wording or use web_fetch."
    }
  '
}

# web_search — web search without an API key (DuckDuckGo html).
tool_web_search() {
  local query="$1" endpoint html rc=0 err errfile="${LEX_HOME:-$HOME/.lex}/web_search.err"
  if [[ -z "$query" ]]; then
    echo "web_search: query is missing." >&2
    return 1
  fi
  endpoint="${LEX_SEARCH_URL:-https://html.duckduckgo.com/html/}"
  html="$(curl -sf --max-time "${LEX_SEARCH_TIMEOUT:-20}" \
    -A 'Mozilla/5.0 (X11; Linux x86_64; rv:128.0) lex/0.1' \
    --get --data-urlencode "q=$query" "$endpoint" 2>"$errfile")" || rc=$?
  if (( rc != 0 )); then
    err="$(_mcp_errline "$errfile")"
    echo "web_search not possible (rc=$rc, $endpoint)${err:+ — $err}. Use web_fetch for known URLs." >&2
    return "$rc"
  fi
  _ddg_parse "$query" <<< "$html"
}

tool_mem_add() {
  local type="$1" content="$2"
  if ! _mem_valid_type "$type"; then
    echo "Error: unknown type '$type' (memory|fact|preference|note)."
    return 1
  fi
  if [[ -z "${content//[$' \t\n']/}" ]]; then
    echo "Error: empty content."
    return 1
  fi
  mkdir -p "$_mem_dir" 2>/dev/null || { echo "Error: cannot create '$_mem_dir'."; return 1; }
  local first slug iso file n
  first="${content%%$'\n'*}"
  slug="$(_mem_slug "$first")"
  [[ -n "$slug" ]] || slug="entry"
  iso="$(date +%Y-%m-%dT%H:%M:%S%z)"
  file="${_mem_dir}/$(date +%Y%m%d%H%M%S)-${slug}.md"
  # collision within the same second (P2, review 2026-09-29): otherwise the second
  # entry overwrites the first.
  n=2
  while [[ -e "$file" ]]; do
    file="${_mem_dir}/$(date +%Y%m%d%H%M%S)-${slug}-${n}.md"
    n=$((n + 1))
  done
  {
    printf -- '---\ndate: %s\ntype: %s\nslug: %s\n---\n\n%s\n' "$iso" "$type" "$slug" "$content"
  } > "$file" 2>/dev/null || { echo "Error: '$file' is not writable."; return 1; }
  echo "Memory saved: $file"
}

tool_mem_list() {
  local type="${1:-}" f t title found=0
  if [[ ! -d "$_mem_dir" ]]; then
    echo "No memories yet ('$_mem_dir' does not exist)."
    return 0
  fi
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    t="$(grep -m1 '^type: ' "$f" 2>/dev/null | cut -d' ' -f2)"
    if [[ -n "$type" && "$t" != "$type" ]]; then
      continue
    fi
    title="$(awk 'NR>1 && !/^---$/ && !/^(date|type|slug):/ && NF { print; exit }' "$f" 2>/dev/null)"
    printf '%s | %s | %s\n' "$(basename "$f")" "$t" "$title"
    found=$((found + 1))
  done < <(find "$_mem_dir" -maxdepth 1 -name '*.md' -type f 2>/dev/null | sort)
  if (( found == 0 )); then
    echo "No entries${type:+ of type '$type'}."
  fi
  return 0
}

tool_mem_search() {
  local query="$1"
  if [[ -z "${query//[$' \t\n']/}" ]]; then
    echo "Error: search term missing."
    return 1
  fi
  if [[ ! -d "$_mem_dir" ]]; then
    echo "No matches for '$query'."
    return 0
  fi
  local out
  out="$(grep -rinF --include='*.md' -- "$query" "$_mem_dir" 2>/dev/null)"
  if [[ -z "$out" ]]; then
    echo "No matches for '$query'."
    return 0
  fi
  printf '%s\n' "$out"
}

dispatch_tool() {
  local name="$1" args="$2"
  local path content old new command all mtype query pattern recursive glob regex
  local todo_action text todo_index url topic title web_max ctx_lib
  local b_action b_ref b_element b_key b_index
  local m_server m_tool m_args
  # Arguments must be JSON objects — otherwise the jq error message
  # lands in the context as a tool result (P3, 2026-09-28).
  [[ -z "${args:-}" ]] && args="{}"
  if ! jq -e 'type == "object"' >/dev/null 2>&1 <<< "$args"; then
    echo "Error: tool arguments are not a JSON object: $(printf '%.120s' "$args")"
    return 1
  fi
  case "$name" in
    read_file)
      path="$(jq -r '.path // empty' <<< "$args")"
      tool_read_file "$path"
      ;;
    write_file)
      path="$(jq -r '.path // empty' <<< "$args")"
      content="$(jq -r '.content // empty' <<< "$args")"
      tool_write_file "$path" "$content"
      ;;
    edit_file)
      path="$(jq -r '.path // empty' <<< "$args")"
      old="$(jq -r '.old // empty' <<< "$args")"
      new="$(jq -r '.new // empty' <<< "$args")"
      all="$(jq -r '.all // false' <<< "$args")"
      tool_edit_file "$path" "$old" "$new" "$all"
      ;;
    bash)
      command="$(jq -r '.command // empty' <<< "$args")"
      tool_bash "$command"
      ;;
    list_files)
      path="$(jq -r '.path // empty' <<< "$args")"
      pattern="$(jq -r '.pattern // empty' <<< "$args")"
      recursive="$(jq -r '.recursive // false' <<< "$args")"
      tool_list_files "$path" "$pattern" "$recursive"
      ;;
    append_file)
      path="$(jq -r '.path // empty' <<< "$args")"
      content="$(jq -r '.content // empty' <<< "$args")"
      tool_append_file "$path" "$content"
      ;;
    search)
      query="$(jq -r '.query // empty' <<< "$args")"
      path="$(jq -r '.path // empty' <<< "$args")"
      glob="$(jq -r '.glob // empty' <<< "$args")"
      regex="$(jq -r '.regex // false' <<< "$args")"
      tool_search "$query" "$path" "$glob" "$regex"
      ;;
    fetch)
      url="$(jq -r '.url // empty' <<< "$args")"
      topic="$(jq -r '.topic // empty' <<< "$args")"
      title="$(jq -r '.title // empty' <<< "$args")"
      tool_fetch "$url" "$topic" "$title"
      ;;
    todo)
      todo_action="$(jq -r '.action // empty' <<< "$args")"
      text="$(jq -r '.text // empty' <<< "$args")"
      todo_index="$(jq -r '.index // empty' <<< "$args")"
      tool_todo "$todo_action" "$text" "$todo_index"
      ;;
    mem_add)
      mtype="$(jq -r '.type // empty' <<< "$args")"
      content="$(jq -r '.content // empty' <<< "$args")"
      tool_mem_add "$mtype" "$content"
      ;;
    mem_list)
      mtype="$(jq -r '.type // empty' <<< "$args")"
      tool_mem_list "$mtype"
      ;;
    mem_search)
      query="$(jq -r '.query // empty' <<< "$args")"
      tool_mem_search "$query"
      ;;
    web_search)
      query="$(jq -r '.query // empty' <<< "$args")"
      tool_web_search "$query"
      ;;
    web_fetch)
      url="$(jq -r '.url // empty' <<< "$args")"
      web_max="$(jq -r '.max_length // empty' <<< "$args")"
      tool_web_fetch "$url" "$web_max"
      ;;
    context7)
      query="$(jq -r '.query // empty' <<< "$args")"
      ctx_lib="$(jq -r '.library // empty' <<< "$args")"
      tool_context7 "$query" "$ctx_lib"
      ;;
    browser)
      b_action="$(jq -r '.action // empty' <<< "$args")"
      url="$(jq -r '.url // empty' <<< "$args")"
      b_ref="$(jq -r '.ref // empty' <<< "$args")"
      b_element="$(jq -r '.element // empty' <<< "$args")"
      text="$(jq -r '.text // empty' <<< "$args")"
      b_key="$(jq -r '.key // empty' <<< "$args")"
      b_index="$(jq -r '.index // empty' <<< "$args")"
      tool_browser "$b_action" "$url" "$b_ref" "$b_element" "$text" "$b_key" "$b_index"
      ;;
    mcp)
      m_server="$(jq -r '.server // empty' <<< "$args")"
      m_tool="$(jq -r '.tool // empty' <<< "$args")"
      # arguments tolerant: JSON object (schema) or JSON string (model fallback)
      m_args="$(jq -c 'if (.arguments | type) == "string" then ((.arguments | fromjson?) // {}) else (.arguments // {}) end' <<< "$args")" || m_args='{}'
      tool_mcp "$m_server" "$m_tool" "$m_args"
      ;;
    *)
      echo "Unknown tool: $name"
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Rendering (step 3, 2026-09-28): tool trace, HUD, markdown light
# ---------------------------------------------------------------------------
_now() { printf '%s' "${EPOCHREALTIME:-$(date +%s)}"; }

# The trace only runs in a terminal (stderr as a TTY) — otherwise it disturts tests and pipes.
# LEX_TRACE=1 forces it (useful for recordings/debugging).
# ---------------------------------------------------------------------------
# Colour palette (step 14, 2026-09-28). All sequences go through variables,
# so NO_COLOR/TERM=dumb stay compliant (they stay empty then). Additionally
# fragile codes were replaced: italic (3) and "white" (37) are barely or not
# readable on light and grey terminals.
# ---------------------------------------------------------------------------
_K_RST=""
_K_DIM=""
_K_MAG=""
_K_GRAY=""
_K_CYANB=""
_K_CYAND=""
_K_BLUEB=""
_K_BOLD=""

_palette_init() {
  [[ -n "${NO_COLOR:-}" || "${TERM:-}" == "dumb" ]] && return 0
  _K_RST=$'\033[0m'
  _K_DIM=$'\033[2m'       # HUD, rule, tool arguments
  _K_MAG=$'\033[2;35m'    # thinking: header
  _K_GRAY=$'\033[90m'     # thinking: content (bright black, available everywhere)
  _K_CYANB=$'\033[1;36m'  # tool: name, table header
  _K_CYAND=$'\033[2;36m'  # result: marker
  _K_BLUEB=$'\033[1;34m'  # prompt
  _K_BOLD=$'\033[1m'
  return 0
}
_palette_init

# Prompt: coloured only when stdout is a terminal — otherwise the
# escape sequences into pipes/logs (P3) — and never with NO_COLOR.
_prompt() {
  if [[ -t 1 ]]; then
    printf '%slex>%s ' "$_K_BLUEB" "$_K_RST"
  else
    printf 'lex> '
  fi
}

_trace_enabled() {
  [[ -n "${LEX_TRACE:-}" ]] && return 0
  [[ -t 2 ]]
}

# Compact argument hint: first sensible value, single line, 70 characters.
_hint_args() {
  local args="$1" v
  v="$(jq -r '[.path // "", .query // "", .command // "", .action // "", .text // "", .url // "", .old // ""] | map(select(length > 0)) | .[0] // ""' <<< "$args" 2>/dev/null)"
  v="${v//$'\n'/ }"
  printf '%.70s' "$v"
}

# Live feedback (steps A/B, 2026-09-28): spinner, tool result,
# reasoning block, separator — all on stderr and only on TTY/LEX_TRACE,
# so pipes and tests stay unchanged.
_spin_pid=""
_spin_flag=""

_spin_start() {
  _trace_enabled || return 0
  # Only repaint on a real TTY (P3, live test 2026-09-29): the \r-\x1b[2K-
  # sequences would otherwise flood pipes and log files.
  [[ -t 2 ]] || return 0
  _spin_flag="$(mktemp)" 2>/dev/null || return 0
  # wait 250 ms first: with fast answers (mock, small prompts)
  # it stays calm instead of flickering.
  (
    sleep 0.25
    printf 'x' > "$_spin_flag" 2>/dev/null
    while :; do
      printf '\r\033[2K%s⏳ thinking …%s' "$_K_DIM" "$_K_RST" >&2
      sleep 0.12
    done
  ) &
  _spin_pid=$!
  # the spinner must not stay behind in the terminal on exit/SIGINT (P3).
  trap '_spin_stop' EXIT
}

_spin_stop() {
  if [[ -n "${_spin_pid:-}" ]]; then
    kill "$_spin_pid" 2>/dev/null
    wait "$_spin_pid" 2>/dev/null
    _spin_pid=""
  fi
  # only clear if the spinner actually printed — otherwise an invisible
  # blank sequence would remain in the terminal for fast answers.
  if [[ -n "${_spin_flag:-}" ]]; then
    # -s = spinner really drew (flag file not empty)
    if [[ -s "$_spin_flag" ]]; then
      printf '\r\033[2K' >&2
    fi
    rm -f "$_spin_flag"
  fi
  _spin_flag=""
}

# Show the tool result to the human (otherwise only the ⚙ line is visible).
_trace_result() {
  _trace_enabled || return 0
  local name="${1:-}" res="${2:-}"
  local max_lines=8 max_chars=600 n=0 line out="" total
  [[ -z "${res//[$' \t\n']/}" ]] && return 0
  total="$(printf '%s' "$res" | wc -l | tr -d ' ')"
  while IFS= read -r line; do
    n=$((n + 1))
    (( n > max_lines )) && break
    out+="${line}"$'\n'
    if (( ${#out} > max_chars )); then break; fi
  done <<< "$res"
  printf '%s↳ %s%s\n' "$_K_CYAND" "$name" "$_K_RST" >&2
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    printf '%s    %s%s\n' "$_K_DIM" "$line" "$_K_RST" >&2
  done <<< "$out"
  if (( total > max_lines )); then
    printf '%s    … (%s lines total)%s\n' "$_K_DIM" "$total" "$_K_RST" >&2
  fi
}

# What the model thought (reasoning_content) — display for the human,
# the model's context stays unchanged (LEX.md §4 context protection).
_trace_reasoning() {
  _trace_enabled || return 0
  [[ "${LEX_SHOW_REASONING:-1}" == "0" ]] && return 0
  local r="${1:-}" max line
  max="$(_int_or "${LEX_REASONING_MAX:-4000}" 4000)"
  (( max >= 1 )) || max=4000
  [[ -z "${r//[$' \t\n']/}" ]] && return 0
  if (( ${#r} > max )); then
    r="${r:0:max}"$'\n… (truncated — raise LEX_REASONING_MAX, set LEX_SHOW_REASONING=0 to switch off)'
  fi
  # step 13: thinking is OBSERVATION, not an answer — hence set apart:
  # dim magenta header, grey content + 2-space indent (step 14:
  # instead of italic, because italic is not supported everywhere).
  printf '%s⚙ thinking:%s\n' "$_K_MAG" "$_K_RST" >&2
  while IFS= read -r line; do
    printf '%s  %s%s\n' "$_K_GRAY" "$line" "$_K_RST" >&2
  done <<< "$r"
}

# Separator between the answers.
_trace_rule() {
  _trace_enabled || return 0
  printf '%s%s%s\n' "$_K_DIM" '──────────────────────────────────────' "$_K_RST" >&2
}

_trace_line() {
  _trace_enabled || return 0
  printf '%s⚙ %-14s%s%s %s%s\n' \
    "$_K_CYANB" "$1" "$_K_RST" "$_K_DIM" "${2:-}" "$_K_RST" >&2
}

_trace_hud() {
  local t0="$1" t1 dt
  _trace_enabled || return 0
  t1="$(_now)"
  dt="$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.1f", b-a}' 2>/dev/null)"
  [[ -z "$dt" ]] && dt="?"
  printf '%s⏱ %ss · turn %s/%s · tokens %s prompt + %s completion%s\n' \
    "$_K_DIM" "$dt" "${_turn_count:-0}" "${_max_turns:-?}" \
    "${_last_prompt_tokens:-?}" "${_last_completion_tokens:-?}" "$_K_RST" >&2
}

# Markdown light: colours for headings, **bold**, `code`, [[wikilinks]], links,
# quotes, warnings/errors/success, list markers — and cleanly aligned
# pipe tables (opencode style: header cyan/bold, grid dim, numbers right-aligned).
# Colour only with TTY (or force), otherwise pass through raw.
_md_render() {
  local force="$1"
  # NO_COLOR/TERM=dumb also wins over force (standard convention).
  if [[ -n "${NO_COLOR:-}" || "${TERM:-}" == "dumb" || ( "$force" != "force" && ! -t 1 ) ]]; then
    cat
    return 0
  fi
  LC_ALL=C awk '
    BEGIN {
      code = 0
      ESC = sprintf("%c", 27)
      ESCCH = ESC
      MAXW = 40
      for (i = 1; i < 256; i++) ORD[sprintf("%c", i)] = i
    }
    function c(s) { return ESC "[" s "m" }
    function do_code(s,   out) {
      out = ""
      while (match(s, /`[^`]+`/)) {
        out = out substr(s, 1, RSTART - 1) c("32") substr(s, RSTART + 1, RLENGTH - 2) c("0")
        s = substr(s, RSTART + RLENGTH)
      }
      return out s
    }
    function do_bold(s,   out) {
      out = ""
      while (match(s, /\*\*[^*]+\*\*/)) {
        out = out substr(s, 1, RSTART - 1) c("1") substr(s, RSTART + 2, RLENGTH - 4) c("0")
        s = substr(s, RSTART + RLENGTH)
      }
      return out s
    }
    function do_wiki(s,   out) {
      out = ""
      while (match(s, /\[\[[^]]+\]\]/)) {
        out = out substr(s, 1, RSTART - 1) c("35") substr(s, RSTART, RLENGTH) c("0")
        s = substr(s, RSTART + RLENGTH)
      }
      return out s
    }
    function do_link(s,   out, full, txt, url, cut) {
      out = ""
      while (match(s, /\[[^]]+\]\([^)]+\)/)) {
        full = substr(s, RSTART, RLENGTH)
        cut  = index(full, "](")
        txt  = substr(full, 2, cut - 2)
        url  = substr(full, cut + 2, RLENGTH - cut - 2)
        out = out substr(s, 1, RSTART - 1) c("4;36") txt c("0") c("2") " (" url ")" c("0")
        s = substr(s, RSTART + RLENGTH)
      }
      return out s
    }
    function inline(s) { return do_link(do_wiki(do_bold(do_code(s)))) }

    # visible length (ignore ANSI sequences and UTF-8 continuation bytes).
    function vlen(s,   t, i, n, code) {
      t = s
      gsub(/\033\[[0-9;]*m/, "", t)
      n = 0
      for (i = 1; i <= length(t); i++) {
        code = ORD[substr(t, i, 1)]
        if (code >= 128 && code < 192) continue
        n++
      }
      return n
    }
    # truncate to n visible characters without breaking a running colour sequence.
    function cutv(s, n,   out, i, len, ch, code, cnt, rest, j) {
      out = ""; cnt = 0; i = 1; len = length(s)
      while (i <= len) {
        ch = substr(s, i, 1)
        if (ch == ESCCH) {
          rest = substr(s, i)
          j = index(rest, "m")
          if (j == 0) { out = out rest; return out }
          out = out substr(rest, 1, j); i += j; continue
        }
        code = ORD[ch]
        if (code >= 128 && code < 192) { out = out ch; i++; continue }
        if (cnt >= n) { out = out "…"; return out }
        out = out ch; cnt++; i++
      }
      return out
    }
    function rep(str, n,   out) { out = ""; while (n-- > 0) out = out str; return out }
    function pad(s, w,   d) { d = w - vlen(s); return (d <= 0) ? s : s sprintf("%*s", d, "") }
    function rjust(s, w,   d) { d = w - vlen(s); return (d <= 0) ? s : sprintf("%*s", d, "") s }

    # line -> cells (drop leading/trailing pipe, trim cells).
    function cells(row, a,   r, n, i) {
      r = row
      sub(/^[ \t]*\|/, "", r)
      sub(/[ \t]*\|[ \t]*$/, "", r)
      n = split(r, a, /\|/)
      for (i = 1; i <= n; i++) { sub(/^[ \t]+/, "", a[i]); sub(/[ \t]+$/, "", a[i]) }
      return n
    }
    function istable(l)  { return (l ~ /^[ \t]*\|/ && l ~ /\|[ \t]*$/) }
    function issep(l,   r, a, n, i) {
      r = l
      sub(/^[ \t]*\|/, "", r); sub(/[ \t]*\|[ \t]*$/, "", r)
      if (r == "") return 0
      n = split(r, a, /\|/)
      for (i = 1; i <= n; i++) if (a[i] !~ /^[ \t]*:?-+:?[ \t]*$/) return 0
      return 1
    }

    # print table f..t: header cyan/bold, grid line dim, right-aligned at :---
    function render_table(f, t,   k, row, i, m, hdr, cell, vis, out) {
      for (i = 1; i <= 40; i++) { TW[i] = 0; AL[i] = "l" }
      nmax = 0
      for (k = f; k <= t; k++) {
        row = lines[k]
        if (issep(row)) {
          m = cells(row, ca)
          for (i = 1; i <= m; i++) if (ca[i] ~ /:$/) AL[i] = "r"
          continue
        }
        m = cells(row, ca)
        for (i = 1; i <= m; i++) {
          cell = inline(ca[i])
          if (vlen(cell) > MAXW) cell = cutv(cell, MAXW)
          vis = vlen(cell)
          if (vis > TW[i]) TW[i] = vis
          if (i > nmax) nmax = i
        }
      }
      for (k = f; k <= t; k++) {
        row = lines[k]
        if (issep(row)) {
          out = "│"
          for (i = 1; i <= nmax; i++) {
            out = out c("2") rep("─", TW[i]) c("0")
            if (i < nmax) out = out c("2") "┼" c("0")
          }
          print out c("2") "│" c("0")
          continue
        }
        m = cells(row, ca)
        hdr = (k == f)
        out = ""
        for (i = 1; i <= nmax; i++) {
          cell = (i <= m) ? inline(ca[i]) : ""
          if (vlen(cell) > MAXW) cell = cutv(cell, MAXW)
          cell = (AL[i] == "r") ? rjust(cell, TW[i]) : pad(cell, TW[i])
          out = out "│" (hdr ? c("1;36") : "") cell (hdr ? c("0") : "")
        }
        print out "│"
      }
    }

    function pline(l,   line, pre, mark, rest) {
      line = inline(l)
      # H1: bold UNDERLINED instead of "white" — white (37) is invisible on
      # light terminals, style codes are background independent (step 14).
      if (l ~ /^# /)   return c("1;4") line c("0")
      if (l ~ /^## /)  return c("1;36") line c("0")
      if (l ~ /^#/)    return c("36") line c("0")
      if (l ~ /^> /) {
        if (l ~ /^> *(\*\*)?(Warning|WARNING|IMPORTANT|NOTE|HINT|CAUTION)/)
          return c("33") line c("0")
        return c("2") line c("0")
      }
      if (l ~ /^(❌|✗|ERROR) / || l ~ /^(Error|ERROR)[: ]/) return c("31") line c("0")
      if (l ~ /^(✅|✓|OK) /)                                 return c("32") line c("0")
      if (l ~ /^(---+|===+|___+)[ \t]*$/)                    return c("2") line c("0")
      if (match(l, /^[ \t]*([-*+]|[0-9]+\.) /)) {
        pre  = substr(l, 1, RSTART - 1)
        mark = substr(l, RSTART, RLENGTH)
        rest = substr(l, RSTART + RLENGTH)
        return pre c("2") mark c("0") inline(rest)
      }
      return line
    }

    { lines[NR] = $0 }
    END {
      for (i = 1; i <= NR; i++) {
        l = lines[i]
        if (l ~ /^[ \t]*```/) { code = 1 - code; print c("2") inline(l) c("0"); continue }
        if (code) { print l; continue }
        if (istable(l) && i < NR && issep(lines[i + 1])) {
          j = i + 1
          while (j <= NR && istable(lines[j])) j++
          render_table(i, j - 1)
          i = j - 1
          continue
        }
        print pline(l)
      }
    }
  '
}

# Public names: without force = TTY-controlled, with force = force colours.
render_markdown()      { _md_render ""; }
render_markdown_force() { _md_render "force"; }

# ---------------------------------------------------------------------------
# Agent-Loop
# ---------------------------------------------------------------------------
run_turn() {
  local input="$1" turn_t0 nudge_count=0 pending="" _dtf="" rlen
  turn_t0="$(_now)"
  append_message "user" "$input"
  log "turn: ${#input} chars"
  local turns=0
  while :; do
    turns=$((turns + 1))
    if (( turns > _max_turns )); then
      # rescue logic here too (live re-test 2026-09-29: 578 bytes fell
      # under the abort): the loop ends, but the last non-rendered
      # answer is not lost.
      if [[ -n "${pending:-}" ]]; then
        echo "⚠️  Max turns reached ($_max_turns) — showing the answer so far." >&2
        _trace_hud "$turn_t0"
        _trace_rule
        render_markdown <<< "$pending"
        return 0
      fi
      echo "⚠️  Max turns reached ($_max_turns). Aborting." >&2
      return 1
    fi
    local response content reasoning tool_calls_json tool_count
    _spin_start
    response="$(call_api)" && _api_rc=0 || _api_rc=$?
    # single-use nudge override: call_api runs in a
    # subshell (the assignment there is lost), hence clear it here in the
    # parent shell — otherwise the session kept running with
    # reasoning_budget=0 (review finding 2026-09-29).
    _rb_override=""
    _spin_stop
    if (( _api_rc != 0 )); then
      echo "❌ API error" >&2
      return 1
    fi
    # invalid/empty response (P2, 2026-09-28): an error message of the
    # server would otherwise be treated as an "answer" and _messages
    # reduced to it — the whole model context would be gone.
    if [[ -z "${response:-}" ]] ||
       ! jq -e '(.choices | type) == "array"' >/dev/null 2>&1 <<< "$response"; then
      echo "❌ Invalid API response (no choices array). Context kept." >&2
      log "run_turn: invalid API response ($(printf '%s' "$response" | tr -d '\n' | cut -c1-160))"
      return 1
    fi
    # token counter for the HUD (stderr, only on trace/TTY)
    _last_prompt_tokens="$(jq -r '.usage.prompt_tokens // empty' <<< "$response" 2>/dev/null)"
    _last_completion_tokens="$(jq -r '.usage.completion_tokens // empty' <<< "$response" 2>/dev/null)"
    content="$(jq -r '.choices[0].message.content // empty' <<< "$response" 2>/dev/null)"
    pending="${content:-}"
    reasoning="$(jq -r '.choices[0].message.reasoning_content // empty' <<< "$response" 2>/dev/null)"
    _trace_reasoning "$reasoning"
    tool_calls_json="$(jq -c '.choices[0].message.tool_calls // []' <<< "$response" 2>/dev/null)"
    tool_count="$(jq 'length' <<< "$tool_calls_json" 2>/dev/null || echo 0)"
    local finish_reason
    finish_reason="$(jq -r '.choices[0].finish_reason // empty' <<< "$response" 2>/dev/null)"
    local assistant_msg
    assistant_msg="$(jq -n --arg content "$content" --argjson tcs "$tool_calls_json" '{role:"assistant",content:$content,tool_calls:$tcs}')"
    if (( tool_count == 0 )); then
      assistant_msg="$(jq 'del(.tool_calls)' <<< "$assistant_msg")"
    fi
    append_message_json "$assistant_msg" "$reasoning"
    _turn_count=$((_turn_count + 1))
    if (( tool_count == 0 )); then
      if [[ "$finish_reason" == "length" || -z "${content:-}" ]]; then
        # P2 (live test 2026-09-29): empty OR truncated gets at most
        # two nudges with reasoning_budget=0 — otherwise the loop keeps spinning.
        if (( nudge_count >= ${_max_nudges:-4} )); then
          # live re-test 2026-09-29: after nudges finish=length contains
          # often usable text already (195–214 bytes measured) — render that,
          # instead of ending in nothing with rc 1. Only with truly empty content
          # the abort comes after.
          if [[ -n "${content:-}" ]]; then
            echo "⚠️  Answer stayed truncated — showing the partial text." >&2
            _trace_hud "$turn_t0"
            _trace_rule
            render_markdown <<< "$content"
            return 0
          fi
          echo "⚠️  Answer repeatedly empty — aborting." >&2
          log "run_turn: repeatedly empty answer, aborting"
          return 1
        fi
        nudge_count=$((nudge_count + 1))
        if [[ -z "${content:-}" ]]; then
          echo "⚠️  Answer was empty (the server cut it). Nudge, without further thinking." >&2
          append_message "user" "Your last answer was EMPTY: the server cut it before visible text arrived. Write the finished answer NOW as plain text — without further thinking, without starting over."
        else
          echo "⚠️  Answer was truncated (finish_reason=length). Finish it now." >&2
          append_message "user" "Your answer was truncated. Finish it NOW — without further thinking and without starting over."
        fi
        _rb_override=0
        continue
      fi
      # step 13 (2026-09-28): metadata + separator FIRST, the answer
      # is the last thing on screen — otherwise it visually drowns.
      _trace_hud "$turn_t0"
      _trace_rule
      render_markdown <<< "$content"
      return 0
    fi
    if [[ "$finish_reason" == "length" ]]; then
      # P2: tool calls truncated — likewise max. 2 nudges, rb=0, so that the
      # arguments not get lost in reasoning (live test 2026-09-29).
      if (( nudge_count >= ${_max_nudges:-4} )); then
        echo "⚠️  Tool calls repeatedly truncated — aborting." >&2
        log "run_turn: tool calls repeatedly truncated, aborting"
        return 1
      fi
      nudge_count=$((nudge_count + 1))
      echo "⚠️  Tool calls were truncated (finish_reason=length). Answer again, without further thinking." >&2
      append_message "user" "Your tool calls were incomplete. Rewrite the complete tool calls NOW — without further thinking."
      _rb_override=0
      continue
    fi
    local i tc name args tci result
    for (( i=0; i<tool_count; i++ )); do
      tc="$(jq ".[$i]" <<< "$tool_calls_json" 2>/dev/null)"
      name="$(jq -r '.function.name' <<< "$tc" 2>/dev/null)"
      args="$(jq -r '.function.arguments // empty' <<< "$tc" 2>/dev/null)"
      tci="$(jq -r '.id // empty' <<< "$tc" 2>/dev/null)"
      # tool trace: show the human THAT work is happening (stderr, only TTY/LEX_TRACE)
      _trace_line "$name" "$(_hint_args "$args")"
      # without command substitution: dispatch_tool then runs in this shell,
      # so the MCP session (ref snapshot, tab state) survives several turns.
      # else instead of ||: a failing mktemp must not run dispatch twice
      # (review finding 2026-09-29).
      _dtf="$(mktemp 2>/dev/null)"
      if [[ -n "$_dtf" ]]; then
        dispatch_tool "$name" "$args" >"$_dtf" 2>&1
        result="$(cat "$_dtf")"
        rm -f "$_dtf"
      else
        result="$(dispatch_tool "$name" "$args" 2>&1)"
      fi
      # central cap (review 2026-09-29): tools without their own limit
      # (mem_*, todo, list_files, context7) reach _tool_max_output here
      # _tool_max_output — otherwise the context floods the jq/API limits.
      if (( ${#result} > ${_tool_max_output:-50000} )); then
        rlen=${#result}
        result="${result:0:${_tool_max_output:-50000}}"$'\n... (truncated, '"$rlen"' bytes total)'
      fi
      _trace_result "$name" "$result"
      log "tool: $name"
      append_tool_message "$tci" "$result"
    done
  done
}

# Server hint (no HTTP request — only a port check, no external calls).
server_hint() {
  [[ -n "${_mock:-}${_mock_file:-}" ]] && return 0
  command -v ss >/dev/null 2>&1 || return 0
  local port
  port="$(printf '%s' "${_api_url:-}" | sed -E 's#^[a-z]+://[^:/]+:([0-9]+).*#\1#')"
  [[ "$port" =~ ^[0-9]+$ ]] || return 0
  # collect the ss output first, then check: `ss | grep -q` breaks the
  # reader -> rc 141 -> under pipefail falsely "no server" (P3).
  local listening
  listening="$(ss -ltn 2>/dev/null)" || listening=""
  if ! grep -Eq ":${port}[[:space:]]" <<< "$listening"; then
    printf '⚠️  No server on port %s — start it with `./ai.sh start` (or set LEX_MOCK=done for tests).\n' "$port" >&2
  fi
}

cmd_status() {
  local mode="live" sessions=0 mem_entries=0 sess_state
  [[ -n "${_mock:-}${_mock_file:-}" ]] && mode="mock"
  sessions="$(find "${_lex_home}/sessions" -name 'session.jsonl' -type f 2>/dev/null | wc -l | tr -d ' ')"
  if [[ -d "$_mem_dir" ]]; then
    mem_entries="$(find "$_mem_dir" -name '*.md' -type f 2>/dev/null | wc -l | tr -d ' ')"
  fi
  if [[ -n "${_session_file:-}" ]]; then
    sess_state="$_session_file"
  else
    case "${_session_enabled:-1}" in
      0|false|no|off|"") sess_state="off (LEX_SESSION=0)" ;;
      *)                 sess_state="ready (created on the next run)" ;;
    esac
  fi
  printf 'lex %s\n' "$LEX_VERSION"
  printf '  mode      : %s\n' "$mode"
  printf '  model     : %s\n' "${_model:-?}"
  printf '  api       : %s\n' "${_api_url:-?}"
  printf '  budget    : %s  max_tokens: %s  temp: %s  max_turns: %s\n' \
    "${_reasoning_budget:-?}" "${_max_tokens:-?}" "${_temperature:-?}" "${_max_turns:-?}"
  printf '  tools     : timeout %ss, max_output %s, nudges %s, approve: %s, sudo: %s\n' \
    "${_tool_timeout:-?}" "${_tool_max_output:-?}" "${_max_nudges:-?}" "${_approve}" "${_sudo}"
  printf '  session   : %s (%s stored sessions)\n' "$sess_state" "$sessions"
  printf '  mem       : %s (%s entries)\n' "$_mem_dir" "$mem_entries"
  printf '  wiki      : %s%s\n' "$_wiki_dir" "$([[ -d "$_wiki_dir" ]] && echo '' || echo '  (missing, fetch creates it)')"
  printf '  htools    : %s%s\n' "$_htools_dir" "$([[ -d "$_htools_dir" ]] && echo '' || echo '  (missing — mkdir -p)')"
  printf '  turns     : %s\n' "$_turn_count"
}

agent_loop() {
  setup_messages
  if [[ ! -t 0 ]]; then
    # no terminal (pipe/file): evaluate one round like --oneshot — otherwise
    # `echo "question" | lex` would swallow the input silently (P3, review
    # 2026-09-29). oneshot calls setup_messages again (idempotent
    # rebuild of _messages) and handles the /status|/help|/plan cases.
    oneshot
    return $?
  fi
  server_hint
  _hist_init
  _prompt
  while [[ -t 0 ]]; do
    local input
    # -e = readline (arrows/history/tab), only when stdin is a terminal
    if [[ -t 0 ]]; then
      IFS= read -e -r input || return 0
    else
      IFS= read -r input || return 0
    fi
    [[ -z "$input" ]] && continue
    _hist_add "$input"
    case "$input" in
      /status) cmd_status ;;
      /help)   usage ;;
      /plan)   tool_todo list ;;
      *)       run_turn "$input" ;;
    esac
    _prompt
  done
  echo
  echo "Bye! 👋"
}

oneshot() {
  setup_messages
  local input
  input="$(cat)"
  [[ -z "$input" ]] && return 0
  case "$input" in
    /status) cmd_status ;;
    /help)   usage ;;
    /plan)   tool_todo list ;;
    *)       run_turn "$input" ;;
  esac
}

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------
install_lex() {
  mkdir -p "${_lex_home}/log" "${_lex_home}/sessions" "${_lex_home}/mem" "${_lex_home}/hooks" "${_lex_home}/agents" "${_lex_home}/skills"
  if [[ ! -f "${_lex_home}/settings.json" ]]; then
    cat > "${_lex_home}/settings.json" <<EOF
{
  "api_url": "${_default_api_url}",
  "api_key": "",
  "model": "${_default_model}",
  "max_tokens": ${_default_max_tokens},
  "reasoning_budget_tokens": ${_default_reasoning_budget},
  "temperature": ${_default_temperature}
}
EOF
  fi
  echo "✓ ~/.lex/ ready: ${_lex_home}"
}

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------
usage() {
  cat <<EOF
lex — a pure-Bash LLM terminal agent (v${LEX_VERSION})

Modes:
  lex                 interactive REPL
  lex --oneshot       single shot (stdin -> stdout, exit)
  lex --approve       REPL, every bash run is confirmed first (TTY needed)
  lex --status        config and runtime status
  lex --install       create ~/.lex/ + settings.json
  lex --version       show version
  lex --help          this help

Slash commands (REPL):
  /status             same as --status
  /plan               show the current plan (todo list)
  /help               this help

Security:
  tool_bash has a hard deny list (rm -rf /, block devices, su, pipes,
  reboots) — that always applies. --approve additionally asks before each run.
  sudo is not a ban but a gate (bug #13): without a valid sudo ticket
  EXACTLY ONE prompt appears on the terminal with the command, the
  password goes straight to sudo; with a valid ticket y/N is asked. Without
  terminal there is no sudo run. LEX_SUDO=0 blocks sudo completely,
  LEX_SUDO_APPROVE=0 drops the y/N question for a valid ticket.

Config (4 tiers, ENV overrides):
  defaults -> ~/.lex/settings.json -> .lex/settings.json -> ENV
  ENV: LEX_API_URL, LEX_API_KEY, LEX_MODEL, LEX_MAX_TOKENS, LEX_REASONING_BUDGET,
       LEX_TEMPERATURE, LEX_MAX_TURNS, LEX_TOOL_TIMEOUT, LEX_TOOL_MAX_OUTPUT,
       LEX_LOG_DIR, LEX_MOCK, LEX_MOCK_FILE, LEX_APPROVE, LEX_SUDO, LEX_SUDO_APPROVE,
       LEX_SESSION, LEX_MEM_DIR,
       LEX_WIKI_DIR, LEX_HTOOLS_DIR, LEX_TRACE, LEX_SHOW_REASONING, LEX_REASONING_MAX,
       LEX_MCP, LEX_MCP_TIMEOUT, LEX_SEARCH_URL, LEX_SEARCH_TIMEOUT

Input: Readline (arrow keys, Ctrl-A/E/W/U, tab = path completion),
History in ~/.lex/history (500 entries).
EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  # Flags in any order (P2, review 2026-09-29): previously only
  # only `lex --approve …`, but not `lex --status --approve`.
  local cmd=""
  while (( $# > 0 )); do
    case "$1" in
      --approve)
        _approve=1
        ;;
      *)
        if [[ -n "$cmd" ]]; then
          echo "Unknown command: $1" >&2
          usage >&2
          exit 1
        fi
        cmd="$1"
        ;;
    esac
    shift
  done
  case "$cmd" in
    --oneshot)
      load_config || exit 1
      oneshot
      ;;
    --status)
      _need_model=0
      load_config || exit 1
      cmd_status
      ;;
    --install)
      install_lex
      ;;
    --version)
      printf '%s %s\n' "$LEX_NAME" "$LEX_VERSION"
      ;;
    --help|-h|help)
      usage
      ;;
    "")
      load_config || exit 1
      agent_loop
      ;;
    *)
      echo "Unknown command: $cmd" >&2
      usage >&2
      exit 1
      ;;
  esac
}

main "$@"
