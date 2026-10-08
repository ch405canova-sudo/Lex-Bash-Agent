# Changelog

All notable changes to lex.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
versioning: [Semantic Versioning](https://semver.org/lang/en/).

## [Unreleased]

### Added

- **Repetition/loop detection (step 46):** `_rep_detect` checks the visible
  assistant text in `run_turn` before rendering in three ways —
  A1 trailing run (the same 8–32-character unit ≥6× at the end), A2
  sentence loop (one sentence ≥40 characters identical ≥4×), A3 rep-4
  (share of duplicate 4-grams ≥0.35 from 70 4-grams); code blocks, table
  rows and separators are masked (false-positive gate for the `/lexpen`
  style), `reasoning_content` and tool_calls arguments are never in scope
  (scope rule from deepseek-harness #3480). Reaction: 1st hit = soft
  nudge, 2nd hit = hard "decide now in one sentence" nudge, then a
  truncation render (2000 characters) instead of the loop output — all
  against the existing `_max_nudges` budget, plus a log line and a
  session record `{type:repetition}`. The guard hangs on the code, not
  on the prompt → equally effective in the original and in `/lexpen`
  mode. New runner `test/test_repetition.sh` (+20 → **709** = 696
  individual checks + 13 runners).
- **`/autosudo` + address/download rule in the system prompt (step 45):**
  slash `/autosudo on|off|status` (env `LEX_AUTOSUDO=1`) skips only the
  y/N approval in `_sudo_gate` — password/TTY questions in `_sudo_ask`
  stay manual; fixes the y/N blocker of the step-45 runs (two hangs of
  24/13 minutes each). Prompt bullet "never guess addresses & downloads":
  GitHub owners/release tags/assets only from sources (repo root status →
  expanded_assets → verification, under 1 kB = error page), no release =
  go install/source build. Live proof in the follow-up run: 3× sudo
  without blocking, 0 guessed GitHub owners. Finding while writing: the
  prompt range anchor in `test_features.sh` broke → prompt bullets
  swapped, test unchanged.

- **Prompt mode `/lexpen` (step 43):** slash `/lexpen` swaps slot 0 of the
  context for the senior-engineer persona from
  `~/.lex/prompts/lexpen.md` (created on first call, XP4→Lex, freely
  editable afterwards), `/lex` or `/lexpen off` switches back to the
  original — history and wiki state are kept (`_wiki_ex()`), session
  record `{type:prompt_mode}`, prompt marker `lex*>`, `prompt` line in
  `/status`, slash list in `usage()`. Answers in the mode: English (prompt
  directive), title block, "Chief", `✦ made by @Lex ✦`. Live verify on the
  real model (persona answer with attribution + nmap run; afterwards `/lex`
  → English again). +22 checks in `test_features.sh` → **691** total.
- **Context compaction + context HUD (step 42):** new slash `/compact`
  (force) and an auto-trigger in `run_turn` compress old messages as soon
  as the estimated prompt exceeds the threshold
  `ctx − max(max_tokens, buffer)` (default 242144 → inert): `_pairing_ok`
  as a jq gate (roles/`tool_call_id`/no open `tool_calls`), forward-unit
  grouping, `[User]:` token, English summary with marker
  `<!--lex-compact-->` in slot 1, fail-safe on an empty summary
  (`_messages` byte-identical), session record `{type:compaction}` +
  span. Config tier `ctx_limit`/`compact`/`compact_keep`/`compact_buffer`
  (2 + env `LEX_CTX_LIMIT`/`LEX_COMPACT`/`LEX_COMPACT_KEEP`/
  `LEX_COMPACT_BUFFER`), HUD `tokens X/Y (Z%) prompt + …`, `/status` with
  a `compact`/`ctx` block, `usage()` names the slash + env. New runner
  `test/test_compaction.sh` (77 checks) — hooked in as the 12th runner in
  `run_all.sh`. Estimator `Bytes ÷ 3` (live verify 2026-10-02 calibrated
  against 17408 `prompt_tokens`: `/4` was 18 % too low).

- **Test run `test_limits.sh` (step 38):** 17 checks that nothing is cut
  off at the lex↔llama boundary — 280,000-byte messages in `_messages`
  **and** the session JSONL, 250,000-byte system prompt, a whole
  60,000-byte file via `read_file`, spill storage complete with a pointer
  in the context, a 150,000-character server answer complete. Hooked in
  as the 11th runner in `run_all.sh`.

- **`testboden` + stream budget (step 37):** `run_all.sh` runs `testboden`
  first — fails if a test file was deleted relative to `HEAD`, is
  referenced as a runner but missing, or exists but is not wired in
  (negative tests: all three directions fail → rc 1, normal → 0).
  `test/test_sse.sh` encodes a performance budget: 3000 chunks under
  2000 ms **and** fully evaluated (29 s back then, ~0.12 s today). Plus
  rules in LEX.md §C/§D/§E: optimization needs a test + measurement in
  the same change, fixture tests must be able to break the path,
  experiments only on `opt/*` branches.
- **Observability: span-level logging + `lex --eval` (step 36):**
  every tool run is appended as one JSONL line to `<log-dir>/spans.jsonl`
  (`span_log()`; `ts`, `name`, `args_hash`, `duration_ms`, `ok`).
  `dispatch_tool()` times each branch and takes `ok` from its exit status
  (`return "$_rc"` keeps the tool's own status). `_ms_now()` guards the
  GNU-only `date +%N`. `cmd_eval()` renders the trace-level report
  (count, total duration, `FAILED: n of m` / `OK` verdict, per-tool
  aggregation, latest 10 spans) via **`lex --eval [spans-file]`** —
  listed in `--help`, works without `load_config`. New runner
  `test/test_eval.sh` (16 checks).
- **Ethical-hacker persona + H-Tools path (step 18):** new system
  prompt block "Role & expertise (ethical hacker)" — the user text
  verbatim (cybersecurity, network security, penetration testing,
  exploit development, real-time detection, security awareness,
  reporting, ethical/legal approach) — between identity and
  personality block. Plus `_htools_dir` with a hardcoded default
  `$HOME/H-Tools` (override `LEX_HTOOLS_DIR` in tier 1), prompt rule
  "software & tools ALWAYS in ${_htools_dir}" (mkdir -p; never $HOME,
  never /tmp), `--status` shows `htools`, `usage` lists the env
  variable. Tests +12 → **418**, `lex` 2418 → **2439 lines**, §5 map
  re-pulled (76/76).

- **Knowledge package security playbook (step 19):** wiki article
  `concepts/security-playbook.md` (best practices, tool pipeline,
  using/reading Wireshark, attacker IPs) + 5 raw sources (WSUG,
  Wireshark dfref, MITRE T1595) + prompt needle "for security tasks
  read the playbook first". Tests +1 → **419**, `lex` → **2440 lines**.

- **Create-playbooks method (step 20):** wiki article
  `concepts/playbook-erstellen.md` (purpose/continuity, when
  criteria, 6-step process, template) + prompt needle "maintain your
  own playbooks" + raw source (Wikipedia runbook). Tests +1 → **420**,
  `lex` → **2441 lines**.

- **Browser control (step 22):** new tool `browser`
  (navigate|snapshot|click|type|press|back|tabs|close) over
  Playwright-MCP with **system Chrome** (`npx @playwright/mcp --browser
  chrome`, no download) — accessibility-snapshot workflow (no vision
  model needed), **without a write gate** (user decision: full trust).
  Prompt list + cycle rule, default config extended by `playwright`,
  `fake_mcp.sh` extended with browser actions, step-22 block. Tests
  +21 → **441**, `lex` → **2528 lines**, map 77/77.

- **Generic `mcp` tool (step 23):** `mcp(server, tool, arguments?)`
  with discovery (__tools → `tools/list` via the new `list` mode in
  `_mcp_call`) + `tools/call` for any server — from now on every new
  MCP server is only `mcp.json` + a prompt needle. `dispatch` accepts
  `arguments` as an object or a string. Finding: the __tools
  apostrophes silently broke `_build_tools` (SC1078) → corrected.
  Tests +15 → **456**, `lex` → **2581 lines**, map 78/78.

- **Desktop access (step 24):** MCP server `@agent-sh/computer-use-linux`
  (Wayland-first) integrated — default config `desktop` + prompt rule
  "desktop tasks: first __tools, then state → act", no new tool
  (generic `mcp` from step 23). `doctor`/`setup`: AT-SPI enabled,
  screenshots/remote desktop/input ready; window-targeting extension
  activates at the next login. Tests +8 → **464**, `lex` → **2583
  lines**.

- **Postgres (step 25, mandatory):** PostgreSQL **16.15 user-space**
  under `~/.lex/pg` (debs via `dpkg -x`, no sudo) with DB `lex` (trust
  auth on 127.0.0.1) + `start.sh`; MCP server **`@bytebase/dbhub`**
  (execute_sql/search_objects, full rights, stdio) over Node 22 (nvm)
  + wrapper `dbhub.sh`. lex only config+prompt: default config
  `postgres` with DSN, mcp description, prompt rule "database tasks:
  first __tools, then SQL". Real proof: discovery + INSERT via
  `tool_mcp postgres`. Tests +8 → **472**, `lex` → **2585 lines**.

- **sudo gate (LEX.md §6 #13):** `tool_bash` may now use `sudo` — but
  only through a gate that shows **exactly one prompt**. Without a
  valid sudo ticket `_sudo_ask()` runs `sudo -v` and shows the command
  on the controlling TTY first; the password goes **straight to sudo**
  and never runs through lex. With a valid ticket it asks `y/N`.
  Without a controlling TTY it refuses. New env variables `LEX_SUDO=0`
  (block) and `LEX_SUDO_APPROVE=0` (drop the y/N question); visible in
  `/status` as `sudo: 1|0`, system prompt/tool schema/`usage`/README
  updated accordingly.

- **Debug proxy `tools/llama-proxy.sh`:** forwards requests to the
  llama-server and logs request **and** response (`.proxy/traffic.log`,
  `<id>-in/out.json` raw + indented, request/upstream headers).
  Commands: `start`, `stop`, `status`, `tail`, `show <n>`. Listens on
  `127.0.0.1` only, port 8080 is rejected, on a dead upstream it
  answers **HTTP 502**.
- **`test/test_proxy.sh`** (26 checks) as the 7th runner in
  `run_all.sh` → **7 runners**; `bash -n` and shellcheck in CI now also
  cover `tools/*.sh`.

- **11 tools instead of 8** (steps 1 + 2 of the wiki integration):
  - `append_file` — append-only writes, indispensable for
    `wiki/log.md` (there `write_file` would lose data).
  - `search` — full-text search as `path:line:text`, **literal** by
    default (`grep -F`), `regex=true` for regular expressions, `glob`
    as a file filter, 200-hit cap.
  - `list_files` with `pattern` (glob) and `recursive` — without both
    arguments still `ls -la`.
  - `todo(action, text?, index?)` — persistent plan under
    `~/.lex/plans/`, `done` is idempotent, index = display position;
    slash command `/plan`.
  - Config `LEX_WIKI_DIR` (default `<wiki>`) + wiki conventions
    and planning discipline in the system prompt, `wiki` in `/status`.
- **Interface (step 6):** CLI with a TUI feel, everything stderr-only
  on a TTY or `LEX_TRACE=1` (pipes/tests stay raw):
  - `⏳ thinking …` spinner during generation (starts only after
    250 ms so fast answers do not flicker)
  - `↳ tool` + indented tool return capped at 8 lines/600 chars
    (invisible before)
  - `⚙ thinking:` block for `reasoning_content` (`LEX_SHOW_REASONING=0`
    off, `LEX_REASONING_MAX` truncates, default 4000)
  - separator after every answer
  - input with **read line**: arrow keys, Ctrl-A/E/W/U, **Tab =
    path completion**, history in `~/.lex/history` (500 entries) —
    pure bash (`read -e` + `set -o emacs` + `bind`), without gum/dialog
- **`fetch` (step 4):** loads a page and stores it as a raw source
  under `<wiki>/raw/<topic>/YYYY-MM-DD-slug.md` with a metadata header
  (`> Source` / `> Collected` / `> Published`), collision-free slugs
  (`-2`, `-3`, …). HTML is converted to plain text via awk (headings,
  lists, link targets as `Text (URL)`, entities decoded, navigation/
  scripts removed), non-HTML stays unchanged. No new dependency.
- **Rendering (step 3):** `⚙` tool trace and `⏱` HUD on stderr (TTY
  only or `LEX_TRACE=1`) and markdown light for the final answer
  (headings, `**bold**`, `` `code` ``, `[[wikilinks]]`, quotes) —
  without a TTY the output stays raw.

- **Personality (step 7):** block at the top of the system prompt —
  always English, brief & effective, **never guess** (for commands
  `<cmd> --help`, for facts `search`/`web_search`/`web_fetch`, for
  libraries `context7`), errors as material (`wiki/log.md`,
  `wiki/errors/`) and the wiki as memory across sessions.
- **Rendering like opencode (step 8):** warning quotes orange,
  `❌`/`Error:` red, `✓`/`OK` green, links cyan+underline with a dim
  URL, list markers and `---` dim — plus **real pipe tables** (header
  cyan/bold, grid dim, right-aligned on `:---`, truncated to 40
  chars, UTF-8 safe), still only on a TTY or with `force`.
- **MCP (step 9):** stdio JSON-RPC client (`initialize` →
  `notifications/initialized` → `tools/call`, answer filtered by
  `id`), servers from `~/.lex/mcp.json` (defaults: **defuddle**,
  **context7**), `LEX_MCP=0` switches off, `LEX_MCP_TIMEOUT` limits.
  **+2 tools**: `web_fetch(url, max_length?)` (crawler excerpt without
  storage) and `context7(query, library?)` (`resolve-library-id` →
  `query-docs`) → **15 tools**; `test/fake_mcp.sh` covers the error
  paths.
- **Web search (step 10):** `web_search(query)` over
  `html.duckduckgo.com` **without an API key** — title, URL and
  snippet, `uddg=` redirects and HTML entities resolved,
  `LEX_SEARCH_URL` switchable (the tests run offline against it).
- **Browser `wait` action (live test 2026-09-29):** `browser(action=wait,
  text=seconds)` → playwright `browser_wait_for`. Pages load
  asynchronously after `back`/`click`/`Enter` and issue new refs —
  before any ref-based action only a fresh `snapshot` (prompt rule) or
  `wait` until the page is idle helps. Plus a stub `browser_wait_for`
  in `test/fake_mcp.sh` and two needles.

- **Three ENV/config knobs (steps 53–56):** `LEX_API_RETRIES` (or
  `api_retries` in `settings.json`) — retries on HTTP 429/5xx and curl
  errors, default 2, clamped ≤10; `LEX_LOOP_GUARD=off` — switches the
  fail memory in `run_turn` off; `LEX_REASONING_STORE_MAX` — upper
  limit for the `reasoning` stored in the session (default 20000
  characters).

### Changed

- **Palette / readability (step 14):** all ANSI sequences now run
  through the central `_palette_init()` palette — **`NO_COLOR`** and
  `TERM=dumb` switch colors off completely (prompt and
  `render_markdown` are colorless even without a TTY). H1 is **bold +
  underline** instead of "white" (white was invisible on a light
  terminal), H3 is cyan instead of bold, the `⚙ thinking:` content is
  **grey** instead of italic (italic is not supported everywhere).
  Order stays: HUD + separator before the answer, the answer stands
  last.
- **Deny list:** `sudo` is **out** (it was forbidden across the board
  before), `su` stays hard-forbidden. The agent can therefore do root
  tasks for the first time instead of only refusing them — user task
  2026-09-28 ("a prompt where I can just type it in").
  Test count **330 → 340**, `lex` 2018 → **2101 lines**.
- **Readability (step 13):** thinking, tools and answer are clearly
  separated — `⚙ thinking:` with a dim-magenta header and **italic
  indented** content, tool name **bold cyan** (arguments grey), `↳`
  cyan-dim, HUD + separator **before** the answer (it stands last on
  the screen), H1 bold white instead of cyan. Nine checks for it
  (+8 → **330**).
- **`todo` plan session-independent:** `_todo_file()` now returns
  `~/.lex/plans/plan.md` instead of `plans/<session-id>.md` — the plan
  carries over sessions like the wiki and `mem_*` (two child runs with
  different session ids as a test, +5 → **322 checks**).
- **`lex` callable directly:** symlink `~/.local/bin/lex → <repo>/lex`
  so `lex` starts in the terminal without an alias.
- **15 instead of 12 tools** (steps 9/10): schema list
  (`_build_tools`), `dispatch_tool`, system prompt and docs
  (README/LEX.md) updated; test count **245 → 317**.
- **`reasoning_budget` = 4096** (`lex:94`, previously 1024) — in sync
  with `ai.sh --reasoning-budget 4096`; verified via a live request
  through the proxy (`reasoning_budget_tokens: 4096`,
  `max_tokens: 8192`).
- **Anti-doubt prompt (step 15, 2026-09-29):** three new rules in the
  system prompt — **decide firmly** (no self-doubt phrasing about
  things you checked yourself), **verification via tools** (`bash -n`,
  `./test/run_all.sh`, `search`, logs) instead of self-introspection,
  **no doubt loops** (no "are you sure?", after an error →
  cause/fix/continue). Research-based (arxiv 2603.03330: "are you
  sure?" flips correct answers 72 vs. 6, arxiv 2506.21285:
  self-criticism worthless at 27B, llama.cpp #12339, Reddit PSA
  "tools on → no overthinking"); three checks for it (+3 → **389**),
  `lex` 2330 → **2333 lines**. In parallel (not in this repo): the
  same principles in the agent config, `ai.sh` added
  `--reasoning-budget-message` (`--reasoning-preserve` stays, budget
  4096).
- **Workflow fixes (step 16, live test 2026-09-29):**
  - **Empty/truncated answers:** `run_turn` nudges at
    `finish_reason=length` **and** on empty content at most 2× and
    sends `reasoning_budget_tokens: 0` for that (`_rb_override` in
    `call_api`) — before, reasoning ate all tokens again in the nudge
    turn and the answer stayed empty; after 2 nudges an existing
    partial text is rendered (measured live: 195–214 bytes that would
    otherwise be lost), only on empty content does it abort (rc 1)
    instead of spinning until `max_turns`. Additionally the max-turns
    abort also renders the existing partial text (follow-up test 2:
    578 bytes hung below it) instead of discarding it.
  - **Spinner on a TTY only:** `_spin_start()` returns without
    `[[ -t 2 ]]` — otherwise the `\r` repaints ended up in pipes and
    log files (even with `LEX_TRACE=1`); the test runs under a
    `script` PTY for this.
  - **Defaults:** `temperature 0.1 → 0.7`, `max_turns 50 → 100`
    (`LEX_TEMPERATURE`/`LEX_MAX_TURNS`/`settings.json` still override).
- **Wiki learning (step 17):**
  - `setup_messages` embeds the wiki state (index.md + the latest 40
    lines from wiki/log.md) — the project wiki is therefore always in
    the context, independent of the model's tool behavior.
  - Mandatory rule in the system prompt: read wiki + `mem_search`
    first, only then say "I don't know"; new findings are collected
    (a line to log.md, new artifacts as an article with an index.md
    line).
  - `search` without `path` searches the wiki instead of the current
    directory (prompt and schema description accordingly).
  - Tests +9 → **403**, `lex` 2382 → **2394 lines**.
  - **E2BIG context protection (17b, live-verify finding):**
    `tool_read_file` caps like `tool_bash` at `tool_max_output` (a
    135-KB log.md exceeded jq's 128-KB argument limit, left `msg`
    empty and wiped the whole context); `append_message` truncates
    >100000 bytes and catches jq errors, `append_message_json` never
    overwrites `$_messages` with an empty result. Tests +3 → **406**,
    `lex` **2418 lines**.
  - Live proofs: sudo gate 1A (one prompt, password in the sudo
    prompt, continuation), anti-doubt behavior confirmed; tests
    **389 → 394**, `lex` 2333 → **2382 lines**.

- **MCP session survives calls (live test 2026-09-29):** every tool
  iteration used to run in a command substitution → own subshell →
  the coproc session died after every call (navigate→snapshot landed
  on `about:blank`, refs different per call). Now: `_mcp_out_var()`
  (temp file instead of `$(…)`), `run_turn` writes `dispatch_tool`
  output via redirection into a temp file, keep-alive in `_mcp_call`
  (reuse key `server|argv`, `kill -0`, restart on config change,
  server death, JSON-RPC error or timeout).
- **Playwright config:** default pinned to `@playwright/mcp@0.0.83`
  with `--cdp-endpoint http://127.0.0.1:9222`; `tool_browser` provides
  the Chrome service for cdp configs via `_ensure_browser()` (PID file
  `$LEX_HOME/browser.pid`). click/type send `target` (= ref id) as
  schema ≥0.0.83 requires.

### Changed/Fixed 2026-10-06 — sudo password back, Postgres libs, deterministic counts

- **sudo password visible again (user order “undo it”)**: the machine-wide
  `/etc/sudoers.d/90-chaos` (`chaos ALL=(ALL) NOPASSWD:ALL`) created on
  2026-10-03 was removed — `sudo -n true` fails again (`rc=1`). The lex path
  now fires exactly when sudo is needed: `_sudo_gate` → `_tty_preview` →
  “sudo password now:” → `sudo -v < /dev/tty` (password goes straight to
  sudo, never through lex). Without a controlling TTY: unchanged clean
  refusal.
- **user-space Postgres startable again**: apt removed `libxml2 2.9.14` and
  `libicu74` on Oct 5; the Noble debs `libxml2_2.9.14+dfsg-1.3ubuntu3.9` and
  `libicu74_74.2-1ubuntu3.1` now live under `~/.lex/pg/deb` (`dpkg-deb -x`) —
  `ai.sh pg start` + `psql` query green again.
- **tests no longer depend on the machine's sudoers**: `test_features`
  (DE+EN) simulates the sudo-ticket state (`_sudo_ticket_valid` stub: block
  “without ticket” → `1`, block “session grant” → `0`). Before, the NOPASSWD
  revert silently changed which branch ran.
- **tests +3 → 794** (`test_features` 525 → 528; 807 PASS lines minus 13
  runner marks), `run_all.sh` **13/13** in DE and EN, sequential; `bash -n` +
  shellcheck warning-clean. `ai.sh` (outside the repo) gained `pg` and
  `docker` subcommands incl. `start`/`stop` integration.

### Fixed 2026-10-06 — fix package steps 53–56 (tool hang, HTTP 500, redaction, fail memory)

- **Tool runs no longer hang on the pipe**: `_run_limited` now writes
  the child chain output into a temp file (`$_rl_out`) instead of a
  pipe — the reader can no longer stay blocked on an open write end
  (basis: bug-bash msg00059, opencode #32504, codey #65). Plus
  `_kill_tree()`: BFS collects the chain up to the root and kills
  leaf→root (TERM, KILL after 3 s), a watchdog at `secs+10` puts its
  own timer around the run, state lives in `$_rl_pid`/`$_rl_hung`, the
  rc of `_run_limited` is the function status. `tool_bash` hangs on
  it. Live: `sleep 20` with `LEX_TOOL_TIMEOUT=5` → tool result
  `Exit-Code: 124`, the turn continues.
- **HTTP errors are retried (P3/P6)**: `call_api` retries 429/5xx and
  curl network errors up to 2× (OpenAI SDK norm), `_retry_delay` uses
  0.8/1.6/3.2 s with an 8 s ceiling and ±25 % jitter; new config
  `api_retries` / `LEX_API_RETRIES` (default 2, clamped ≤10, tier
  1/2/4). Error messages now carry the HTTP code, a body snippet
  (400 B), the byte count, the attempt count and — for
  `parse_error`/`invalid string` — the hint that special characters or
  size in the tool arguments are the cause (llama.cpp #21660/#22072).
- **Secrets no longer leave lex (P4)**: `_redact()`/`_redact_var()`
  mask the own API key, `password`/`secret`/`token`/`apikey`/`auth`
  pairs, `Bearer`/`Basic`, token prefixes (`sk-`, `ghp-`, `xox…`) and
  URL credentials — applied in `log()`, `session_write()`, the display
  (`_trace_result`, `_trace_reasoning`, `_md_render`) and the wiki
  write paths. Deliberately **not** in the model context and not on
  config/script targets. The value group stays JSON-safe (an escaped
  quotation pair as a whole, open values without `"`/`\`).
- **Fail memory against tool loops (P5)**: `run_turn` keeps the
  signature `cksum(name|args|result[0..200])` per tool call; three
  identical runs in a row → soft nudge with an answer obligation, then
  identical again → hard stop (`rc 1`). The result bytes are part of
  the signature so legitimate polling (growing file, flipping status)
  resets the counter. Switch via `LEX_LOOP_GUARD=off`, session records
  `{type:loop_guard}`.
- **Context warning from 85 % + pinning (P7)**: `_compact_run` prints
  `⚠️ Context X % full …` **before** the compaction gate, independent
  of `LEX_COMPACT` (re-armed via `_compact_warned`, once per “nearly
  full” period); `_compact_prompt` appends a pinning block (goal,
  running plans, open decisions and paths always carry into the new
  summary).
- **Reasoning cap (P8)**: `append_message_json` limits the stored
  `reasoning` to `LEX_REASONING_STORE_MAX` (default 20000 characters)
  and writes the remainder into the line as a hint.
- **Live test 2026-10-06** (isolated `LEX_HOME`, real LLM turns):
  oneshot, tool timeout, redaction, fail memory, 85 % warning and
  reasoning cap all confirmed live. **Finding along the way**: the
  first redactor ate the `\` before the closing `"` and made one
  session.jsonl line invalid → value group hardened
  (`wiki/errors/2026-10-06-redaction-brach-session-jsonl.md`); after
  that the session is 100 % parseable and the secret is nowhere in
  `LEX_HOME`.
- **Tests +41 → 791** (13 runners, DE+EN green): `test_features` +38
  (fix package incl. JSON safety), `test_loop` +9 (fail memory
  soft/hard/off), `test_http` +6 (retry with 3×500, with/without
  budget), `test_sse` +1 (three attempts). No commit/push (order
  missing).

### Fixed 2026-10-05 — sudo asked y/N per command (step 52)

- **Session grant instead of y/N per command (new default)**: the sudo
  gate asked for a y/N approval per sudo command whenever a ticket was
  valid (58 % of the run time in the AnonOps run, 32 sudo calls). New:
  process state `_sudo_grant` (`""` unasked → `"1"` granted →
  `"0"` declined) + `_sudo_grant_request()` — at the first sudo of the
  session ONE question `allow sudo for this entire session? (y/N): `
  (title + truncated command like the approval prompt, question without
  newline, abortable with Ctrl+C); yes = the session runs without
  further questions, no = stores `"0"` and keeps asking y/N per command
  (old path). `/status` shows `grant: open|granted|declined`,
  `/autosudo on` and `LEX_SUDO_APPROVE=0` also skip the session
  question; without a controlling TTY nothing changes (the question
  fails → decline → old behaviour, deterministic). German
  `sudo für diese ganze Sitzung freigeben? (y/N): `. Along the way the
  old error in the `/help` text "LEX_SUDO_APPROVE=0 (default)" was
  corrected — the default is 1. **Tests +12 → 750** (13 runners,
  DE+EN green): 8 gate/anchor checks in `test_features` + 4 PTY E2E
  checks in `test_input` (fake `sudo` in PATH logs the calls, exactly
  1× session question in the transcript).

### Fixed 2026-10-05 — Ctrl+C killed lex + session permissions umask-dependent (step 51)

- **Ctrl+C ended the entire lex process**: there was no `trap … INT` —
  both in a turn and at the prompt (live finding: session `125104`, the
  user stopped the AnonOps run and lex was completely dead). Now:
  `_sigint()`-trap (lex:3255) — in a turn only `_turn_aborted=1`,
  `run_turn` aborts at the abort points (loop top / after `call_api` /
  tool loop), all open `tool_call` IDs get their protocol-consistent
  marking answer (`_abort_turn_tools`), a hanging user message is
  answered via `_abort_turn_note`; at the prompt: 1st Ctrl+C discards
  the line, 2nd press ≤2 s = `Bye!`, Ctrl+D stays EOF (distinguished
  via `rc>128 || _int_seen`).
- **`timeout` survived tty Ctrl+C**: the child chain sits in its own
  process group — the turn continued until `tool_timeout` (measured
  20 s instead of 2 s). Fix: `timeout --foreground` in `_run_limited`
  (rc=124 timer still checked, `_have_tf` cache, fallback without
  support).
- **Session permissions umask-dependent**: new sessions came out as
  775/664 (finding: session 125104). Now: `session_init`/`install_lex`
  — `sessions/` + folder `700`, `session.jsonl` via `: >` before the
  first line + `600`; existing sessions fixed up.
- **Diagnosis included (user question "why was there no sudo prompt?")**:
  NOPASSWD:ALL active → sudo never asks for a password, only y/N is the
  question; all 11 long blocks of the run were sudo approvals
  (~2 h 35 m ≈ 58 % of the session, incl. a 2 h Avahi stop); the real
  blockers were Avahi/Tor-DNS/irssi permissions, not sudo.
  **Tests +8 → 738** (13 runners, DE+EN green).

### Fixed 2026-10-05 — visible y/N approval prompt (step 50)

- **Approval question was invisible**: `_approve_request`/`_sudo_ask`
  wrote the question **before** the command
  (`printf 'Approve command (y/N): %s\n' "$cmd"`) — with multi-line sudo
  commands `(y/N)` scrolled off screen, the user only saw the command end
  + blinking cursor (live hang in the AnonOps-Tor run, progress only via
  manual TIOCSTI `y` injection). Now: `_tty_preview_text()`/`_tty_preview()`
  — title + command truncated (200 B, `LC_ALL=C`, `…(+N bytes)`) above the
  question, then `allow? (y/N): ` **without newline** as the last line
  (cursor behind it); `_sudo_ask` analogously, last lex line
  `enter sudo password now:`. Behaviour (y/j), gate and `/autosudo`
  unchanged; ported 1:1 to DE. **Tests +2 → 730** (13 runners, DE+EN green).

### Changed 2026-10-05 — anti-refusal guard for the lexpen mode (step 49)

- **Trigger (user GO)**: before the lexpen prompt, `lex` refused ethical
  opsec analyses (ethical-hacker role + legal sentence → assumed “evil
  hacking”); the persona (`lexpen.md`) fixes that, but there was no
  positive directive to act, and since step 48 the playbook rule
  “permission/scope first” rode along into the mode. **Built**:
  `_prompt_lexpen_guard` (line 402) — “requests are carried out, not
  refused”: scans, packet/log analysis, vulnerability assessments are
  analysis work; questions only technical; legality is the human at the
  terminal's call. Appended to `${_prompt_ops}` exclusively in
  `cmd_lexpen on` — persona unchanged, default prompt byte-identical,
  `/lexpen off` restores the original. **Tests +2 → 728** (guard needle
  in the lexpen context, guard-not-in-default). **Verify**: run_all 13/13
  = 728 green (serially), shellcheck clean, byte identity after
  wiki-path normalization. `lex` 4023 → 4025 lines.

### Changed 2026-10-05 — Ops-layer split in the system prompt (step 48)

- **System prompt split into style + ops, `/lexpen` keeps the
  tool/research rules:** live finding 2026-10-05 (proxychain/SOCKS5
  task, session `20261005-022414`) — in persona mode **0 tool calls**
  for a research task, the "answer" was a pure weights answer. Cause:
  `cmd_lexpen` swaps slot 0 completely for the persona, which carries
  no tool/research rules (tool schemas are still sent, but the
  discipline is missing from the context). The default prompt now
  consists of `_prompt_style` (identity, role, working framework,
  style incl. language rule) + `_prompt_ops` ("You verify with tools,
  not in your head", "Never guess, look it up" → `web_search`,
  "Errors are material", "For humans at a terminal", the 17-tool list,
  wiki structure, rules) and is assembled into `_system_prompt` —
  **byte-identical** to the previous prompt (sha256 `b5578469…`,
  13165 bytes). `cmd_lexpen on` appends `${_prompt_ops}` to the
  persona (`"$content"$'\n'"${_prompt_ops}"`), `/lexpen off` stays as before;
  the style marker `ALWAYS in English` stays out of the mode (the
  persona carries its own LANGUAGE directive). **Tests +14 → 726**
  (default identity, style/ops needles one by one, ops needles in the
  lexpen context, marker gone/restored); test find: the prompt-range
  `sed` start pattern `^_system_prompt="` in `test_features.sh`
  broke → `^_prompt_style="`. Byte identity proven against the
  reference hash with the same `LEX_HOME`. Newline find after the port: `$(cat)` strips trailing newlines → explicit `$'\n'` between persona and ops (test +1 → 726).

### Fixed 2026-10-03 — REPL prompt after empty Enter + spinner hardening (step 47)

- **REPL prompt disappeared (user report "after tasks only a blinking
  cursor"):** on empty input `[[ -z "$input" ]] && continue` skipped
  `_prompt` — readline clears the input line on Enter, the prompt stayed
  gone (input kept working). Now `{ _spin_stop; _prompt; continue; }`
  plus a hard `_spin_stop` before every end-of-loop `_prompt`.
- **Spinner hardening:** the repaint loop ran `while :;` forever — a
  surviving child would have kept eating the prompt line. Now a flag gate
  `while [[ -f "$_spin_flag" ]]` (ends ≤0.12 s after `_spin_stop`), the
  erase-clear therefore always runs before the prompt.
- **Tests +3 → 712** (699 individual checks + 13 runners): PTY test
  (2× Enter → ≥3 `lex>`) + two static anchors in `test_input.sh`.
- **Ancillary finding fixed:** `LEX.md` had doubled itself in commit
  2bdbd7d (§0–§7 and §9–§13 each twice) → rebuilt on the basis of 756e10b
  with entries 45/46 and the current numbers (811 lines).

### Fixed

- **15 review findings (step 14, P1/P2/P3):**
  - **[P1]** the rm deny list let `rm -rf -- /`, `rm -Rf /`,
    `rm --no-preserve-root -rf /`, `sudo rm -rf /`, `xargs rm -rf /`
    through — now a segment-wise check of the rm target tokens.
  - **[P1]** `curl … | sh | cat` and `curl … && sh x.sh` got through
    because only the **last** segment was checked — now all segments.
  - **[P1]** `safe_path` allowed bare roots (`/etc`, `/usr`, `/var`,
    `/proc`) and **symlink targets** — both are now blocked (incl.
    `cd -P` in the fallback).
  - **[P2]** `su postgres -c …` was missed — `su` now counts as a
    command word (false positives like `grep su -` stay allowed).
  - **[P2]** invalid/empty API answers reduced `_messages` to the
    error message (**model context gone**) — now a guard with rc 1.
  - **[P2]** an MCP server dying at startup triggered a `set -u`
    crash or rc 141 without a message — `_mcp_send()` + fd check now
    report "server is not startable".
  - **[P2]** non-numeric config values (`LEX_MAX_TURNS=abc`) broke
    `(( ))` — `_int_or()`/`_float_or()` validate.
  - **[P2]** `edit_file` wrote via `mktemp` to `/tmp` (not atomic,
    mode 600) — temp file now in the target directory, mode copied
    (also `todo done`).
  - **[P2]** `_mcp_config` without `LEX_HOME` and `_load_settings`
    without `max_turns`/`tool_timeout`/`tool_max_output`/`log_dir`
    corrected.
  - **[P3]** `dispatch_tool` requires JSON objects as arguments, the
    prompt only on a TTY, the `ss` check without a pipe (rc 141),
    spinner `trap` on exit, test path `/tmp/safe_err` → `$TMP`.
  - Test count **340 → 386**, `lex` 2101 → **2330 lines**.
- **Backticks in the system prompt** would have been executed as
  **command substitution** (`bash`, `context7(…)` …) — all 32
  occurrences in the prompt block escaped (`\``); a test checks both
  the source and the evaluated prompt.
- **MCP timeout was never detected:** `if ! …; then rc=$?` always
  gives 0 → timeouts reported "connection aborted". Now `rc=$?`
  directly after the assignment; a read rc > 128 counts as a timeout,
  everything else as a dropped connection.
- **`&amp;` stayed in search hits:** `gsub(/&amp;/, "&", …)` — `&` in
  the replacement means "whole match" → `"\\&"`.
- **`_ddg_parse` received the query instead of the HTML** as stdin
  (`<<< "$q"` in the parser) → every result "No hits".
- **Doubled HTTP status line** in the proxy
  (`HTTP/1.1 HTTP/1.1 200 OK`) → `curl: Unsupported HTTP/1
  subversion`; now the last status from `curl -D` wins (the
  `100 Continue` of the Expect handshake).
- **Content-Length 1 byte too large** (body via `$(cat …)`, the
  command substitution swallowed the trailing `\n`) → `curl: rc 18`.
- **Race in logging:** `traffic.log` was written only after the
  answer → now before.
- **`status` always showed the default upstream `8080`** instead of
  the stored URL; the proxy also bound `0.0.0.0` instead of
  `127.0.0.1`.

- **E2BIG in the curl path (live test 2026-09-29):** `call_api` passed
  the body as an exec argument — from ~128 KiB the kernel reported
  "argument list too long" (multi-turn runs pushed the history from
  34 KB to 140 KB). Now a temp file + `curl -d @file`; needle with a
  140,000-byte body against the fake server. Tests **+13 → 485**,
  `lex` → **2683 lines**.
- **Ref decay after async page events (live test):** playwright issues
  new refs after `fill` (autocomplete) and `back` (reload) — the old
  ref was rejected with "Ref not found". Not a lex bug in the narrow
  sense, but caught: `wait` action, ref rule in the system prompt
  ("always a fresh snapshot before ref actions") and the session-stable
  state from the keep-alive fix.
- **DDG anti-bot (external, only reported):** `web_search` got 0 hits
  because DuckDuckGo serves a challenge page — not fixed on the lex
  side (open point: another provider/our own UA).

### Changed

- **Limits raised for big tasks (full audit 2026-09-29):**
  defaults `max_tokens` 8192 → **16384**, `reasoning_budget` 4096 →
  **8192**, `max_turns` 100 → **200**, `tool_timeout` 60 → **300 s**;
  nudge limit as its own default 4 (`LEX_MAX_NUDGES`) instead of a
  hidden number; API timeout `LEX_API_TIMEOUT` (default 1800 s)
  instead of a fixed `curl --max-time 900`; `--status` shows `nudges`.
  Goal: no more aborts from `finish=length`, nudge limits or timeouts
  that are too short on long generations.

### Fixed

- **jq E2BIG in the message path:** `call_api` delivers the context
  via `--slurpfile`/temp file instead of as an exec argument (Linux
  limit 131,071 B → empty body, "❌ API error", reproduced with 193
  KB); `append_tool_message`, `append_message` and `setup_messages`
  now cap their jq arguments at 100,000 B (prevents broken protocol /
  start aborts). `dispatch_tool` results go through the central tool
  cap (`LEX_TOOL_MAX_OUTPUT`).
- **Hard deny list closed:** `rm -rf ${HOME}` / `"$HOME"/.` / `~/.`
  (home root in literal **and** expanded form; subtrees like
  `~/project` stay allowed) and download bypasses `curl … | sudo sh`,
  `| env sh`, `| nohup sh`, `bash <(curl …)`, `source <(curl …)`,
  `eval "$(curl …)"`, `curl … & sh f.sh` (wrapper skip,
  direct execution/process substitution, `&` as a segment separator).
- **Code review fixes (P2/P3):** `tool_web_fetch`/`tool_context7`
  without a subshell (`_mcp_out_var` — coproc session/NEXTID stable),
  `mem_add` loses no entries in the same second (collision loop),
  `edit_file` keeps all trailing newlines, `write_file` is atomic
  (temp file + `mv`) and assigns the correct mode, `--approve` works
  in any argument position, `safe_path` expands `~/…`, MCP error file
  per server (`mcp.<server>.err`), `agent_loop` without a TTY runs
  like `--oneshot` (a pipe no longer swallows the input),
  `_ensure_browser` checks the PID file (no double start on "Profile
  in use"), `source lex` in 4 test runners with an error guard.

### Changed

- **Streaming path in `call_api` (step 36):** answer evaluation now
  runs in a single jq pass (`_sse_to_response`) over the stream file —
  JSON passthrough if the body starts with `{` (classic JSON answers
  stay possible), otherwise `reduce` over the SSE lines: content deltas
  are concatenated, `tool_calls` merged by `index` (name/id from the
  first delta, arguments accumulated), `usage` comes from the stream.
  The transfer runs as `curl -o <stream> -w '%{http_code}'`, so the
  curl return code and the HTTP status can be checked separately.
  3000 chunks: 29 s → **0.12 s**.
- **Nudge logic with diagnostics:** a nudge is only sent on a real
  `finish_reason == "length"`; every nudge line lands as
  `nudge k/max finish=… content=… reasoning=…` in the log, other cases
  get their own messages (reasoning only, empty). The abort now names
  the nudge count, finish_reason and the reasoning length.
- **`test/fake_server.sh`:** extension `.sse` delivers the file as
  `text/event-stream` (stream tests without a consumption problem), the
  first line `STATUS:<code>|{json}` sets the HTTP status.

### Fixed

- **Streaming regression in `call_api` (step 36):** `rc=$?` after
  `done < <(curl …)` was the status of the loop body instead of curl —
  server/HTTP errors silently ended up in the nudge chain (4× "the
  answer was empty", then "answer empty repeatedly — aborting.")
  instead of being an API error. The tool_calls merge
  `jq -s '.[0] + .[1]'` with two here-strings only read the last delta
  → `name: null`, arguments as a fragment (`}`) → `tool: null` in the
  session. `data:` without a space and streams without `[DONE]`
  silently became empty. Fix: rc/HTTP guard, a single jq pass, server
  tolerance, warning on a missing `[DONE]`, real `usage`; tests
  **`test/test_sse.sh` (19)**.
### Fixed

- **No more truncation at the lex↔llama boundary (step 38):**
  `append_message`, `append_tool_message` and `setup_messages` capped
  at 100,000 bytes (E2BIG guard for `jq --arg`),
  `append_message_json` and `assistant_msg` still went through
  arguments, `tool_read_file`/`tool_bash`/`tool_search`/`tool_browser`/
  `tool_mcp` additionally capped at `_tool_max_output` (50,000 bytes)
  and the central cap in `run_turn` cut results off without the model
  being able to notice. The message path now runs over files
  (`--rawfile`/`--slurpfile`), oversized tool results are stashed by
  `_tool_spill()` under `~/.lex/toolout/` (newest 100) and the context
  gets a header + path. Unchanged are the display caps (`_trace_*`,
  `render_markdown`), the 200-hit/500-entry markers and
  `web_fetch max_length`.

- **Lost parts restored:** `_ms_now`/`span_log` and `cmd_eval`
  (`lex --eval`) were missing, `test/fake_server.sh` and
  `test/test_http.sh` were deleted and `test_proxy.sh` sent real
  requests to port 8080 (rule 6) — all brought back or limited to high
  ports.

- **`/exit`/`/quit` were missing (live finding 2026-10-01):** the slash
  list only knew `/status /server /help /plan` — `/exit` fell through
  to `run_turn`, cost a full request (the model answered "Fine. …")
  and left the REPL open. Now `break` in the REPL or rc 0 without a
  model call in oneshot/pipe; `usage()` lists `/server` and `/exit`.

- **HUD logged invented token zeros (live finding 2026-10-01):** the
  request body lacked `stream_options:{include_usage:true}` —
  llama-server only delivers usage in the stream on request → every
  turn showed `tokens 0 prompt + 0 completion`. Body supplemented
  **and** the zero default in `_sse_to_response` removed: without a
  usage event the HUD now shows `?` instead of lying.

- **O6: no compaction/summarization (step 42):** `_messages` grew
  without limit until the server rejected at the ctx limit — now an
  auto-trigger before `append_message user` plus `/compact` as a force;
  the default threshold is deliberately inert (242144), old tests keep
  running unchanged.

### Changed

- **Slash commands documented:** README and `usage()` now name the full
  list `/status`, `/server`, `/plan`, `/help`, `/exit`.

- **"Working framework" in the system prompt (step 40):** a standing
  scope instead of one per request — own systems/lab/CTF, blue-team
  work (hardening, vulnerability analysis, malware analysis, incident
  response, detection engineering) as core business without asking;
  offensive terms as working vocabulary; a scope question instead of a
  blanket refusal. Evidence: Defensive Refusal Bias
  (arXiv 2603.01246) — authorization sentences in the *user message*
  make refusals worse, COVER (ACL 2025) — the system prompt is the
  effective lever.

- **HUD format with ctx% (step 42):** with `ctx_limit` set, `_trace_hud`
  shows `tokens 65536/262144 (25%) prompt + 42 completion`, without a
  limit still the old formula, without usage `?/Y` — four old
  assertions in `test_features.sh`/`test_sse.sh` pulled to the new
  contract.

### This status

- Tests **591 → 669** (12 runners green), `lex` 3211 → **3622 lines**,
  `shellcheck -S warning` = 0.

## [0.1.0] — 2026-09-28

First complete, tested version.

### Added

- **Session persistence (spec §6.5):** append-only JSONL under
  `~/.lex/sessions/<id>/session.jsonl` — header line plus one line per
  message, including `reasoning_content`. The reasoning deliberately
  does **not** go into the model context (context protection, LEX.md
  §4). Switch off with `LEX_SESSION=0`.
- **Memory tools (spec §6.4):** `mem_add`, `mem_list`, `mem_search`.
  Markdown with YAML frontmatter (`date`, `type`, `slug`) under
  `~/.lex/mem/`, types `memory|fact|preference|note`.
  Configurable via `LEX_MEM_DIR`.
- **Hard deny list for `tool_bash` (§6 #11):** `rm -rf /`/`~`, block
  devices, fork bombs, `sudo`/`su`, shutdown/reboot, system processes,
  throwing away permissions, `curl|sh` — **always on**.
- **Approval gate (§6 #12, opt-in):** `--approve` or `LEX_APPROVE=1`
  asks before every bash execution (only with a controlling TTY).
- **`/status` (spec §6.6)** as a slash command and as `lex --status`:
  mode, model, API, budget, tools, session, memory, turn counter.
- **`edit_file` multi-block (spec §6.6):** new argument `all`
  (schema: `boolean`) replaces all occurrences.
- **`lex --approve`**, `/help`, port hint at REPL start (port check via
  `ss` only, **no** HTTP request).
- **Test runner `test/test_features.sh`** (53 checks) + registration in
  `run_all.sh` → 6 runners, 89 checks.
- **CI:** `.github/workflows/ci.yml` (`bash -n`, shellcheck, tests,
  hygiene).
- `README.md`, `CHANGELOG.md`.

### Fixed

- **§6 #8 — GNU tool guards:** `readlink -f` at the script path,
  `realpath -m` in `safe_path()` and `timeout` in `tool_bash()` now go
  through fallback chains (`_abs_path`, `_run_limited`).
- **§6 #9 — `install_lex`:** creates `mem/`, no longer `mem_net/`.
- **§6 #10 — `LEX_MOCK_FILE` destroyed the source file:** now a shadow
  copy under `~/.lex/mock/`; the sequence survives across runs, the
  source stays intact.
- **REPL prompt:** `printf '\033[1;34m\x01%\033[0m '` produced "Invalid
  format specifier" and a broken prompt (shellcheck SC2183) → `lex>`.
- **Isolation of `test_input.sh`:** `LEX_HOME` was not set, the tests
  wrote sessions and mock shadows into the real `~/.lex`.
- shellcheck `-S warning` is clean for `lex` and all test files.
