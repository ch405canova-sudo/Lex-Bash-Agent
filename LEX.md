# LEX — The single working document for Project-Lex

> **Status**: 2026-09-28 · **Supersedes** the 7 older MD documents (they are no longer maintained).
> **Rule**: From now on only maintain this file. Everything else is archive/reference.
> **For a new chat**: read §0 → §3 (current state) → §7 (next step). Nothing else.

---

## 0. HOW YOU CONTINUE WORKING HERE (handover)

### Check paths & status (30 seconds)
```bash
# Where am I, what does it say?
less LEX.md                       # this document

# Does the script still run at all?
bash -n lex                       # syntax
bash test/run_all.sh              # 8 runners, 530 checks — green as of 2026-09-30 (v0.1.0 + wiki steps 1–20 + browser + mcp + desktop + postgres + live test + full audit + eval)

# Quick test WITHOUT a server
echo "Say hello" | LEX_MOCK=done ./lex --oneshot   # → "Works."
```

### The 4 golden rules when continuing work
1. **Never send real requests to `127.0.0.1:8080`** — the llama-server is **shared**: other local tooling and Lex run on the same llama-server (port 8080) with the same model (Ternary-Bonsai-2-27B). **Until the user grants a live-test approval: NEVER test against the real server** — always `LEX_MOCK=done` or `LEX_MOCK_FILE=<file>`. The exception (live test) applies **only** with explicit approval from the user.
2. **Everything in English** — code comments, error messages, docs, answers.
3. **Pure Bash + jq + curl only** — no new dependency without an entry in §2.
4. **Keep the §7 order** — do not skip ahead, do not build two things in parallel.

### Where what lives
| I want to… | File |
|---|---|
| continue building | `LEX.md` §7 |
| clarify an open decision | `LEX.md` §9 |
| fix a bug | `LEX.md` §6 |
| look up the API contract | `LEX.md` §4 |
| write something into the knowledge base | the project wiki (log → `wiki/log.md`, errors → `wiki/errors/`) |

### Instant start in a fresh chat
> "Read `LEX.md`. Phase 0 is complete (all §7 steps ✅) — take the next task from §8/§10. Work according to §0.1. Use mock requests only; real requests only after approval."

---

## 0.1 THE BUILD METHOD — one uniform procedure

> This is the protocol **every** change to Lex follows. Same steps, same order, every time. Whoever deviates from it explains why in the log.

### A. Six immovable principles
1. **Spec before code.** First one line of decision in `LEX.md` (§2 or §6), then the code. No "I'll note that later".
2. **The loop is sacred.** `run_turn()` is never rewritten — new capabilities arrive as a function + dispatch entry *on top of it* (learn-claude-code s01/s02). Anyone touching the loop body states that explicitly.
3. **One thing at a time.** No jumping across phases, no building two features in parallel. At most one in-flight task.
4. **Evidence, not claims.** Every finding gets `file:line` or an executed finding-command. No numbers from memory.
5. **No silent regression.** Everything that worked before must work after — `run_all.sh` green, syntax ok, no new broken links.
6. **Research is not progress.** Building happens only per §7. Research runs only when it concerns an open question from §9 (that list lives in §8).

### B. The work cycle (8 steps, always in this order)
```
1. SITUATION      gather findings: run grep/ls/bash -n, back them with file:line
2. DECISION       only when open: pick an option → entry in LEX.md §2/§6/§9
3. PLAN           for 3+ steps: create a TODO list
4. BUILD          code in lex per the rules in C
5. VERIFY         bash -n + shellcheck + affected tests (+ fake server for HTTP)
6. LOG            project log → what, why, verified by what
7. SYNC           update LEX.md: tick off §6, §3 current state, close §9 if applicable
8. REVIEW         link/consistency check (no new dead references), check the DoD in E
```
> **Steps 6+7 are the part that historically ran irregularly.** Without them the task does not count as done.

### C. Code rules for `lex`
| Rule | Why |
|---|---|
| `set -u` + `set -o pipefail`, **no** `set -e` | deliberate error handling, no silent abort |
| JSON **only** via `jq`, HTTP **only** via `curl` | no hand serialization |
| Values **always** into jq via `<<< "$var"` — never as an argument | that was the old `load_config` bug |
| One function = one responsibility, ≤ ~40 lines | testable, readable |
| New capability = 3 places: `_build_tools()` + `dispatch_tool()` + function | never inside the loop body |
| Error messages in English on **stderr**, structured tool result to the model | stdout stays clean for the answer |
| No GNU-only without a guard (`realpath`, `readlink -f`, `timeout` → `command -v` check) | portability claim in §1 |
| Config via `_default_*` → tier 2/3 → `LEX_*` ENV | the 4-tier model stays the only config source |
| `tool_bash` protection: `</dev/null`, `_run_limited` (timeout guard), deny list, truncation, exit code | spec §6.3 — `</dev/null` + newline + timeout guard + deny list **fulfilled 2026-09-28**; `truncated` flag (distinguishing "cut off" vs. "error") open for phase 1 |

### D. Test rules
- **Every new function gets a test.** `test/test_<name>.sh`, always mocked.
- **Never port 8080** — neither in a test nor in a single command.
- **The HTTP path is tested**, not only the mock branch: fake server over `ncat` — `test/test_http.sh` in `run_all.sh` since 2026-09-28 (gap §8 F closed).
- `bash test/run_all.sh` = the single source of truth for "is it done".
- Tests are assert-based (`[ "$out" = "expected" ]`), output on stdout, exit 1 on failure — exactly what `run_all.sh` already expects.

### E. Definition of Done — a task is finished only when
- [ ] code changed
- [ ] `bash -n lex` → OK
- [ ] affected/new tests written and green (`run_all.sh` fully green)
- [ ] no new broken link (link check over `lex/` and the wiki)
- [ ] the project log has an entry
- [ ] `LEX.md` is current (§6, §3, §9 if applicable)
- [ ] errors that occurred are filed in the wiki error log

### F. Phase discipline
- **Phase 0 is not done until DoD + §7 are through** (including CI, docs, v0.1.0). Docker was **dropped** (decision 2026-09-28). Only then phase 1.
- Idea for a later phase → **one line in §10**, then straight back to the current task.
- Research only against §8 (A–G) — everything else is distraction.
- **A (model tool-call benchmark) takes priority over everything else**, because it decides whether the rest of the effort pays off at all.

### G. Handover protocol (every new chat, same 5 steps)
1. Read `LEX.md` (§0 → §3 → §7)
2. Clarify an open question from §9 **if** it concerns the task
3. Take exactly **one** task from §7
4. Run cycle B
5. At the end tick off DoD E, log entry, done — do **not** grab "one quick" second thing

---


## 1. What is Lex

An **own, pure-Bash LLM terminal agent** — pure Bash + `jq` + `curl`, no Node/Python.

| | |
|---|---|
| **Binary** | `lex` (one script, 2992 lines) |
| **Backend** | local llama-server, OpenAI protocol, `http://127.0.0.1:8080/v1/chat/completions` |
| **Model** | `Ternary-Bonsai-2-27B-PQ2_0.gguf` (alias=`--alias` possible) |
| **Language** | English-first — system prompt, docs, answers |
| **Target platforms** | dev machine, internal server, Termux, iSH, Raspberry Pi, router |
| **License** | MIT (`LICENSE`, 2026-09-28 — instead of the earlier planned Apache 2.0) |
| **Status** | **Phase 0 complete** — commit `46c64c0`, tag `v0.1.0` |

**Positioning**: local-first (no API key), English-first, single-user, reactive, CI + release from day 1.

**Golden Rule**: We are not rebuilding the reference project. We are building Lex. — learn-claude-code = philosophical reference point.

---

## 2. Decisions taken (do not re-discuss)

| Topic | Decision |
|---|---|
| Base language | **Pure Bash** (option A). Hybrid/Python/Mojo → rejected (original architecture options review) |
| LLM backend | **local-first**, cloud API optional (`LEX_API_URL`/`LEX_API_KEY`/`LEX_MODEL`) |
| Tool set phase 0 | **8 tools**: `read_file`, `write_file`, `edit_file` (+`all`), `bash`, `list_files`, `mem_add`, `mem_list`, `mem_search` |
| Tool set phase 0.1b (planning) | **+1**: `todo(action ∈ add\|done\|list, text, index)` → `~/.lex/plans/plan.md` (session-independent, see decision "planning (addendum)"), idempotent ticking by display index, slash `/plan` → **11 tools** |
| Rendering (step 3) | `render_markdown` (markdown light, raw without TTY) + `⚙` trace and `⏱` HUD on stderr → **stdout pipes unchanged** |
| Interface (step 6) | **CLI with a TUI feel, no curses toolkit**: `⏳ thinking …` spinner, `↳ tool` return, `⚙ thinking:` block and separator on **stderr** (TTY only or `LEX_TRACE=1`), input with **Readline** (`read -e` + `set -o emacs` + `bind`) incl. history `~/.lex/history` (500) and tab path completion — deliberately **without** gum/dialog/fzf, no new dependencies |
| Tool set phase 0.1 (fetch) | **+1** → **12 tools**: `fetch(url, topic)` stores pages as raw sources under `<wiki>/raw/<topic>/YYYY-MM-DD-slug.md` (metadata header per `raw-template.md`), HTML→plaintext via awk |
| Personality (step 7) | **Block at the top of the system prompt**: always English, stay brief, **never guess** (for commands `<cmd> --help`, for facts `search`/`web_search`/`web_fetch`, for libraries `context7`), capture errors as material (`wiki/log.md`, `wiki/errors/`), the wiki = **memory across sessions**. Backticks in the prompt are escaped (`\``), otherwise bash executes them as command substitution — a test checks that |
| Rendering (step 8) | `render_markdown` additionally colors warning quotes (orange), `❌`/`Error:` (red), `✓`/`OK` (green), links (cyan+underline, URL dim) and list markers — and renders **pipe tables** for real (header cyan/bold, grid dim, right-aligned on `:---`, truncated to 40 chars, **UTF-8 safe**) |
| MCP (step 9) | **stdio JSON-RPC 2.0**, one session per call (`initialize` → `notifications/initialized` → `tools/call`), servers from `${LEX_HOME}/mcp.json` (default: **defuddle** + **context7** + **playwright** (step 22)), `LEX_MCP=0` to switch off, `LEX_MCP_TIMEOUT`. **+2 tools**: `web_fetch(url, max_length?)` (crawler excerpt, no storage), `context7(query, library?)` (resolve → query-docs) + `browser` (step 22) + `mcp` (step 23) → **17 tools** |
| Readability (step 13) | **Clear visual contrast like opencode** (user feedback 2026-09-28: "thinking and answer looked too similar, the answer was easy to miss"): thinking = dim-magenta header + italic/indented content (observation, not an answer), tools = bold cyan name + grey arguments, `↳` cyan-dim, HUD + separator **before** the answer, the answer stands **last** (H1 bold white, H2 bold cyan) — step 14 refined H1/H2 and the thinking content further (see "Palette") |
| Review fixes (step 14) | **Code review (user task "optimize it, look for bugs, internet welcome"), 15 findings fixed**: hard deny list **segment-wise** (rm variants incl. `--no-preserve-root`/`sudo`/`xargs`, `curl …\|sh\|cat`, `curl … && sh`, `su postgres -c`), `safe_path` blocks bare roots **and** resolves symlink targets, invalid API answers do **not** wipe the model context, dead MCP servers report "not startable", config validated numerically, `edit_file` keeps the mode and writes atomically, `dispatch_tool` requires JSON objects, prompt only on a TTY, `ss` check pipefail-safe, `_load_settings` reads all keys, spinner `trap`; details in §6 #14–28 |
| Palette (step 14) | **Color convention**: all sequences go through `_palette_init()` variables → `NO_COLOR` and `TERM=dumb` switch colors off completely (prompt and `render_markdown` are colorless even without a TTY); hierarchy independent of background: **H1 bold+underline** (instead of white — invisible on a light terminal), H2 bold cyan, H3 cyan, `⚙ thinking:` header dim-magenta + content **grey `90`** instead of italic (italic is not supported everywhere), tool bold cyan, `↳` cyan-dim, HUD/separator dim — answer still last |
| Planning (addendum) | **`todo` is session-independent**: a stable path `~/.lex/plans/plan.md` instead of `<session-id>.md` — the plan carries over sessions like the wiki and `mem_*` (own tests: two child runs with different session IDs) |
| Web search (step 10) | **+1**: `web_search(query)` via `html.duckduckgo.com` **without an API-key** — results as `n) title / URL / snippet`, `uddg=` redirects and entities resolved, `LEX_SEARCH_URL` as a switchable endpoint (tests run offline against it) |
| Tool set phase 0.1 (wiki) | **+2**: `append_file` (append-only, for `wiki/log.md`), `search` (literal by default, `regex=true`, `path:line:text`), `list_files` **extended** with `pattern` (glob) + `recursive` → **10 tools**; config `LEX_WIKI_DIR` (default `~/.lex/wiki`) + wiki conventions in the system prompt |
| Memory phase 0 | Simple file-based memory (`~/.lex/mem/`, Markdown+YAML) — **not** 16×200 (that is phase 3) — **implemented 2026-09-28** |
| Session | append-only JSONL in `~/.lex/sessions/<id>/` — **implemented 2026-09-28** (`LEX_SESSION=0` switches it off) |
| Security | **hard deny list in `tool_bash`, always on** + **opt-in** approval gate (`--approve`/`LEX_APPROVE=1`) — decision 2026-09-28 |
| sudo in `tool_bash` | **gate instead of prohibition** (user task 2026-09-28: "a prompt where I can just type it in"): `su` **stays** forbidden, `sudo` leaves the deny list and runs through `_sudo_gate()` — **always exactly ONE prompt**: without a valid sudo ticket `_sudo_ask()` shows the command on the controlling TTY and runs `sudo -v` → **the password goes straight to sudo**, never through lex (no variable, no log, `tool_bash` stdin stays `</dev/null>`); with a valid ticket `_approve_request()` asks y/N. No controlling TTY → refusal. `LEX_SUDO=0` switches sudo off completely, `LEX_SUDO_APPROVE=0` drops the y/N question when a ticket is already valid |
| `reasoning_budget` / `max_tokens` | **8192 / 16384** since 2026-09-29 (full audit "large tasks", G1) — before that 4096/8192 (decision 2026-09-28, synced with `ai.sh`; the server flag `--reasoning-budget 4096` is still overridden) |
| Daemon / hooks | from phase 4 / 3–4 (MCP **not** deferred: the stdio client has been running since step 9) |
| CI, Docker, release | CI from day 1 ✅ (GitHub Actions), semver ✅ (`v0.1.0`) — **Docker dropped** (user decision 2026-09-28) |
| Sub-agents, 24+ tools, streaming | phase 1–2 |

---

## 3. Current state (verified 2026-09-28, status **v0.1.0**)

### Exists & works (every point executed individually)
- `bash -n lex tools/*.sh test/*.sh` → syntax OK · `shellcheck -S warning lex test/*.sh tools/*.sh` → **0 warnings** (shellcheck 0.9.0 installed)
- `./lex --version` → `lex 0.1.0` · `./lex --help` OK · `./lex --status` shows mode/model/tools/session/memory
- `echo "Say hello" | LEX_MOCK=done ./lex --oneshot` → `Works.`
- **1 live request (approved)**: `LEX_MAX_TURNS=1 ./lex --oneshot` → `Works.` against the real llama-server; session `~/.lex/sessions/20260928-062954-46894-29948/session.jsonl` (3 lines, `reasoning` preserved)
- `LEX_HOME=<tmp> ./lex --install` → `~/.lex/{log,sessions,mem,hooks,agents,skills}` + `settings.json` (no more `mem_net/`)
- **17 tools** implemented (8 from phase 0 + `append_file` + `search`, `list_files` with `pattern`/`recursive`, `todo`, `fetch`, `web_search`, `web_fetch`, `context7`, `browser`, `mcp`), 4-tier config, mock layer (`LEX_MOCK`, `LEX_MOCK_FILE` with a shadow copy)
- **Personality prompt** (step 7): English block at the top, "never guess", error documentation, wiki as memory — backticks in the string escaped, otherwise command substitution
- **Anti-doubt prompt** (step 15, 2026-09-29): three rules in the system prompt — decide firmly (no self-doubt phrasing about things you checked yourself), verify via tools (`bash -n`, `./test/run_all.sh`, `search`, logs) instead of introspection, no doubt loops (no "are you sure?", after an error → cause/fix/continue); basis: research (arxiv 2603.03330, 2506.21285, llama.cpp #12339) — plus `--reasoning-budget-message` in `ai.sh` and the same principles in the agent config (`--reasoning-preserve` stays active)
- **Workflow fixes** (step 16, 2026-09-29, from the live test): truncation **and** empty answers get at most 2 nudges with `reasoning_budget_tokens: 0` (cause of the "empty answers": reasoning ate all tokens again in the nudge turn); after 2 nudges an existing partial text is rendered (measured live: 195–214 bytes the old path would have discarded), only a truly empty answer aborts instead of spinning forever; the max-turns abort also renders the existing partial text instead of discarding it; the spinner only runs on a real TTY (no `\r` garbage in pipes, even with `LEX_TRACE=1`); defaults `temperature 0.1 → 0.7` and `max_turns 50 → 100` (`LEX_TEMPERATURE`/`LEX_MAX_TURNS`/settings.json still override)
- **Wiki learning** (step 17, 2026-09-29): `setup_messages` embeds the wiki state (index.md + `tail -n 40` from wiki/log.md, ≈ 11 KB constant) — memory no longer hangs on a random model tool call; mandatory rule in the prompt ("only after that may you say you do not know something", collect: new findings as a line in log.md or an article + index.md); `search` without `path` searches **the wiki** instead of `.` (live error from step 16b: it searched its own home)
- **Rendering** (step 8): markdown light + warning/error/success/links and real **pipe tables** (right-aligned, UTF-8 safe), only on a TTY or with `force`
- **MCP client** (step 9): stdio JSON-RPC against **real** `defuddle` and `context7` servers verified live; `test/fake_mcp.sh` covers the error paths
- **Web search** (step 10): `web_search` without API key (DuckDuckGo), redirect/entity decoding, tested offline against a local fixture
- **Session JSONL** (append-only, one message per line; `reasoning_content` is persisted but **not** written into the model context)
- **Memory** under `~/.lex/mem/` (Markdown + YAML frontmatter, types `memory|fact|preference|note`)
- **Security**: hard deny list in `tool_bash` (always on) + opt-in `--approve` (TTY only) + **sudo gate** (§6 #13: exactly one prompt, password straight to sudo)
- **Tests**: 8 test files + `fake_server.sh` + `fake_mcp.sh`, **530 checks** (522 individual + 8 runner marks), `bash test/run_all.sh` → **PASS: 8  FAIL: 0  TOTAL: 8** (exit 0)
- **Observability** (step 26, 2026-09-30): every tool run is appended as one JSONL line to `<log-dir>/spans.jsonl` (`span_log()`, `_ms_now()` guards the GNU-only `date +%N`), `dispatch_tool()` times each branch and records `ok` from its exit status; `cmd_eval()` aggregates the trace (count, total duration, failure verdict, per tool, latest 10 spans) via **`lex --eval [spans-file]`**
- **Debug proxy** `tools/llama-proxy.sh` (2026-09-28): forwards requests to the llama-server and logs request/response (`start|stop|status|tail|show`), logs in `.proxy/` (gitignored). Binds **127.0.0.1 only**, port 8080 is rejected
- **2 live requests (approved)**: first direct (`Works.`), second **via the proxy** → confirmed `reasoning_budget_tokens: 4096`, `max_tokens: 8192`, 8 tools, `finish=stop`
- **Mutation tests**: deny list / session / `edit_file all` each broken individually → `test_features.sh` red (the tests are not vacuous)
- **Review fixes (step 14, 2026-09-28)**: hard deny list over **segments** (`rm -rf -- /`, `sudo rm -rf /`, `xargs rm -rf /`, `curl …|sh|cat`, `curl … && sh`, `su postgres -c`), `safe_path` also blocks **bare roots** and **symlink targets**, invalid API answers no longer wipe the context, dead MCP servers report "not startable", config values validated numerically, `edit_file` keeps permissions, `dispatch_tool` requires JSON objects, prompt only on a TTY, `ss` check pipefail-safe
- **Palette (step 14)**: colors go through variables (`_palette_init`) → `NO_COLOR`/`TERM=dumb` switch everything off; H1 bold+**underline** instead of "white" (readable on a light background), H3 cyan, thinking content **grey instead of italic**
- **Git**: repository initialized, commits `46c64c0` → `1faafaf` → `9c3f4e9`, tag **v0.1.0**, working tree clean

### Tree (status 2026-09-30)
```
<repo>/
├── lex                        ✅ 2992 lines, shellcheck-clean
├── LEX.md                     ✅ this document
├── README.md                  ✅
├── CHANGELOG.md               ✅
├── LICENSE                    ✅ MIT
├── ai.sh                      ✅ llama-server manager (path-free)
├── install.sh                 ✅ interactive installer
├── .gitignore                 ✅
├── .github/workflows/ci.yml   ✅ bash -n + shellcheck (incl. tools/) + run_all.sh + hygiene check
├── tools/llama-proxy.sh       ✅ debug proxy (start|stop|status|tail|show), 127.0.0.1 only
├── test/run_all.sh            ✅ 8 runners, green
├── test/test_input.sh         ✅ 10 checks (CLI modes, mock sequence)
├── test/test_tools.sh         ✅ 15 checks (5 tools + safe_path + dispatch)
├── test/test_loop.sh          ✅ 9 checks (run_turn, finish_reason, max_turns)
├── test/test_http.sh          ✅ 2 checks (real curl path, fake server)
├── test/test_features.sh      ✅ 317 checks (spec, deny, approve, wiki steps 1–10, todo session-independent, readability, review fixes)
├── test/test_proxy.sh         ✅ 26 checks (pass-through, logging, 502, 8080 block)
├── test/test_eval.sh          ✅ 15 checks (span log, dispatch instrumentation, cmd_eval, --eval)
├── test/fake_server.sh        ✅ ncat helper on a high port, never 8080
├── test/fake_mcp.sh           ✅ minimal MCP server (stdio/JSON-RPC) for the MCP tests
└── Dockerfile                 ⛔ dropped (decision 2026-09-28: lex has nothing to do with Docker)
```

**Verified 2026-09-30**: `bash test/run_all.sh` → **PASS: 8  FAIL: 0  TOTAL: 8**
(530 checks green, exit 0) · `shellcheck -S warning lex test/*.sh tools/*.sh` → 0.

---

## 4. API contract (verified LIVE, 2026-09-27 — GOLD)

- Endpoint: `POST http://127.0.0.1:8080/v1/chat/completions`
- **`reasoning_budget_tokens`** is **top-level** — NOT `thinking: {budget: …}` (that was the old bug, fixed in `lex:209`)
- Output field: **`reasoning_content`** (not `thinking`)
- Tool calls: `choices[0].message.tool_calls[].function.name` + `.arguments` (JSON **string**)
- `tool` role expects: `{"role":"tool","tool_call_id":"…","content":"…"}` ✅ (that is how it is implemented)
- Streaming (SSE): `data: {choices:[{delta:{reasoning_content:"…", content:"…"}}]}` → **phase 1**
- Usage: `completion_tokens` / `prompt_tokens` / `total_tokens`
- Server flags: `--reasoning on|off|auto`, `--reasoning-budget 4096`; `n_ctx_slot = 262144`, 1 slot
- **lex sends `reasoning_budget_tokens: 8192` + `max_tokens: 16384`** (defaults since 2026-09-29, full audit G1; confirmed live 2026-09-28 with 4096/8192) — identical for the request field, `settings.json`/`LEX_REASONING_BUDGET`/`LEX_MAX_TOKENS` still override. Server flag `--reasoning-budget 4096` remains superseded
- `reasoning_content` is **preserved between tool calls** (important for multi-turn)

- `call_api()` reads `LEX_API_URL` **at runtime** (not only at load time) — the docs "ENV overrides" therefore also apply to changes after startup (2026-09-28, the test harness needs this)
- `reasoning_content` is **written to the session JSONL but never into `_messages`** (deliberate context protection: 129 reasoning blocks ≈ 65,441 tokens would blow the 262,144 context) — see §9 question 7
- **2 live requests made** (2026-09-28, approved): 1. direct `LEX_MAX_TURNS=1 ./lex --oneshot` → `Works.`; 2. via the debug proxy (port 24480) → confirmed `reasoning_budget_tokens:4096`, `max_tokens:8192`, 8 tools, `usage: prompt=1409 completion=69`
> ⚠️ **You and Lex share the llama-server (port 8080). In tests NEVER real requests — always `LEX_MOCK=done` or `LEX_MOCK_FILE=<file>` or your own fake server on a high port.**

---

## 5. Architecture of the script (`lex`, 2992 lines, status 2026-09-30)

| Function | Line | Task |
|---|---|---|
| `_abs_path()` / `_run_limited()` / `_mock_shadow()` | 48 / 67 / 80 | fallback chains for `realpath`/`timeout`, shadow copy for `LEX_MOCK_FILE`; `cd -P` resolves symlinked directories |
| `_load_settings()` | 152 | jq reader for a settings file (incl. `max_turns`, `tool_timeout`, `tool_max_output`, `log_dir`) |
| `_int_or()` / `_float_or()` / `_copy_mode()` | 170 / 176 / 184 | step 14: defuse numeric config values (otherwise `(( ))` abort), copy the template file mode to temp files |
| `load_config()` | 194 | 4-tier: defaults → `~/.lex/settings.json` → `.lex/settings.json` (CWD) → ENV (incl. `LEX_APPROVE/LEX_SESSION/LEX_MEM_DIR`) **+ numeric validation** |
| `log()` | 248 | append-only to `$_log_dir/lex.log` |
| `_ms_now()` / `span_log()` | 261 / 273 | millisecond clock (`date +%N` is GNU-only → guarded, falls back to whole seconds) + span record: one JSONL line per tool run into `<log-dir>/spans.jsonl` (`ts`, `name`, `args_hash`, `duration_ms`, `ok`) |
| `_system_prompt` | 294 | English-first **incl. the personality block (step 7)** — always English, stay brief, never guess, capture errors, wiki as memory — plus **17 tools**, wiki conventions and planning discipline; **anti-doubt (step 15)**: decide firmly, verify via tools instead of introspection, no doubt loops |
| `session_init()` / `session_write()` | 365 / 382 | session id + header line, append-only JSONL |
| `append_message_json()` / `append_message()` / `setup_messages()` | 390 / 410 / 442 | message into the context array **and** as a JSONL record (with optional `reasoning`), JSON array as a string, jq-based |
| `_build_tools()` | 471 | OpenAI tool schemas (17 tools, `edit_file.all` as `boolean`) |
| `call_api()` | 493 | mock file (shadow) → static mock → `curl` + `jq -n` body, URL **at runtime** |
| `safe_path()` | 559 | deny list for `/etc /usr /bin /sbin /boot /dev /proc /sys /var /lib /lib64 /root` — **including bare roots** (`/etc`, not only `/etc/…`) and **symlink targets** (step 14) |
| `tool_read_file()` / `tool_write_file()` / `tool_edit_file()` | 588 / 609 / 650 | file tools (`edit_file` with `all`, counts occurrences; temp file since step 14 **in the target directory**, mode kept) |
| `_bash_segments()` / `_rm_targets_catastrophic()` / `_su_is_command()` / `_bash_denied()` | 728 / 744 / 795 / 817 | **hard deny list** (always on): split the command into segments, rm target check over tokens (`rm -rf -- /`, `sudo rm -rf /`, `xargs rm -rf /`), `curl \| sh` over **all** segments (`…\ \| sh \| cat`, `… && sh`), `su` as a command word (`su postgres -c`); plus block devices, fork bomb, reboot, `chmod -R 777 /`, `history -c`; `sudo` runs through `_sudo_gate()` |
| `_approve_request()` | 885 | opt-in approval (TTY only) |
| `_needs_sudo()` / `_sudo_ask()` / `_sudo_gate()` | 907 / 927 / 939 | **sudo gate (§6 #13)**: detect `su` patterns, check the ticket (`sudo -n`), without a ticket **one** prompt on the TTY (`sudo -v`, password straight to sudo), with a ticket y/N; the reason ends up in `_sudo_gate_reason` instead of on stdout |
| `tool_bash()` | 960 | deny list → sudo gate/approval → execution with `_run_limited`, `</dev/null`, truncation |
| `tool_list_files()` | 997 | directory listing |
| `tool_append_file()` / `tool_search()` | 1050 / 1067 | wiki workbench (step 1): append-only writes, full-text search (`grep -rIn`, literal/regex, glob, 200-hit cap) |
| `_todo_file()` / `tool_todo()` | 1117 / 1121 | step 2 + addendum: plan under `${_lex_home}/plans/` — **session-independent** (`plan.md`), `done` idempotent, index = display position |
| `_hist_init()` / `_hist_add()` | 1227 / 1244 | step 6: read history `~/.lex/history` (500 entries), `set -o emacs` + `bind` |
| `_html_to_text()` / `tool_fetch()` / `_html_decode()` | 1264 / 1359 / 1355 | step 4: ingest into `raw/<topic>/`, HTML→plaintext via awk, metadata header, collision suffixes |
| `_mem_valid_type()` / `_mem_slug()` | 1470 / 1475 | type whitelist, filename from the heading |
| `_mcp_config()` / `_mcp_argv()` / `_mcp_wait()` / `_mcp_send()` / `_mcp_call()` | 1489 / 1504 / 1517 / 1548 / 1563 | step 9: MCP client for **stdio** — servers from `${LEX_HOME:-$HOME/.lex}/mcp.json` (otherwise defaults), handshake `initialize` → `notifications/initialized` → `tools/call`, answer filtering by `id`, connection timeout separated from read timeout; step 14: `_mcp_send()` detects servers **dead at startup** (coproc fd) and reports "not startable" instead of failing |
| `tool_web_fetch()` / `tool_context7()` | 1715 / 1734 | step 9: crawler excerpt via defuddle (no storage), context7 two-stage (`resolve-library-id` → `query-docs`) incl. library suggestion |
| `tool_browser()` | 1805 | step 22: playwright MCP against system Chrome — navigate/snapshot/click/type by ref (accessibility instead of vision), **no write gate**, output cap |
| `tool_mcp()` | 1892 | step 23: generic MCP access — discovery (tools/list via `_mcp_call … list`) + tools/call, server/tool error messages, output cap |
| `_ddg_parse()` / `tool_web_search()` | 1918 / 1983 | step 10: DuckDuckGo evaluation in awk (title/URL/snippet, `uddg=` decoding via a byte table, entities, max 10 hits) plus `curl` with `LEX_SEARCH_URL` |
| `tool_mem_add()` / `tool_mem_list()` / `tool_mem_search()` | 2001 / 2031 / 2053 | memory (spec §6.4) |
| `dispatch_tool()` | 2072 | case map name → tool (17 entries) **+ mandatory JSON object as the argument** (otherwise the jq error message lands in the context); **span instrumentation (step 26)**: `_t0` before the case, `_rc=$?` after `esac` + `span_log … "$_ok"` + `return "$_rc"` |
| `_palette_init()` / `_prompt()` | 2221 / 2237 | **step 14**: color palette via variables (`NO_COLOR`/`TERM=dumb` → empty), prompt `lex>` only colored on a TTY |
| `_hint_args()` | 2251 | compact argument hint for the trace (70 chars) |
| `_spin_start()` / `_spin_stop()` | 2264 / 2285 | step 6: `⏳ thinking …` spinner on stderr, only after 250 ms, a flag file prevents whitespace; `trap … EXIT` (step 14) |
| `_trace_result()` / `_trace_reasoning()` / `_trace_rule()` / `_trace_line()` / `_trace_hud()` | 2304 / 2328 / 2348 / 2353 / 2359 | step 6 + 13 + 14: tool return (8 lines/600 chars, `↳` cyan-dim), `⚙ thinking:` block (header dim-magenta, content **grey `90`** + indent instead of italic), separator, `⚙ tool args` (name bold cyan), HUD — all via the palette |
| `_md_render()` / `render_markdown()` | 2374 / 2569 | step 3 + 8 + 13 + 14: markdown light (headings, `**bold**`, `` `code` ``, `[[wikilinks]]`, quotes, warning/error/success/links/list markers, **pipe tables**); step 14: **H1 bold+underline** (instead of "white" → readable on light backgrounds), H2 bold cyan, H3 cyan, `NO_COLOR`/`TERM=dumb` → raw |
| `run_turn()` | 2575 | **the loop**: user → API → parse → at `tool_count==0` print and `return 0`, otherwise run the tools and continue; writes `reasoning` only into the session; step 14: **guard** on invalid/empty API answers (context stays intact) |
| `server_hint()` | 2724 | port check via `ss` at REPL start — **no** HTTP request; collect the ss output first (pipefail/rc 141, step 14) |
| `cmd_status()` | 2739 | `/status` display (model, API, tools, session, memory, turns) |
| `agent_loop()` | 2769 | REPL (`while [[ -t 0 ]]`), slash commands `/status`, `/help`, prompt via `_prompt()` |
| `oneshot()` | 2804 | stdin → `run_turn` (also `/status`, `/help`) |
| `install_lex()` | 2820 | create `~/.lex/` (`mem/`, not `mem_net/`) + settings template |
| `usage()` | 2840 | help incl. security note |
| `cmd_eval()` | 2888 | **trace-level report** over `spans.jsonl`: count, total duration, failure verdict, per-tool aggregation, latest 10 spans; entry point `lex --eval [file]`, documented in `--help` |
| `main()` | 2924 | `--oneshot --approve --eval --status --install --version --help` |
| `_wiki_dir` (`LEX_WIKI_DIR`) | 42 | root of the project wiki, default `~/.lex/wiki`, visible in `/status` |

**Loop invariant**: the loop is never rewritten — mechanisms come on top (learn-claude-code s01/s02).

### Side tool `tools/llama-proxy.sh` (since 2026-09-28)

Debug layer between lex and the llama-server — shows what goes **in** and **out**:

```bash
LEX_PROXY_UPSTREAM=http://127.0.0.1:8080 ./tools/llama-proxy.sh start 24480
LEX_API_URL=http://127.0.0.1:24480/v1/chat/completions ./lex --oneshot   # test lex against it
./tools/llama-proxy.sh show 1     # Nth request. Request AND response raw + pretty
./tools/llama-proxy.sh tail 20    # traffic.log
./tools/llama-proxy.sh status | stop
```

| Log file | Content |
|---|---|
| `.proxy/traffic.log` | one line per exchange: status, bytes, duration, `model/msgs/roles/max/rb/tools`, `finish/content/reasoning` |
| `.proxy/<id>-in.json` + `-pretty.json` | raw request or indented |
| `.proxy/<id>-out.json` + `-pretty.json` | raw response or indented |
| `.proxy/<id>-headers.txt` / `-rsp-headers.txt` | request headers, upstream headers |
| `.proxy/handler.err` | errors of the per-request handler |

Rules: port **never 8080** (rejected), bind **127.0.0.1 only**, upstream from `LEX_PROXY_UPSTREAM` (default `http://127.0.0.1:8080`), state in `$LEX_PROXY_DIR` (default `./.proxy`, gitignored). A `curl` error against the upstream yields **HTTP 502** + `PROXY-ERROR` in the log.

---

## 6. Known bugs / open fixes

### Blocking for "done"
| # | Location | Problem | Fix | Status |
|---|---|---|---|---|
| 1 | `test/run_all.sh:31-33` | 3 test files do not exist → `run_all.sh` always red | write `test_input.sh`, `test_tools.sh`, `test_loop.sh` | ✅ 2026-09-28 |
| 2 | `test/run_all.sh:36` | `printf '%s\n' "PASS: %d …"` → prints `%d` **literally** | `printf 'PASS: %d  FAIL: %d  TOTAL: %d\n' "$PASS" "$FAIL" "$TOTAL"` | ✅ 2026-09-28 |
| 3 | `lex:376-383` | **`finish_reason` never checked** → at `length` (truncation) a cut-off tool call is treated as "done" → the known "I start … and stop" | evaluate `finish_reason`; on `length` warn/nudge instead of `return 0` | ✅ 2026-09-28 |
| 4 | `lex:211` | `curl --max-time 300` too short (4096 tok @ 11–24 t/s ≈ up to 370 s) | `--max-time 900` or derive from `max_tokens`/ctx | ✅ 2026-09-28 |
| 5 | `lex:38` | `max_tokens=4096` + reasoning budget 1024 share the budget → truncation | raise (e.g. 8192) or clarify the budget logic | ✅ 2026-09-28 |

### Portability / correctness
| # | Location | Problem | Fix | Status |
|---|---|---|---|---|
| 6 | `lex:293` | `tool_bash` had **no `</dev/null`** (original spec §6.3) → interactive commands hang | `bash -c "$command" </dev/null` | ✅ 2026-09-28 (test 17) |
| 7 | `lex:298` | `output+="\n…"` produced a **literal** `\n`, no line break (confirmed with `od`) | `$'\n…'"${len}"' Bytes …'` | ✅ 2026-09-28 (test 18) |
| 8 | `lex:30/42/59` | `realpath -m`, `readlink -f`, `timeout` are **GNU tools** → possibly missing on macOS (Bash 3.2), iSH | fallback chains `_abs_path()` (realpath → readlink → `cd` resolution) and `_run_limited()` (timeout → direct call), guard at the script path | ✅ 2026-09-28 (test: 4 checks) |
| 9 | `lex:773` | `install_lex` created `mem_net/`, the spec wants `~/.lex/mem/` | renamed + test (`install (mem/ created)`, `no mem_net/`) | ✅ 2026-09-28 |
| 10 | `lex:71/114` | `LEX_MOCK_FILE` was consumed **in place** (destroyed the source file) | shadow copy under `~/.lex/mock/` (`_mock_shadow()`), only renewed when the source is newer → sequence survives across runs, source intact | ✅ 2026-09-28 (test: 3 checks) |

### Fixed 2026-09-28 — test harness HTTP path (was never executed)
`test_http.sh` was **not** registered in `run_all.sh` and failed twice over. Four defects, all found and fixed in this task:

| Location | Problem | Fix |
|---|---|---|
| `test/fake_server.sh` | `ncat --listen` **without `-k`** accepts exactly ONE connection and dies — the port wait (`nc -z`) consumed it → afterwards `curl: rc 7` | `-k` + port wait check |
| `test/fake_server.sh` | handler works in **line mode**: even `nc -z` probes would pull a response line → the test got `DEFAULT` instead of the intended answer | read request line/headers, only take a line on `POST` |
| `test/fake_server.sh` | `echo PID; wait …` → the command substitution `FAKE_PID="$(fake_server.sh …)"` only returns at EOF → the caller hangs | detach ncat, print the PID, **exit immediately**; handler/lock next to the script file (= in the tester's TMP) |
| `test/fake_server.sh` | **`Content-Length` in chars instead of bytes** (`${#body}`) → with `ü` the limit was 1 byte short, curl cut the JSON → `jq: invalid JSON text passed to --argjson` → "Empty answer from the model" | `wc -c` |
| `test/test_http.sh` | 2nd response line **invalid JSON** (extra `}`) | corrected (permutation proven: `jq -e`) |
| `test/test_http.sh` | second start only set `LEX_API_URL`, but `call_api()` read `_api_url` set at `source` time → turn 2 addressed the old, already-killed port (`curl: rc 7`) | `lex` reads `LEX_API_URL` **at runtime** (docs: "ENV overrides") |
| `test/test_http.sh` | `cleanup()` removed `rm -rf $TMP` **before** `kill` → the handler was deleted while ncat still needed it | order swapped |
| `test/run_all.sh` | `test_http.sh` missing from the runner list | registered (5th runner back then; **today 6** with `test_features.sh`) |
| — | side finding: backtick in a comment **inside the unquoted heredoc** → when writing the handler `nc -z` ran as command substitution | backticks replaced |

### Security (decision 2026-09-28)
| # | Problem | Decision / fix | Status |
|---|---|---|---|
| 11 | `safe_path` only protects the file tools — **`tool_bash` bypasses everything** → the sandbox is cosmetic | **hard deny list in `_bash_denied()`, ALWAYS on** (rm -rf on `/`/`~`/`.`, `mkfs`/`wipefs`/`of=/dev/`/`dd … of=/dev/`, fork bomb, `su` (no longer `sudo`, see #13), shutdown/reboot, system processes, `chmod -R 777 /`, `history -c`, `curl\|sh` without a fetcher stays allowed) — 7 patterns + end-to-end in the test | ✅ 2026-09-28 |
| 12 | **No approval gate** (learn-claude-code s03) | **opt-in**: `--approve` or `LEX_APPROVE=1` → `_approve_request()` asks per command, only with a controlling TTY (otherwise refusal). **Without the flag no prompt** → tests stay deterministic | ✅ 2026-09-28 |
| 13 | `sudo` was in the deny list → the agent could do **nothing** with root rights (user task 2026-09-28: "a prompt where I can just type it in") | **gate instead of prohibition**: `sudo` out of the deny list, `su` stays in. `_sudo_gate()` (lex:557) is called in `tool_bash` **in the current shell** — always **exactly ONE** prompt: without a valid ticket `_sudo_ask()` (lex:545) shows the command on the controlling TTY and runs `sudo -v` → **the password goes straight to sudo**, never through lex (no variable, no log, `tool_bash` stdin stays `</dev/null>`); with a valid ticket `_approve_request()` asks y/N. No controlling TTY → refusal. `LEX_SUDO=0` blocks sudo entirely, `LEX_SUDO_APPROVE=0` drops the y/N question with a valid ticket | ✅ 2026-09-28 |

### Fixed 2026-09-28 — debug proxy (`tools/llama-proxy.sh`)

Four defects, all found during self-testing (`test/test_proxy.sh`):

| # | Symptom | Cause | Fix |
|---|---|---|---|
| P1 | `curl: Unsupported HTTP/1 subversion` | status line doubled: `HTTP/1.1 HTTP/1.1 200 OK` — `$status` already contains the version, but `printf 'HTTP/1.1 %s'` was used | `printf '%s\r\n…' "$status"`; also `grep '^HTTP/' \| tail -n1` (the **last** status wins, not `100 Continue`) |
| P2 | `curl: rc 18`, 1 byte missing | body via `$(cat …)` → command substitution swallows the trailing `\n`, `Content-Length` was 1 too large | send header and body separately, body via `cat` |
| P3 | `traffic.log` empty / race | the log was written **after** the answer, but curl already returns on receipt | log **before** the answer (there `rlen` first, otherwise `set -u` abort → "Empty reply") |
| P4 | `status` always showed upstream `8080` | `cmd_status` did not read the stored `proxy.upstream` file | read the file, check the port from it; also: bind `0.0.0.0` → **`127.0.0.1`** |

Test coverage: `test/test_proxy.sh` = 26 checks, the 7th runner in `run_all.sh`; `bash -n` + shellcheck run in CI over `tools/*.sh`.

### Fixed 2026-09-28 — spec features (original spec §6)
| Spec | Feature | Implementation | Test |
|---|---|---|---|
| §6.4 | `mem_add`, `mem_list`, `mem_search` | `lex:1360/1383/1405`, schemas in `_build_tools()`, dispatch, system prompt 5→8 tools, `LEX_MEM_DIR` | `test_features.sh` (10 checks) |
| §6.5 | session JSONL, append-only | `lex:214/231/239` — header line + one message per line, `reasoning_content` as a field; **not** in the context (context protection), `LEX_SESSION=0` switches off | `test_features.sh` (7 checks, incl. "every line valid JSON") |
| §6.6 | `/status` | `lex:1970`/`lex:1987` as a slash command **and** `lex --status`; `/help`; port hint at startup | `test_features.sh` (6 checks) |
| §6.6 | `edit_file` multi-block | `all` argument (`boolean` in the schema), all occurrences via a literal-safe loop (no `${//}`-`&` problem), feedback "n of m" | `test_features.sh` (3 checks) |
| §6.3 | `tool_bash` protection | `</dev/null` + truncation + exit code (2026-09-28) **+ timeout guard + deny list** | `test_tools.sh` + `test_features.sh` |

**Deliberately open (phase 1)**: `truncated` flag as its own response field (deep-research notes §14), Landlock/glob sandbox (§8 E), test the Bash 3.2 baseline (§8 D).

---

### Fixed 2026-09-28 — code review (step 14, P1/P2/P3)
User task: "please optimize it and look over it again entirely, whether you find bugs or places we can optimize". 15 findings, all fixed; line numbers from `lex` (2330 lines at the time).

| # | Location | Problem | Fix |
|---|---|---|---|
| 14 | `lex:580` `_bash_denied` | the rm deny list was substring-based → **`rm -rf -- /`, `rm -Rf /`, `rm -fr --no-preserve-root /`, `sudo rm -rf /`, `xargs rm -rf /`, `timeout 5 rm -rf /` got through** | segment-wise check: `_bash_segments()` (520) + `_rm_targets_catastrophic()` (533) compares the rm target tokens (`/`, `/*`, `.`, `./`, `~`, `~/`, `$HOME`, the real `$HOME`) |
| 15 | `lex:580` | `curl …\|sh\|cat` and `curl … && sh x.sh` bypassed the pipe check (only the **last** segment was checked) | all segments are checked; from segment 2 on a shell word (`sh/bash/zsh/…`) causes a deny; `curl …\|cat` and `curl …\|grep sh` stay allowed |
| 16 | `lex:580` | `su postgres -c id` was missed (only `su -c` as a substring) | `_su_is_command()` (558): `su` must be a command word of a segment (also behind `sudo`/`env`/`xargs` wrappers); `grep su - …` stays allowed |
| 17 | `lex:410` `safe_path` | bare roots (`/etc`, `/usr`, `/var`, `/proc`) and **symlink targets** (`/tmp/etclink/passwd`) got through | roots added to the case list, resolve the symlink target, `cd -P` in the fallback of `_abs_path` |
| 18 | `lex:1233` `_mcp_config` | `cat "${LEX_HOME}/mcp.json"` without a fallback → `set -u` abort when `LEX_HOME` is missing | `${LEX_HOME:-$HOME/.lex}` |
| 19 | `lex:182` `load_config` | non-numeric config values (`LEX_MAX_TURNS=abc`) → arithmetic error in `(( ))`, possibly an endless loop | `_int_or()`/`_float_or()` (158/164) validate after tier 4; `LEX_REASONING_MAX` at runtime |
| 20 | `lex:2054` `run_turn` | an empty/invalid API answer was treated as an "answer" → `_messages` reduced to it, **the whole model context gone** | guard: `.choices` must be an array, otherwise rc 1 + message, context preserved |
| 21 | `lex:1302` `_mcp_call` | MCP server dies at startup → coproc fd gone → `printf`/`read` failed with rc 141 or a `set -u` crash **without any message** | `_mcp_send()` (1288): PID check + group with `2>/dev/null`; `_mcp_wait()` (1258) checks the fd → clear message "server is not startable" |
| 22 | `lex:458` `tool_edit_file` | `mktemp` in `/tmp` → `mv` cross-filesystem (not atomic) and mode **600** instead of the template's | temp file in the target directory + `_copy_mode()` (172); also for `todo done` |
| 23 | `lex:1585` `dispatch_tool` | `args` not validated → the model's jq error message landed as a tool result in the context | require `type == "object"`, otherwise a plain-text error + rc 1 |
| 24 | `lex:2139` `server_hint` | `ss \| grep -q` under `pipefail` → rc 141 → "no server" although one is running | collect the ss output first, then check |
| 25 | `lex:140` `_load_settings` | `max_turns`, `tool_timeout`, `tool_max_output`, `log_dir` were **not** read from `settings.json` | jq readers added |
| 26 | `lex:1719` `_prompt` | the prompt wrote the color sequence to stdout unconditionally → ended up in pipes/logs | only on a TTY and without `NO_COLOR` |
| 27 | `lex:1746` `_spin_start` | the spinner stayed in the terminal on exit/SIGINT | `trap '_spin_stop' EXIT` |
| 28 | `test/test_tools.sh:40` | shared path `/tmp/safe_err` (violation of test isolation) | `$TMP/safe_err` |

**Palette (step 14, done alongside)**: all sequences run through `_palette_init()` (1703) → `NO_COLOR`/`TERM=dumb` yield empty strings; H1 = bold+**underline** instead of `1;37` (white is invisible on a light background), H3 = cyan instead of bold, thinking content = grey `90` instead of italic `2;3` (italic is not supported everywhere); TTY demo verified via `script … | cat -v`.

### Fixed 2026-09-29 — live test of the integrations (real environment, real LLM turns)

| # | Location | Problem | Solution |
|---|---|---|---|
| L1 | `_mcp_call` / `dispatch_tool` / `run_turn` | every tool iteration ran in a command substitution → own subshell → the coproc MCP session died after every call: navigate→snapshot landed on `about:blank`, refs differed per call ("Ref not found") | new `_mcp_out_var()` (temp file instead of `$(…)`), `run_turn` writes `dispatch_tool` output to a temp file (redirection, no subshell), keep-alive in `_mcp_call` (key `server\|argv`, `kill -0`, restart on config change or server death); needles: session counter over `_mcp_call` **and** `dispatch_tool` |
| L2 | `tool_browser` (ref decay) | playwright-mcp issues new refs after async page events (autocomplete after `fill`, reload after `back`) — old ref → "Ref not found" | new action `wait` (`browser_wait_for`, `text`=seconds) + prompt rule: after back/click/press(Enter) **always a fresh snapshot first**; schema enum + description added, stub `browser_wait_for` |
| L3 | `tool_browser` click/type | playwright-mcp ≥0.0.83 expects `target` (ref id) in addition | args `{target,ref,element[,text]}` — ref/element remain for older versions and the stub |
| L4 | `call_api` | `$body` as an exec argument blows the kernel limit at ~128 KiB (`E2BIG`: "argument list too long") — multi-turn runs push the history up (live turn 3: 34 KB → 88 KB → **140.8 KB**) | body via temp file, `curl -d @file`; needle: 140,000-byte body against the fake server |
| L5 | `tool_browser` / default config | without a CDP endpoint playwright started its own browser per run or did not attach to the running one | `_ensure_browser()` (Chrome service on 127.0.0.1:9222, PID file `$LEX_HOME/browser.pid`, only if the config contains `cdp-endpoint`) + default config `@playwright/mcp@0.0.83 --cdp-endpoint http://127.0.0.1:9222` |
| — | `web_search` (external, not lex-side) | DuckDuckGo serves an anti-bot challenge page → 0 hits, `html.duckduckgo.com` serves an `anomaly` challenge | open: another provider or our own UA — only reported, not fixed |

### Fixed 2026-09-29 — full audit (limit increase + code review waves 1–4)

**G — limits (user: "raise the limits so the agent does not abort on big tasks")**

| # | Location | Problem | Solution |
|---|---|---|---|
| G1 | tier-1 defaults | `max_tokens 8192` + `rb 4096` → `finish=length` on long answers; `max_turns 100`, `tool_timeout 60 s` (far too short at 16384 tokens) | defaults **16384 / 8192 / 200 / 300 s**; nudge limit as its own default (`_default_max_nudges=4`, ENV `LEX_MAX_NUDGES`); curl time `LEX_API_TIMEOUT` (default 1800 s); `--status` shows `nudges` |
| G2 | `call_api` | jq `--argjson m "$_messages"` as an exec argument → E2BIG from 131,071 B → empty body, "❌ API error" (reproduced with 193 KB) | context via `--slurpfile` from a temp file + rc guard; curl `--max-time "${LEX_API_TIMEOUT:-1800}"` |
| G3 | `append_tool_message` / `append_message` / `setup_messages` | jq arguments without an E2BIG guard → broken protocol (tool_call without an answer); oversized wiki/system prompt → empty start context | 100,000-byte cap before jq + fallback placeholder; wiki cap in `setup_messages` |
| G4 | `dispatch_tool` result | tool outputs without a central cap (mem_*, todo, list_files …) landed untruncated in the context | central cap via `_tool_max_output` before `_trace_result`; needles: `_max_nudges=1` abort, test_http block6 with 2 × 100,000 B |

**R — code review (sub-agent, P1/P2/P3)**

| # | Location | Problem | Solution |
|---|---|---|---|
| R1 | `_rm_targets_catastrophic` | `rm -rf ${HOME}`, `"$HOME"/.`, `~/…/.` slipped past the exact tokens → home wipe possible | prefix check against the home root (literal **and** expanded; blocked only the root plus .-/..-components, subtrees like `~/project` stay allowed) |
| R2 | `_bash_denied` (download) | `curl\|sudo sh`, `\|env sh`, `\|nohup sh`, `bash <(curl…)`, `source <(curl…)`, `eval "$(curl…)"`, `curl … & sh f.sh` bypassed the pipe check | wrapper skip (like `_su_is_command`), direct execution/process substitution forbidden, `&` as a segment separator; false-positive protection (`diff <(…)`) |
| R3 | `tool_web_fetch` / `tool_context7` | `$( _mcp_call … )` in a subshell → coproc session and NEXTID counter broke | `_mcp_out_var` (main shell, temp-file redirection) |
| R4 | `tool_mem_add` | filename only second-precision → a second entry in the same second overwrites the first | collision loop with a `-N` suffix |
| R5 | `tool_edit_file` | `$(cat)` strips all trailing newlines, `printf '%s\n'` adds exactly one back → file end corrupted | count the original line endings and reproduce them faithfully |
| R6 | `tool_write_file` | not atomic (direct write), new files would keep mktemp-600 | temp file in the target directory + `_copy_mode` resp. `0666 & ~umask` + `mv` |
| R7 | `main` | `--approve` only worked at position 1 | flags in any order; second command → clear error |
| R8 | `safe_path` | `~/x` ended up as `$PWD/~/x` (realpath has no tilde) | tilde expansion before `_abs_path` |
| R9 | `_mcp_call` | the shared `mcp.err` was overwritten by every server start → error messages went nowhere | own error file `mcp.<server>.err` |
| R10 | `agent_loop` | without a TTY (`echo "question" \| lex`) it silently swallowed the input (the REPL loop never ran) | non-TTY → `oneshot` path |
| R11 | `_ensure_browser` | dead PID file / living Chrome without an open port → double start ("Profile in use") | PID check: dead → remove the file, alive → wait for the port query, otherwise report |
| R12 | `test_*.sh` | `source lex` without an error guard (syntax error → follow-up errors unclear); test_http block6 did not cover G2 | `\|\| exit 1` in 4 runners; block6 with a second 100-kB message |

**TEST (+29 → 514)**, `lex` 2683 → **2884 lines** — **✅ VERIFY 2026-09-29**

### Open (P3 — deliberately not built, order/scope)
| # | Location | Problem | Assessment |
|---|---|---|---|
| O1 | `_md_render` | table with `\|` inside `` `code` `` breaks the column width | cosmetic, medium effort — next opportunity |
| O2 | tools (`%.70s`, truncation) | byte truncation can end in the middle of a multi-byte char (locale-dependent) | marginal; `cutv` in the tables is already UTF-8-safe |
| O3 | `_mock_shadow` | race if two runs write the same `LEX_MOCK_FILE` | only tests affected, runs are serial |
| O4 | `lex:21` (`set -u`) | without `HOME` lex aborts (`HOME: unbound variable`) | intent or a default `$HOME` fallback? open question to the user |
| O5 | `call_api` | no retry on 5xx/dropped connection | phase 1 |
| O6 | context management | no compaction/summarization — over long sessions `_messages` grows until the server refuses (ctx 262144; E2BIG is caught by G2, the ctx limit is not) | deliberately phase 3 (limits report 2026-09-29); only relevant once sessions really get long |

## 7. Next steps (in order)

**Working method**: cycle B from §0.1, one task at a time, tick off the DoD (§0.1 E). Do not jump.

**Parallel (its own task, do not interrupt the build):** §8 A — model tool-call benchmark. It decides whether the harness can carry the model at all.

1. **Bug 1+2**: write tests (`test_input.sh`, `test_tools.sh`, `test_loop.sh`), fix the `run_all.sh` printf → `run_all.sh` green — **✅ done 2026-09-28**
2. **Bug 3+4+5**: `finish_reason` check + `--max-time` + `max_tokens` → fixes the "abort after announcing" finding — **✅ done 2026-09-28**
3. **Bug 6+7**: `tool_bash` (`</dev/null`, `\n`) — **✅ done 2026-09-28**, plus the 9 defects of the HTTP test path (§6 "Fixed 2026-09-28") and `test_http.sh` in `run_all.sh`
   - Rest from §6: **#8** (GNU guards), **#9** (`mem_net`→`mem`), **#10** (mock shadow) — **✅ done 2026-09-28**
4. **Session JSONL** + `mem_*` tools + `/status` + `edit_file all` (spec §6.4/§6.5/§6.6) — **✅ done 2026-09-28**
5. **Security** (§6 #11/#12): hard deny list in `tool_bash` + opt-in `--approve` — **✅ done 2026-09-28** (decision: deny globs always, approval gate only opt-in)
6. **CI**: `.github/workflows/ci.yml` (`bash -n`, `shellcheck`, `run_all.sh` with mock, hygiene check) + `shellcheck` installed locally — **✅ done 2026-09-28**
7. **Docs**: `README.md`, `CHANGELOG.md`, `LICENSE` (MIT) — **✅ done 2026-09-28**
8. **Initialize the git repo** + commit + tag `v0.1.0` — **✅ done 2026-09-28** (`46c64c0`)

**Docker (former step 6)**: ⛔ **dropped** — user decision 2026-09-28: "lex has nothing to do with Docker".

9. **Debug proxy** `tools/llama-proxy.sh` + `test/test_proxy.sh` (26 checks, 7th runner) + live test over port 24480 → `rb=4096` confirmed live — **✅ done 2026-09-28** (4 defects P1–P4 documented in §6)
10. **Step 1 — wiki workbench**: `append_file` + `search` + `list_files(pattern,recursive)` + `LEX_WIKI_DIR` + wiki conventions in the system prompt (+33 checks) — **✅ done 2026-09-28**
11. **Step 2 — planning**: `todo(action=add|done|list)` → `~/.lex/plans/<session>.md` (since the addendum below: `plans/plan.md`, session-independent), slash `/plan`, prompt rule "plan first, then execute, answer only after VERIFY" (+24 checks) — **✅ done 2026-09-28**
12. **Step 3 — rendering**: tool trace `⚙` + HUD `⏱/turn/tokens` (stderr, TTY only or `LEX_TRACE=1`) and markdown light for the final answer (raw without TTY so pipes/tests stay clean) (+16 checks → 190) — **✅ done 2026-09-28**
13. **Step 4 — ingest (`fetch`)**: `fetch(url, topic)` → `<wiki>/raw/<topic>/YYYY-MM-DD-slug.md` with a header per `raw-template.md`, HTML→plaintext via awk (headings, lists, `Text (URL)`, entities, no navigation/script chrome), collision suffixes, http(s) only, 30 s / 5 MB (+32 checks → 222) — **✅ done 2026-09-28**
14. **Step 5 — final REVIEW**: the §5 line map pulled automatically against the code (29 places), numbers consistent across all doc files, diff checked — **✅ done 2026-09-28**, commits `5022bbf` (proxy) + `e02d124` (wiki integration)
15. **Step 6 — interface (A/B/C)**: live feedback (`⏳ thinking …` spinner only after 250 ms, `↳ tool` with indented/capped return, separator), `⚙ thinking:` block for `reasoning_content` (`LEX_SHOW_REASONING`, `LEX_REASONING_MAX`), read input (`read -e` + `set -o emacs` + `bind`, tab = path completion, history `~/.lex/history`, 500 entries) — all stderr-only at a TTY, pure bash (+23 checks → 245) — **✅ done 2026-09-28**, PTY visual check ✓

16. **Step 7 — personality prompt**: block at the top of the system prompt (always English, brief & effective, **never guess** → `<cmd> --help` / `search` / `web_search` / `context7`, errors as material into the log or `wiki/errors/`, wiki = memory) + 3 learning rules; **pitfall solved**: backticks escaped in the double-quoted string (`\``), otherwise bash executes them (+9 → 254) — **✅ done 2026-09-28**
17. **Step 8 — rendering like opencode**: `do_link()` (cyan+underline, URL dim), colors for warning/error/success/separator/list markers and **real pipe tables** (header cyan/bold, grid dim, right-aligned on `:---`, truncation without a broken color sequence, `vlen` counts UTF-8 correctly) (+17 → 271) — **✅ done 2026-09-28**
18. **Step 9 — MCP client (defuddle + context7)**: stdio JSON-RPC session per call, config `${LEX_HOME}/mcp.json`, **+2 tools** `web_fetch`/`context7` → **15 tools**; real servers verified live, `test/fake_mcp.sh` covers the error paths (+34 → 305) — **✅ done 2026-09-28**
19. **Step 10 — web search without a key**: `web_search(query)` over DuckDuckGo HTML, evaluation in awk with redirect/entity decoding, tested offline against a local fixture (+12 → 317) — **✅ done 2026-09-28**

20. **Addendum (2026-09-28) — `todo` session-independent + `lex` callable directly**: `_todo_file()` now delivers `~/.lex/plans/plan.md` (instead of `plans/<session-id>.md`) so the plan carries over sessions like the wiki and `mem_*` — proven with two real child runs and a session switch in the test (+5 → **322**); additionally a symlink `~/.local/bin/lex → <repo>/lex` so `lex` starts in the terminal without an alias — **✅ done 2026-09-28**

21. **Step 13 — readability (user feedback)**: thinking (dim-magenta, italic, indented), tools (bold cyan) and the answer (last, H1 bold white/H2 bold cyan) are now clearly separated; HUD and separator move **before** the answer (+8 → **330**) — **✅ done 2026-09-28**
22. **sudo gate (§6 #13, user task)**: `sudo` leaves the deny list and runs via `_needs_sudo()` → `_sudo_gate()` → (`_sudo_ask()` with `sudo -v` on the TTY | `_approve_request()` y/N); `LEX_SUDO`/`LEX_SUDO_APPROVE` added as config, `su` stays forbidden, system prompt/tool schema/`usage`/`--status` updated (+10 checks, `lex` was 2101 lines then) — **✅ done 2026-09-28**

23. **Step 14 — review + palette (user task "please optimize it and look for bugs, internet welcome")**: 15 findings from a code review implemented — **P1**: deny list now segment-wise (`_bash_segments`/`_rm_targets_catastrophic`/`_su_is_command`: `rm -rf -- /`, `sudo rm -rf /`, `xargs rm -rf /`, `curl …|sh|cat`, `curl … && sh`, `su postgres -c`), `safe_path` blocks bare roots and resolves symlink targets; **P2**: `_mcp_config` without `LEX_HOME`, numeric config validation (`_int_or`), guard on an invalid API answer (context stays), `_mcp_send` detects dead servers, `edit_file` temp file in the target directory with mode preservation; **P3**: `dispatch_tool` requires JSON objects, prompt only at a TTY, `ss` check without a pipe, spinner `trap`, `_load_settings` keys, test path `/tmp/safe_err` → `$TMP`. **Palette**: `_palette_init` (NO_COLOR/TERM=dumb), H1 bold+underline instead of white, H3 cyan, thinking grey instead of italic (+46 → **386**) — **✅ done 2026-09-28**

**✅ Phase 0 is therefore COMPLETE** (DoD §0.1 E fulfilled, everything verified).

24. **Step 15 — anti-doubt prompt (2026-09-29, user task "thinking without self-doubt", research-based)**: three rules in the system prompt — **decide firmly** (no self-doubt phrasing about things you checked yourself), **verification via tools** (`bash -n`, `./test/run_all.sh`, `search`, logs) instead of self-introspection, **no doubt loops** (no "are you sure?", after an error → cause/fix/continue). Basis: arxiv 2603.03330 ("are you sure?" flips correct answers 72 vs. 6), arxiv 2506.21285 (self-criticism worthless at 27B → external verification), llama.cpp discussion #12339, Reddit PSA (tools on → overthinking route), "Don't overthink" −23 % tokens. In parallel: the same principles in the agent config and `--reasoning-budget-message` in `ai.sh` (`--reasoning-preserve` stays active, budget stays 4096) (+3 → **389**) — **✅ done 2026-09-29**
25. **Step 16 — workflow fixes from the live test (2026-09-29, user task "perfect workflow")**: 9 live requests in the main test (approval 8 — **consumed 9** because of my budget mistake: run D was planned as 1 request, I set `LEX_MAX_TURNS=2`, truncation produced a 2nd turn via a nudge), then **3 for the follow-up test** (total **12**). Observed: **sudo gate 1A** (exactly one prompt on the TTY, password typed directly in the sudo prompt, continuation in turn 2, password 0× in the log), **anti-doubt confirmed** (immediate `web_search` + voluntary `web_fetch` verification, no doubt formulas). Built: **P2** — `finish_reason=length` **and** an empty answer get at most 2 nudges with `_rb_override=0` (`call_api` sends `reasoning_budget_tokens: 0` for that) — before, reasoning ate all tokens again in the nudge turn (cause of the "empty answers"); after 2 nudges an **existing partial text** is rendered (the follow-up test: the nudge turns delivered 195–214 bytes the old path would have discarded — the actual empty-answer gap), only with truly empty content does it exit with rc 1 instead of spinning until `max_turns`; **P3** — `_spin_start()` only on a real TTY (`[[ -t 2 ]]`, even with `LEX_TRACE=1`) → no `\r` repaints in pipes/logs; **P4** — default `temperature 0.1 → 0.7`; **max_turns 50 → 100** (user: do not stop because of limits; the live abort came from my test limit `LEX_MAX_TURNS=2` anyway). **Follow-up results:** rb=0 confirmed live in the request body (proxy log), server budget message visible (= E applies), spinner garbage 0, abort path working. **Follow-up test 2** (2 requests, approval "yes, 2 requests"): `rb=0` confirmed live in the body, turn 1 empty → nudge, turn 2 produced **578 bytes** of visible text that hung on the test cap `LEX_MAX_TURNS=2` → **third gap of the same class**: the max-turns abort also renders the existing partial text instead of discarding it (`pending` in `run_turn`), otherwise every abort path would be an "empty answer". Tests: spinner test moved to a `script` PTY, 2 rescue tests (+5 → **394**), `lex` 2333 → **2418 lines**, §5 map re-pulled (76/76) — **✅ done 2026-09-29**

26. **Step 17 — wiki learning (2026-09-29, user task "lex should use its wiki, that is important")**: finding — prompt rules present (step 1/7), but (a) conditional ("if the task needs background"), (b) wiki content never reached the context (`setup_messages` only embedded the system prompt), (c) `search` default = `.` → in the live test lex searched its own home instead of the wiki, (d) only prompt needles, no behavior test. Built: **O2** — `setup_messages` appends index.md + `tail -n 40` from wiki/log.md (≈ 11 KB ≈ 3k tokens, constant even with a 135 KB log), **O1** — mandatory order ("only after that may you say you do not know something") + collection rule (line to log.md, new artifacts as an article with an index.md line), **O3** — `search` without `path` searches in `$_wiki_dir`, prompt tool description + schema "default: the project wiki". Test finding: the new CWD test failed on an **extra bracket** in the `check` argument (`ok=1)` instead of `1`), the content was correct (+9 → **403**), `lex` 2382 → **2418 lines**, §5 map re-pulled (76/76) — **✅ BUILD 2026-09-29**, **the live verify run surfaced the E2BIG bug** (3 requests: prompt seed YES, 2× `search` with `path=<wiki-root>`, then `read_file log.md` → **135-KB argument** → `jq --arg` failed (Linux max 128 KB/argument) → empty `msg` → `--argjson ""` wiped `$_messages` → empty body → proxy 500 → `❌ API error`). **17b build:** `tool_read_file` now caps like `tool_bash` at `_tool_max_output` (root), `append_message` truncates >100000 bytes **and** catches jq errors, `append_message_json` never overwrites `$_messages` with an empty result (context protection like P2) — reproducer with the real log.md green again (body 68 KB) (+3 → **406**), `lex` 2394 → **2418 lines** — **✅ BUILD 2026-09-29**, **verify rounds (6 requests total, approvals 3+3):** repeat with `MAX_TURNS=3` → rc 0, `read_file` of the 135-KB file went through (= **17b live**), 6× `search`+`read_file` (= O1/O2/O3 live), but only an intermediate sentence (turn limit too tight). **Quality round with `MAX_TURNS=10`:** only **3 requests**, **full correct answer** (append-only → data-loss protection; `append_file` escape-safe; literal default because the **27B model tears `[[Link]]` apart at the regex grammar**) with title+date of the log entry. Trace (reconstructed from the proxy bodies): **`search` hit immediately** (line 404), only `mem_search` reported "No hits" (expected — no memory entry; that message comes without a path from `mem_search` (line 1617/1623), `search` (line 878) always appends `in <path>` — the trace grep had attributed it to `search`) → the model read the entry excerpt proactively with `bash sed` 395–440 → full grounded answer — **✅ done 2026-09-29**

27. **Step 18 — ethical-hacker persona + H-Tools path (2026-09-29, user task "give Lex this prompt" + "hardcode the H-Tools path")**: **prompt** — new block "Role & expertise (ethical hacker)" between identity and personality block, user text verbatim (cybersecurity/network security/penetration testing, expertise list: network security, penetration testing, exploit development, real-time detection, security awareness, reporting, ethical law-compliant approach); **path** — `_htools_dir="${LEX_HTOOLS_DIR:-$HOME/H-Tools}"` (root default, tier 1 in `load_config`), prompt rule "software & tools ALWAYS in ${_htools_dir}" (mkdir -p, never $HOME, never /tmp), `--status` line `htools`, help ENV list with `LEX_HTOOLS_DIR`. **TEST (+12 → 418):** 6 prompt needles (persona parts + path + /tmp ban), default value, env override in a subshell, persona/H-Tools in the mounted context, `--status` and `--help` needle. Test finding: the override test died silently — `source "$1"` let `main "$@"` receive the **file path as the command** → `usage; exit 1` in the subshell; fix `shift` before `source` (in the test script `source` works with the caller's positional params). **VERIFY:** `bash -n` ✓ · shellcheck → **0** · `./test/run_all.sh` → **PASS: 7  FAIL: 0  TOTAL: 7**, **418 checks** (411+7), `lex` 2418 → **2439 lines**, §5 map 40/41 lines re-pulled → **76/76** — **✅ BUILD 2026-09-29**

28. **Step 19 — knowledge package security playbook (2026-09-29, user "teach lex": best practices, tools, combinations, Wireshark, attacker IPs")**: article `wiki/concepts/security-playbook.md` with 5 chapters (ethical framework, tool pipeline incl. combo workflow nmap→Wireshark→Follow-Stream, using Wireshark with a display-filter table, reading Wireshark with TCP handshake + attack patterns, IP check chain with CGNAT/false-positive pitfalls), an index.md line, **5 new raw sources** via `tool_fetch` (WSUG 4.4/3.18/3.19, Wireshark dfref, MITRE ATT&CK T1595) + existing nmap raws as grounding; one 404 on the WSUG chunk (the chapters are called `ChCap…`/`ChUse…` today). Prompt needle: "security/pen-test tasks → first read …/concepts/security-playbook.md". **TEST (+1 → 419)**, `lex` 2439 → **2440 lines**, §5 map re-pulled (76/76) — **✅ BUILD 2026-09-29**

29. **Step 20 — "creating playbooks" taught (2026-09-29, user continuation)**: own wiki article `wiki/concepts/playbook-erstellen.md` (purpose: continuity across session boundaries, consistency, error reservoir, handover; when-criteria; 6-step process; copy-paste template; section table; live example = the security-playbook article), an index.md line, **prompt needle** "maintain your own playbooks …" (threshold ≥2× / ≥3 steps with order risk, obligation: index+log+raw for facts). **GROUNDING:** `tool_fetch` → `raw/playbooks/2026-09-29-runbook-wikipedia.md` (17.8 KB; usable text from line 142: definition, repeatable, "error messages and what to do"); failed atlassian.com runbooks → 404. **TEST (+1 → 420)**, `lex` 2440 → **2441 lines**, §5 map re-pulled (76/76) — **✅ BUILD 2026-09-29**

30. **Step 22 — browser control via Playwright-MCP (2026-09-29, user: "no restriction for lex, I trust it")**: new tool `browser(action, url?, ref?, element?, text?, key?, index?)` with navigate|snapshot|click|type|press|back|tabs|close — workflow after **accessibility snapshot** instead of screenshot (model `Ternary-Bonsai-2-27B` is text-based, no vision → "seeing" = refs from `browser_snapshot`), **no write gate** (full user trust, all actions free). Default config: `playwright` → `npx -y @playwright/mcp@latest --browser chrome` (**system Chrome, no download**). Prompt: tool list line + cycle rule (navigate → snapshot → ref → click/type, then log). `test/fake_mcp.sh` extended with browser_navigate/snapshot/click/type; **+21 tests** (dispatch happy path, missing ref/url/text, unknown action, stub error path, JSON-object requirement, default config without mcp.json, 15→16 in schema/prompt). Consolidated: plan 22–25 (22 browser → 23 generic mcp tool → 24 desktop `computer-use-linux` → 25 **mandatory Postgres** incl. database installation), Postgres value assessed up front (database currently `inactive`). **TEST (+21 → 441)**, `lex` 2441 → **2528 lines**, §5 map re-pulled (77/77) — **✅ BUILD 2026-09-29**

31. **Step 23 — generic `mcp` tool (foundation, 2026-09-29)**: `mcp(server, tool, arguments?)` — discovery first (tool empty/__tools → **`_mcp_call` in the new mode `list`** = `tools/list`, output "name — description"), then `tools/call` on any configured server. `dispatch` accepts `arguments` as a JSON object **or** a JSON string (fromjson fallback). Without `server` → an error naming the configured server names (from `_mcp_config`). Prompt: 17th tool + order rule. **Effect:** every future server (step 24 desktop, 25 postgres) is only `mcp.json` + a prompt needle — no more code per server. Finding: the __tools apostrophes in the schema's jq single-quote string silently broke `_build_tools` (SC1078, `bash -n` passed!) → without quotes. **TEST (+15 → 456)**, `lex` 2528 → **2581 lines**, §5 map re-pulled (78/78) — **✅ BUILD 2026-09-29**

32. **Step 24 — desktop access `computer-use-linux` (2026-09-29, "full control without a gate")**: server **`@agent-sh/computer-use-linux`** (466★, Wayland-first — exactly right for the GNOME 46/Wayland of this session) installed via `npm i -g` (user-level, no sudo); **`doctor`** → readiness: screenshots/remote-desktop/development-input/AT-SPI ✓ after `setup` (AT-SPI enabled, `can_build_accessibility_tree: true`), window introspection open (**extension installed, enable flag set → activates at the next login**; logout now decided by the user: continue without). **No new lex tool (step 23!)**: only default config `desktop: {command: computer-use-linux, args: [mcp]}` + mcp description + prompt rule ("desktop tasks: first `__tools`, then read state → act"). Live proof: `computer-use-linux apps` → real AT-SPI tree (gnome-shell), rc 0. **TEST (+8 → 464)**, `lex` 2581 → **2583 lines**, §5 map new (78/78) — **✅ BUILD 2026-09-29**

33. **Step 25 — Postgres (mandatory, 2026-09-29, "DB + MCP without sudo")**: **25a** PostgreSQL **16.15 user-space** under `~/.lex/pg` — Ubuntu debs unpacked with `dpkg -x` (initdb/psql run over relocation, libpq5+postgresql-client-16 pulled along), own socket, 127.0.0.1:5432 only, **no sudo, no password** (the planned apt/sudo route dropped entirely: no sudo ticket); DB `lex` (trust) proven with INSERT/SELECT, run via `~/.lex/pg/start.sh`. **25b** MCP **`@bytebase/dbhub`** (2 tools `execute_sql`/`search_objects`, 1.4k tokens, **read/write**, stdio — no HTTP port) installed with **Node 22 (nvm, user-level)**, because dbhub needs `node:sqlite` ≥22.5 and the npm binaries would use `env node`=v20 → wrapper `~/.lex/pg/dbhub.sh` execs node22. **25c** again only config+prompt (step 23 pays off): default config `postgres` (dbhub.sh + `--dsn postgres://lex@127.0.0.1:5432/lex?sslmode=disable`), mcp description + prompt rule "database tasks: first `__tools`, then SQL; only the own lex DB". **25d real proof manual:** `tool_mcp postgres __tools` → real tool list of dbhub, `execute_sql INSERT` → `success:true` and a psql counter of 2. **TEST (+8 → 472)**, `lex` 2583 → **2585 lines**, §5 map re-pulled (78/78) — **✅ BUILD 2026-09-29**
34. **Live test of all integrations (2026-09-29, user approval "everything incl. real LLM turns")**: carried out on the real environment (Wayland/GNOME, system Chrome, user-space Postgres). **Live proofs:** Postgres ✓ (`tool_mcp postgres`: `__tools` → real dbhub list, `execute_sql` CREATE/INSERT/UPDATE/SELECT → count `live`=4, `search_objects`), Desktop ✓ (`list_apps` → real AT-SPI tree), `web_fetch`/defuddle ✓ (Wikipedia plaintext), `context7` ✓ (curl docs), browser full cycle in **one** session: navigate → snapshot → type+Enter (search lands on `/wiki/Pipeline`) → click (ref from a fresh snapshot → `Brian Fox`) → back → wait → snapshot → tabs/close. **Three real LLM turns** over `./lex --oneshot` against 8080: (1) browser navigate+snapshot → title + H1 with correct refs and the ref rule obeyed, (2) Postgres discovery+SQL with self-correction ("live" instead of the guessed table), (3) browser turn with **five** dispatches up to the click — only this turn exposed L4 (E2BIG). **Findings L1–L5 fixed** (§6 "Fixed 2026-09-29"): MCP session subshell, ref decay (+`wait` action + prompt rule), `target` schema, `curl -d @file` against E2BIG, Chrome CDP service; `web_search` = external DDG anti-bot finding (only reported). **TEST (+13 → 485)**, `lex` 2585 → **2683 lines**, §5 map unchanged (78/78) — **✅ LIVE 2026-09-29**
35. **Full audit: limits + code review (2026-09-29, user: "check that everything works as planned, raise the limits so the agent does not abort on big tasks, find and fix bugs in the whole code")**: inventory of all abort/truncation points (limits report) + sub-agent code review (bug report), then **four waves** carried out — wave 1 limits/E2BIG (G1–G4), wave 2 security P1s (R1–R2: home-deny gap, download bypasses), wave 3 P2s (R3–R7), wave 4 P3s (R8–R12). Every wave: `bash -n` + shellcheck + `run_all.sh` green. Details in §6 "Fixed 2026-09-29 — full audit". `--status` now shows `nudges`; smoke: `budget 8192 max_tokens 16384 max_turns 200 timeout 300s`. Deliberately **not** built: compaction (→ §6 open O6). **TEST (+29 → 514)**, `lex` 2683 → **2884 lines** — **✅ VERIFY 2026-09-29**

36. **Step 26 — observability: span-level logging + `lex --eval` (2026-09-30, source: the wiki article `web-intelligence`)**: finding — five of six layers (search, evidence, answer, memory, wiki) existed, the sixth (**observability/evaluation**) did not; no way to see how often a tool ran, how long it took or what failed. Built: `span_log()` writes **one JSONL line per tool run** into `<log-dir>/spans.jsonl` (`ts`, `name`, `args_hash`, `duration_ms`, `ok`) with a jq-less TSV fallback; `_ms_now()` guards the GNU-only `date +%N` (rule C: no GNU-only call without a fallback) and `dispatch_tool()` times every branch, taking `ok` from the branch exit status **after** `esac` (`return "$_rc"` keeps the tool's own status, the unknown-tool branch logs before `return 1`); `cmd_eval()` renders the **trace-level report** (count, total duration, `FAILED: n of m` / `OK` verdict, per-tool aggregation, latest 10 spans) and is reachable as `lex --eval [spans-file]` (documented in `--help`, works without `load_config`). **TEST (+15 → 522 individual; new runner `eval`, 8 runners → 530 checks)**: span_log JSONL/ok, dispatch success + failure path, cmd_eval valid/empty/missing file, `lex --eval` CLI. **VERIFY:** `bash -n` ✓ · shellcheck (single file) = 0 · `./test/run_all.sh` → **PASS: 8  FAIL: 0  TOTAL: 8**, `lex` 2888 → **2992 lines**, §5 map re-pulled — **✅ BUILD 2026-09-30**

## 8. Research agenda (prioritized, status 2026-09-28)

### A. Model capability — BIGGEST RISK
Measure tool-call adherence of **Ternary-Bonsai-2-27B**, 20–50 runs (possibly against a separate test server, **never** the shared port 8080):
- How often valid `tool_calls` JSON? Are **parallel** calls emitted? Behavior at `finish_reason=length`?
- Tool-call stability across multi-turn with `role:tool` returns
- The result decides: keep building the harness, switch the model (e.g. Qwen3-Coder) or adjust the scaffolding

### B. Competition — the gap claim is outdated
The statement "Lex is the only local-first one" is **no longer true**. In the field (not in the old table):
- **apogee** (Go, local-first, Landlock/sandbox, MCP, sessions, Homebrew)
- **whet** (Rust, local-only, 12 tools, SQLite memory)
- **Arterm-CLI** (Node, local-first, permission-gated)
- **localcode**, **codii** (Python, local-first)
- plus established: `simonw/llm`, goose (Block), aider, Open Interpreter
→ Re-assess the gap: the only real differentiator is probably **pure Bash** + **English**. The latter is rather a disadvantage for a show post.

### C. Name & law
- `lex` **collides** with the Unix lexical generator (Debian/OpenBSD: `flex` creates `/usr/bin/lex`) → `install` to `/usr/local/bin/lex` is risky
- Check availability: GitHub repo name, Homebrew formula, domain
- ~~create an Apache-2.0 file~~ → **MIT chosen** (2026-09-28, `LICENSE` present, copyright "ch405canova-sudo")

### D. Portability baseline
Which GNU tools are guaranteed on macOS 14 / Termux / iSH / Pi? Decide Bash 3.2 compatibility (feature-gated) or explicitly set minimum version 4 **and test it**.
→ **Status 2026-09-28**: `realpath`/`readlink -f`/`timeout` have fallbacks (§6 #8); no Bash-4-only constructs in the code. **Open**: actually testing on macOS/Termux/iSH + Bash 3.2.

### E. Security model
allow/deny globs (grok `Bash(...)` syntax), approval gate, Landlock (`eugene1g/agent-safehouse`). Write the threat model: what `bash` must never do.
→ **Status 2026-09-28**: hard deny list (always on) + opt-in approval built. **Open**: glob syntax for allowed paths/patterns, Landlock sandbox, the threat model as text.

### F. Test strategy
~~The mock bypasses `curl` completely → the HTTP path is untested.~~ **✅ 2026-09-28 completed**: fake server over `ncat` (`test/fake_server.sh`), `test_http.sh` in `run_all.sh`, plus golden-file assertions via `LEX_MOCK_FILE`. Open: golden files instead of inline JSON, load/fuzz tests.

### G. Context/tokens
How does Bash count tokens (no tokenizer)? When does compaction kick in? Clarify before phase 3.

---

## 9. Open questions (once, not four times)

1. **Name/repo**: `lex`? `project-lex`? (see §8 C — `lex` is taken)
2. **LLM backend**: local only or also cloud?
3. **CI**: GitHub Actions or self-hosted?
4. **Release timing**: v0.1.0 after the foundation or only after phase 1?
5. **Plugin architecture**: like `wedow/harness` (tools/hooks as executables, any language) or fixed like the reference project?
6. **Persistent agency / multi-player**: no (focused, single-user) — just document it, do not re-discuss
7. ~~**`reasoning_budget`**: lex 1024 vs. `ai.sh --reasoning-budget 4096`?~~ → **DECIDED 2026-09-28: 4096.** The request field wins, lex therefore overrode the server flag; now in sync. `max_tokens=8192` stays (§6 #5). **Not verified live** — the only approved live request still ran with 1024; the next live test checks it. → **done (confirmed live 4096 on 2026-09-28); raised to 8192/16384 on 2026-09-29** (full audit G1, §2/§4 updated).

---

## 10. Roadmap (short form)

| Phase | Goal |
|---|---|
| **0 (COMPLETE 2026-09-28)** | loop + 8 tools + session/memory + security + 6 test runners + CI + docs + **v0.1.0** (Docker dropped) |
| 1 | SSE streaming, `finish_reason` safeguards, zero-fork hot path, read line, plugin structure, `todo_write` |
| 2 | 24+ tools, sub-agents (explore/plan/review/summarize), read-only mode, parallel tool calls, skills |
| 3 | context compaction, 3-type memory (semantic/episodic/procedural + gate + pass), task system, hooks |
| 4 | HTTP daemon (9655), headless `lex -p --output-format json`, MCP client, background tasks, `stop.md` |
| 5 | session commands (`/resume /rewind /compact /fork`), sandbox (Landlock), eval mode, trace/undo |
| 6 | HN show post, brew/pkg, community, v1.0.0 |

**Reference mechanisms** (learn-claude-code s01–s17): the loop stays constant, everything else is built onto it.

---

## 11. File map

### This repository
| Path | Content |
|---|---|
| `LEX.md` | **this file — the single source of truth** |
| `lex` | the script (2992 lines, 17 tools) |
| `README.md` / `CHANGELOG.md` / `LICENSE` | docs + MIT license (2026-09-28) |
| `ai.sh` | llama-server manager (path-free, env-driven) |
| `install.sh` | interactive installer (deps → `lex --install` → symlinks) |
| `.github/workflows/ci.yml` | CI: `bash -n` + shellcheck + `run_all.sh` + installer smoke test + hygiene |
| `tools/llama-proxy.sh` | **debug proxy** (`start\|stop\|status\|tail\|show`), logs in `.proxy/` |
| `test/run_all.sh` | test runners (**8 runners**: syntax/input/tools/loop/http/features/proxy/eval, green) |
| `test/test_input.sh` … `test_eval.sh` | 8 test files, **530 checks** (522 individual + 8 runner marks) |
| `test/fake_mcp.sh` | minimal MCP server (stdio/JSON-RPC) for steps 9 + 22 + 23 + 24 + 25 |
| `test/fake_server.sh` | fake server (ncat, high port) for the curl path |

### Knowledge base (a separate markdown wiki outside this repository)
```
<wiki-root>/
├── raw/                ← immutable sources (read-only)
└── wiki/               ← compiled articles
    ├── index.md        ✅ clean
    ├── log.md          append-only ops log — this is where entries are written
    ├── analyses/       architecture analysis (historical)
    ├── concepts/       concept articles (pure-bash agent loop, security playbook, playbooks)
    ├── errors/         error learning
    ├── entities/       empty — a legitimate folder
    └── sources/        empty — a legitimate folder
```
- **Link status**: `wiki/` = 0 broken. `raw/` = 7 dead links → **deliberately untouched** (raw is immutable).
- **Path rule**: the wiki project root is `<wiki-root>`, i.e. `raw/…` + `wiki/…`. Relative from `wiki/<topic>/`: `../../raw/…`.
- The wiki is reached via `LEX_WIKI_DIR` (default `~/.lex/wiki`).

---

## 12. Rules (always in force)

The build method is in **§0.1** — that is binding. Only the additions that are not there:

1. **Wiki = working memory, `LEX.md` = project document.**
2. **No hallucinations** — only what is evidenced (`file:line` or an executed command).
3. **Errors are documented, not hidden** → the wiki error log (schema see the wiki conventions).
4. **Everything in English** — code, comments, messages, docs, tests.
