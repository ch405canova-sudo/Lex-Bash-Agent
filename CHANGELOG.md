# Changelog

All notable changes to lex.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
versioning: [Semantic Versioning](https://semver.org/lang/en/).

## [Unreleased]

### Added

- **Observability: span-level logging + `lex --eval` (2026-09-30):**
  every tool run is appended as one JSONL line to `<log-dir>/spans.jsonl`
  (`span_log()`; `ts`, `name`, `args_hash`, `duration_ms`, `ok`).
  `dispatch_tool()` times each branch and takes `ok` from its exit status
  (`return "$_rc"` keeps the tool's own status). `_ms_now()` guards the
  GNU-only `date +%N`. `cmd_eval()` renders the trace-level report
  (count, total duration, `FAILED: n of m` / `OK` verdict, per-tool
  aggregation, latest 10 spans) via **`lex --eval [spans-file]`** —
  listed in `--help`, works without `load_config`. New runner
  `test/test_eval.sh` (+15 checks).

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
  - Config `LEX_WIKI_DIR` (default `~/.lex/wiki`) + wiki conventions
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

- **Tests 514 → 530 (7 → 8 runners):** new `eval` runner covers
  `span_log`, the `dispatch_tool` instrumentation and `cmd_eval`
  (success path, failure path, empty/missing span file, CLI flag).

- **Limits raised for big tasks (full audit 2026-09-29):**
  defaults `max_tokens` 8192 → **16384**, `reasoning_budget` 4096 →
  **8192**, `max_turns` 100 → **200**, `tool_timeout` 60 → **300 s**;
  nudge limit as its own default 4 (`LEX_MAX_NUDGES`) instead of a
  hidden number; API timeout `LEX_API_TIMEOUT` (default 1800 s)
  instead of a fixed `curl --max-time 900`; `--status` shows `nudges`.
  Goal: no more aborts from `finish=length`, nudge limits or timeouts
  that are too short on long generations.

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

### This status

- Tests **485 → 514** (7 runners green), `lex` 2683 → **2884 lines**,
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
