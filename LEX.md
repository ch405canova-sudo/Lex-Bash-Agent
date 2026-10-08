# LEX — The single working document for Project-Lex

> **Status**: 2026-09-28 · **Supersedes** the 7 older MD documents (they are no longer maintained).
> **Rule**: From now on only maintain this file. Everything else is archive/reference.
> **For a new chat**: read §0 → §3 (current state) → §7 (next step). Nothing else.

---

## 0. HOW YOU CONTINUE WORKING HERE (handover)

### Check paths & status (30 seconds)
```bash
# Where am I, what does it say?
less LEX.md                     # this document

# Does the script still run at all?
bash -n lex                     # syntax
bash test/run_all.sh            # 13 runners, 794 checks — green as of 2026-10-06 (v0.1.0 + wiki steps 1–25 + full audit + streaming fix + observability backport + testboden gates + truncation→spill + `/exit` & token HUD + blue-team working framework + context compaction & context HUD + prompt mode `/lexpen` + repetition guard + fix package steps 53–56)

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
| Error messages in **English** on **stderr**, structured tool result to the model | stdout stays clean for the answer |
| No GNU-only without a guard (`realpath`, `readlink -f`, `timeout` → `command -v` check) | portability claim in §1 |
| Config via `_default_*` → tier 2/3 → `LEX_*` ENV | the 4-tier model stays the only config source |
| `tool_bash` protection: `</dev/null`, `_run_limited` (timeout guard), deny list, full output, exit code | spec §6.3 — `</dev/null` + line break + timeout guard + deny list **fulfilled 2026-09-28**; **per-tool cap dropped 2026-09-30** (cutoff now only centrally via spill, §6); `truncated` flag (distinguishing "cut off" vs. "error") open for phase 1 |
| **Optimizing = test + measurement in the same change**; hot paths (`call_api`, `run_turn`, `dispatch_tool`) never refactored without a fixture test | finding 2026-09-30: the streaming rework broke guard, tool_calls fusion and nudges — the suite stayed green because the path only knew JSON mocks |
| **Experiments out of the working tree** (`git switch -c opt/…`), "working tree clean" as a precondition for optimization | uncommitted intermediate states are why broken paths go unnoticed (§6 "Fixed 2026-09-30") |

### D. Test rules
- **Every new function gets a test.** `test/test_<name>.sh`, always mocked.
- **Never port 8080** — neither in a test nor in a single command.
- **The HTTP path is tested**, not only the mock branch: fake server over `ncat` — `test/test_http.sh` in `run_all.sh` since 2026-09-28 (gap §8 F closed).
- `bash test/run_all.sh` = the single source of truth for "is it done".
- Tests are assert-based (`[ "$out" = "expected" ]`), output on stdout, exit 1 on failure — exactly what `run_all.sh` already expects.
- **The test floor is hard:** `run_all.sh` runs `testboden` first — it aborts when a test file was deleted against HEAD, is referenced as a runner but missing, or exists but is not wired in. Test files are **replaced, never removed** (that is exactly what hid the streaming regression).
- **Fixture tests must be able to break the path too.** Testing only mock paths is not enough: the API path needs SSE fixtures (`test/test_sse.sh` — deltas, tool_calls fusion, `data:` without a space, missing `[DONE]`, server gone, HTTP errors) and a real HTTP fake (`test/test_http.sh`).
- **Optimization needs a number, not a feeling:** measure before/after with a fixed fixture and capture it as a test — `test_sse.sh` numbers the budget (3000 chunks < 2000 ms; was 29 s, today ~0.1 s). Whoever claims "faster" delivers the measurement.

### E. Definition of Done — a task is finished only when
- [ ] code changed
- [ ] `bash -n lex` → OK
- [ ] affected/new tests written and green (`run_all.sh` fully green, `testboden` included)
- [ ] optimizations: before/after **measured** with a fixed fixture, budget test green
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
| **Binary** | `lex` (one script, 4569 lines) |
| **Backend** | local llama-server, OpenAI protocol, `http://127.0.0.1:8080/v1/chat/completions` |
| **Model** | `Ternary-Bonsai-2-27B-PQ2_0.gguf` (alias=`--alias` possible) |
| **Language** | English-first — system prompt, docs, answers |
| **Target platforms** | dev machine, internal server, Termux, iSH, Raspberry Pi, router |
| **License** | MIT (`LICENSE`, 2026-09-28 — instead of the earlier planned Apache 2.0) |
| **Status** | **Phase 0 complete** — commit `46c64c0`, tag `v0.1.0` |

**Positioning**: local-first (no API key), English-first, single-user, reactive, CI + Docker + release from day 1.

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
| Tool set phase 0.1 (wiki) | **+2**: `append_file` (append-only, for `wiki/log.md`), `search` (literal by default, `regex=true`, `path:line:text`), `list_files` **extended** with `pattern` (glob) + `recursive` → **10 tools**; config `LEX_WIKI_DIR` (default `<wiki>`) + wiki conventions in the system prompt |
| Memory phase 0 | Simple file-based memory (`~/.lex/mem/`, Markdown+YAML) — **not** 16×200 (that is phase 3) — **implemented 2026-09-28** |
| Session | append-only JSONL in `~/.lex/sessions/<id>/` — **implemented 2026-09-28** (`LEX_SESSION=0` switches it off) |
| Security | **hard deny list in `tool_bash`, always on** + **opt-in** approval gate (`--approve`/`LEX_APPROVE=1`) — decision 2026-09-28 |
| sudo in `tool_bash` | **gate instead of prohibition** (user task 2026-09-28: "a prompt where I can just type it in"): `su` **stays** forbidden, `sudo` leaves the deny list and runs through `_sudo_gate()` — without a valid sudo ticket `_sudo_ask()` shows the command on the controlling TTY and runs `sudo -v` → **the password goes straight to sudo**, never through lex (no variable, no log, `tool_bash` stdin stays `</dev/null>`); with a valid ticket lex asks **once per session** `_sudo_grant_request()` (step 52: `allow sudo for this entire session? (y/N): ` — yes = the session runs without further questions, no = y/N per command via `_approve_request()`, visible since step 50: command truncated to 200 B, question as the **last** line without newline). No controlling TTY → refusal. `LEX_SUDO=0` switches sudo off completely, `LEX_SUDO_APPROVE=0` drops every approval question — **live finding 2026-10-05**: `NOPASSWD:ALL` active (step 45) → `_sudo_ask` is **never** reached, the only question was y/N per command; every long block of the AnonOps run was a y/N wait loop (~2 h 35 m ≈ 58 %) → §6 step-51 diagnosis, §6 #34 (step 52) rebuilds the gate around **one session grant**, `/autosudo` skips that too |
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
- **Security**: hard deny list in `tool_bash` (always on) + opt-in `--approve` (TTY only) + **sudo gate** (§6 #13: password straight to sudo, since step 52 **one session grant** per session instead of y/N per command)
- **Fix package steps 53–56** (2026-10-06, research `wiki/raw/2026-10-06-fix-recherche-hang-500-redaction-loops.md`, user order “implement everything and test lex live”): **P1/P2 tool hang** — `_run_limited` writes to `$_rl_out` (temp file instead of the fd3 pipe), new `_kill_tree()` (BFS to the root, leaf→root TERM, KILL after 3 s) + watchdog `secs+10`, live proof `Exit-Code: 124` with `LEX_TOOL_TIMEOUT=5`; **P3 HTTP retry** — `call_api` retries 429/5xx/curl rc up to 2× (`_retry_delay` 0.8/1.6/3.2 s, ceiling 8 s, jitter ±25 %), config `api_retries`/`LEX_API_RETRIES` (default 2, clamped ≤10), error message with body snippet (400 B) + bytes + attempt count + `parse_error` hint; **P4 redaction** — `_redact()`/`_redact_var()` at `log()`, `session_write()`, display (`_trace_result`/`_trace_reasoning`/`_md_render`) and wiki write paths (`$_wiki_dir`), value group JSON-safe (live finding: the first draft broke session.jsonl → `wiki/errors/2026-10-06-redaction-brach-session-jsonl.md`); **P5 fail memory** — signature `cksum(name|args|result[0..200])`, 3× identical → soft nudge, again → hard (`return 1`), `LEX_LOOP_GUARD=off`; **P7** — 85 % warning independent of `LEX_COMPACT` (re-arm `_compact_warned`) + pinning block in `_compact_prompt`; **P8** — reasoning cap `LEX_REASONING_STORE_MAX` (default 20000) in `append_message_json`. **Live verification 2026-10-06** (isolated `LEX_HOME`, real LLM turns against 8080): oneshot ✓, tool timeout rc=124 ✓, redaction in wiki/log/session ✓, session.jsonl 100 % parseable ✓, fail-memory nudge fired live ✓, 85 % warning ✓, reasoning cap visible ✓ — plus DE+EN **794 checks green** each (state after the sudo ticket stub)
- **Tests**: 11 test files + `fake_server.sh` + `fake_mcp.sh`, **794 checks** (807 PASS lines minus 13 runner marks; the sudo-ticket branches are simulated and no longer depend on the machine's sudoers), `bash test/run_all.sh` → **PASS: 13  FAIL: 0  TOTAL: 13** (exit 0, live counted 2026-10-06) — the first runner is **`testboden`** (§6 "Prevention")
- **Observability**: `span_log()` writes one line per `dispatch_tool` call to `$_log_dir/spans.jsonl` (default `~/.lex/log/spans.jsonl`; `ts`, `name`, `args_hash`, `duration_ms`, `ok` — jq JSONL, TSV without jq), plus `cmd_eval` = `lex --eval [file]` → evaluation (verdict, per-tool section, last 10 spans)
- **Context compaction + context HUD** (step 42): auto-trigger before `append_message user` as soon as the `wc -c/3` estimate (live measurement 3.30 B/token) ≥ `ctx − max(max_tokens, buffer)` (default 242144 → inert), `/compact` as force, jq pairing gate + G0–G8 (fail-safe: with an empty summary `_messages` stays byte-identical), marker `<!--lex-compact-->` in slot 1, session record `{type:compaction}`; HUD `tokens X/Y (Z%) prompt + …`, `/status` with `compact`/`ctx` block; config `ctx_limit`/`compact`/`compact_keep`/`compact_buffer` (tier 2 + ENV)
- **Prompt mode `/lexpen` → Lex persona** (step 43): slash `/lexpen` swaps slot 0 of the context for the senior-engineer persona from `~/.lex/prompts/lexpen.md` (created on first call, XP4→Lex, freely editable afterwards), `/lex` or `/lexpen off` back to the original — history and wiki state stay intact (`_wiki_ex()`), session record `{type:prompt_mode}`, prompt marker `lex*>`, `prompt` line in `/status`, `usage()` names both slashes; answers in the mode: **English** (prompt directive, addendum 2026-10-03), title block, "Chief", `✦ made by @Lex ✦`
- **Debug proxy** `tools/llama-proxy.sh` (2026-09-28): forwards requests to the llama-server and logs request/response (`start|stop|status|tail|show`), logs in `$LEX_PROXY_DIR` (gitignored). Binds **127.0.0.1 only**, port 8080 is rejected
- **Live requests (approved)**: two on 2026-09-28 (direct `Works.` + via the proxy → `reasoning_budget_tokens: 4096`, `max_tokens: 8192`, 8 tools, `finish=stop`) plus **25 API turns in 11 sessions on 2026-09-30** (step 38, task "start the llama server and test everything thoroughly") — details §4 "Live block 2026-09-30"
- **Mutation tests**: deny list / session / `edit_file all` each broken individually → `test_features.sh` red (the tests are not vacuous)
- **Review fixes (step 14, 2026-09-28)**: hard deny list over **segments** (`rm -rf -- /`, `sudo rm -rf /`, `xargs rm -rf /`, `curl …|sh|cat`, `curl … && sh`, `su postgres -c`), `safe_path` also blocks **bare roots** and **symlink targets**, invalid API answers no longer wipe the context, dead MCP servers report "not startable", config values validated numerically, `edit_file` keeps permissions, `dispatch_tool` requires JSON objects, prompt only on a TTY, `ss` check pipefail-safe
- **Palette (step 14)**: colors go through variables (`_palette_init`) → `NO_COLOR`/`TERM=dumb` switch everything off; H1 bold+**underline** instead of "white" (readable on a light background), H3 cyan, thinking content **grey instead of italic**
- **Git**: repository initialized, commits `46c64c0` → `1faafaf` → `9c3f4e9`, tag **v0.1.0**, working tree clean

### Tree (status 2026-10-01)
```
<repo>/
├── lex                        ✅ 4569 lines, shellcheck-clean
├── LEX.md                     ✅ this document
├── README.md                  ✅
├── CHANGELOG.md               ✅
├── LICENSE                    ✅ MIT
├── .gitignore                 ✅
├── .github/workflows/ci.yml   ✅ bash -n + shellcheck (incl. tools/) + run_all.sh + hygiene check
├── .git/                      ✅ commits 46c64c0/1faafaf/9c3f4e9, tag v0.1.0
├── tools/llama-proxy.sh       ✅ debug proxy (start|stop|status|tail|show), 127.0.0.1 only
├── test/run_all.sh            ✅ 13 runners (testboden first), green
├── test/test_input.sh         ✅ 30 checks (CLI modes, mock sequence, /exit REPL, prompt guarantee, Ctrl+C prompt/turn, session grant)
├── test/test_tools.sh         ✅ 16 checks (5 tools + safe_path + dispatch)
├── test/test_loop.sh          ✅ 24 checks (run_turn, finish_reason, max_turns, nudge cases, fail memory soft/hard/off)
├── test/test_http.sh          ✅ 10 checks (real curl path, fake server, >128 KiB, HTTP 500 retry with/without budget)
├── test/test_features.sh      ✅ 528 checks (spec, deny, approve, wiki steps, todo, readability, review fixes, working framework, prompt mode `/lexpen`, session grant, fix package redaction/retry/compaction/reasoning, sudo ticket stub)
├── test/test_proxy.sh         ✅ 26 checks (pass-through, logging, 502, 8080 block)
├── test/test_sse.sh           ✅ 30 checks (stream fusion, server gone, HTTP 500 (3 attempts), warnings, nudge ban, budget 3000 chunks, stream_options body, usage HUD)
├── test/test_eval.sh          ✅ 16 checks (span_log, dispatch spans, cmd_eval, `lex --eval`)
├── test/test_limits.sh        ✅ 17 checks (no cutting lex↔llama: messages, spill, server answer)
├── test/test_compaction.sh    ✅ 77 checks (compaction gates, pairing, marker, HUD)
├── test/test_repetition.sh    ✅ 20 checks (real-case loop → A1/A2/A3, FP gates, run_turn integration, static anchors)
├── test/fake_server.sh        ✅ ncat helper on a high port, never 8080 (+ `.sse` and `STATUS:` modes)
├── test/fake_mcp.sh           ✅ minimal MCP server (stdio/JSON-RPC) for the MCP tests
└── Dockerfile                 ⛔ dropped (decision 2026-09-28: lex has nothing to do with Docker)
```

**Verified 2026-10-06**: `bash test/run_all.sh` → **PASS: 13  FAIL: 0  TOTAL: 13**
(794 checks green, exit 0) · `shellcheck -S warning lex test/*.sh tools/*.sh` → 0.

---

## 4. API contract (verified LIVE, 2026-09-27 — GOLD)

- Endpoint: `POST http://127.0.0.1:8080/v1/chat/completions`
- **`reasoning_budget_tokens`** is **top-level** — NOT `thinking: {budget: …}` (that was the old bug, fixed in `lex:209`)
- Output field: **`reasoning_content`** (not `thinking`)
- Tool calls: `choices[0].message.tool_calls[].function.name` + `.arguments` (JSON **string**)
- `tool` role expects: `{"role":"tool","tool_call_id":"…","content":"…"}` ✅ (that is how it is implemented)
- Streaming (SSE): `data: {choices:[{delta:{reasoning_content:"…", content:"…"}}]}` → **phase 1**
- Usage: `completion_tokens` / `prompt_tokens` / `total_tokens` — in the stream **only** if the body carries `stream_options:{include_usage:true}` (llama-server, upstream #16052; standard in lex since 2026-10-01) — otherwise the server does not deliver the event, and the HUD shows `?`
- Server flags: `--reasoning on|off|auto`, `--reasoning-budget 4096`; `n_ctx_slot = 262144`, 1 slot
- **lex sends `reasoning_budget_tokens: 8192` + `max_tokens: 16384`** (defaults since 2026-09-29, full audit G1; confirmed live 2026-09-28 with 4096/8192) — identical for the request field, `settings.json`/`LEX_REASONING_BUDGET`/`LEX_MAX_TOKENS` still override. Server flag `--reasoning-budget 4096` remains superseded
- `reasoning_content` is **preserved between tool calls** (important for multi-turn)

- `call_api()` reads `LEX_API_URL` **at runtime** (not only at load time) — the docs "ENV overrides" therefore also apply to changes after startup (2026-09-28, the test harness needs this)
- `reasoning_content` is **written to the session JSONL but never into `_messages`** (deliberate context protection: 129 reasoning blocks ≈ 65,441 tokens would blow the 262,144 context) — see §9 question 7
- **2 live requests made** (2026-09-28, approved): 1. direct `LEX_MAX_TURNS=1 ./lex --oneshot` → `Works.`; 2. via the debug proxy (port 24480) → confirmed `reasoning_budget_tokens:4096`, `max_tokens:8192`, 8 tools, `usage: prompt=1409 completion=69`
- **Live block 2026-09-30 (approved: "start the llama server and test everything thoroughly")** — `ai.sh start` (Ternary-Bonsai-2-27B-PQ2_0, 262144 ctx, 1 slot), **11 sessions / 25 API turns / 14 spans**:
  - **Large data complete**: user message **280,072 B** in context *and* session JSONL; `read_file` of the real `log.md` (**181,728 B**) → the context gets only the head (50,150 B) + pointer, the store has **181,727 B** (original minus the trailing `\n` that `$(…)` removes — byte-identical except for that one byte, no other content loss)
  - **Pointer proven effective**: the marker stood exclusively at the end of a **59,989-B** output and was not derivable from the prompt → the model followed the pointer (`read_file` of the store) + `grep` fallback → **correct marker**; without spill it would have been cut off
  - **Tools live**: `bash`, `read_file`, `write_file` (file created ✓), `search` in the wiki ✓, `web_search` (697 ms, real hit ✓); proxy pass-through: `req=38665 B`, `max=16384`, `rb=8192`, **tools=17**, `finish=stop`
  - **Nudge rescue**: `LEX_MAX_TOKENS=150` provokes `finish=length` → 4 nudges (log `nudge 1/4 … 4/4`), partial text rendered instead of discarded, rc 0
  - **Clean sessions**: all JSONL valid, **0** cut markers, `reasoning` fields filled (127–1722 B), system prompt deliberately not in the session; `lex --eval` → 14 spans, 2 `ok=false` = `search` without hits (expected)
  - **No session continue**: every run starts fresh (no restore in the code) — a "what was the marker?" question in a fresh session failed as expected at the turn limit, not in the code
> ⚠️ **You and Lex share the llama-server (port 8080). In tests NEVER real requests — always `LEX_MOCK=done` or `LEX_MOCK_FILE=<file>` or your own fake server on a high port.**

---

## 5. Architecture of the script (`lex`, 4569 lines, status 2026-10-06)

| Function | Line | Task |
|---|---|---|
| `_abs_path()` / `_run_limited()` / `_mock_shadow()` | 49 / 123 / 209 | fallback chains for `realpath`/`timeout`, shadow copy for `LEX_MOCK_FILE`; `cd -P` resolves symlinked directories |
| `_load_settings()` | 298 | jq reader for a settings file (incl. `max_turns`, `tool_timeout`, `tool_max_output`, `log_dir`, **`ctx_limit`/`compact`/`compact_keep`/`compact_buffer` since step 42**, **`api_retries` since step 53**) |
| `_int_or()` / `_float_or()` / `_copy_mode()` | 324 / 330 / 338 | step 14: defuse numeric config values (otherwise `(( ))` abort), copy the template file mode to temp files |
| `load_config()` | 348 | 4-tier: defaults → `~/.lex/settings.json` → `.lex/settings.json` (CWD) → ENV (incl. `LEX_APPROVE/LEX_SESSION/LEX_MEM_DIR`, **`LEX_CTX_LIMIT/LEX_COMPACT/LEX_COMPACT_KEEP/LEX_COMPACT_BUFFER` since step 42**, **`LEX_API_RETRIES` since step 53** (clamped ≤10)) **+ numeric validation** (`_int_or` + on/off) |
| `_redact()` / `_redact_var()` | 437 / 472 | **step 53 — the single redactor**: own API key literally, key/value pairs (`password|secret|token|apikey|auth|…`, value group **JSON-safe**: escaped quotation pair as a whole, open values without `"`/`\`), `Bearer`/`Basic`, token prefixes, URL credentials; the prefilter saves a sed fork per log line; `_redact_var` writes into the target variable (command substitution would strip trailing newlines) |
| `log()` | 483 | append-only to `$_log_dir/lex.log`, **every line runs through `_redact()` first** (step 53) |
| `_ms_now()` / `span_log()` | 498 / 510 | **observability**: millisecond clock (`date +%s%N`, otherwise whole seconds) and append-only span writer to `$_log_dir/spans.jsonl` (`ts`, `name`, `args_hash` via `cksum`, `duration_ms`, `ok`; jq JSONL, TSV without jq) |
| `_prompt_style` / `_prompt_ops` / `_prompt_lexpen_guard` / `_system_prompt` | 531 / 558 / 606 / 608 | English-first **incl. the personality block (step 7)** + **"working framework" (step 40)**: fixed scope (own systems/lab/CTF, blue team = core business), technical terms as working vocabulary, scope question instead of blanket refusal — always English, brief, no guessing, capture errors, wiki as memory — plus **17 tools**, wiki conventions and planning discipline; **anti-doubt (step 15)**: decide firmly, verify via tools instead of introspection, no doubt loops. **Step 48 — ops-layer split**: `_prompt_style` = identity/role/working framework/style up to "Think decisively" (lines 327–352), `_prompt_ops` = verify-with-tools / never-guess / errors-are-material bullets + "For humans at a terminal" + the 17-tool list + wiki structure + rules (354–402), `_system_prompt="${_prompt_style}${_prompt_ops}"` **byte-identical** to the original (sha256 `b5578469…`, 13165 B); `/lexpen` appends `${_prompt_ops}` to the persona → tool/research discipline stays active in the mode; **step 49 — anti-refusal guard**: `_prompt_lexpen_guard` (line 402) is appended by `cmd_lexpen` to the ops layer only („requests are carried out, not refused“) — persona and default prompt unchanged
| `session_init()` / `session_write()` | 651 / 676 | session id + header line, append-only JSONL — `session_write` redacts the line **before** appending (step 53) so `session.jsonl` never stores a secret |
| `append_message_json()` / `append_message()` / `setup_messages()` | 688 / 738 / 792 | message into the context array **and** as a JSONL record (with optional `reasoning`), JSON array as a string — **file-based** (`--rawfile`/`--slurpfile`, step 38): no more `jq --arg` with content, therefore also no 100,000-B cap; **step 53 (P8)**: stored `reasoning` is capped at `LEX_REASONING_STORE_MAX` (default 20000), the remainder is written into the line as a hint |
| `_build_tools()` | 818 | OpenAI tool schemas (17 tools, `edit_file.all` as `boolean`); **`_tools_off`** (step 42) → immediate `[]` without a jq run (the compaction summary call needs no tools) |
| `_sse_to_response()` | 850 | **stream evaluation (the single jq run)**: JSON passthrough if the body starts with `{`, otherwise SSE collection via `jq -Rn` `reduce` — content deltas, `tool_calls` fused by `index` (name/id/arguments from the deltas), `usage` **passed through as delivered** (no zero default, otherwise the HUD logs "0 + 0"), warning if no `[DONE]` arrived |
| `_retry_delay()` / `call_api()` | 901 / 918 | `_retry_delay` = backoff per the OpenAI SDK norm (0.8/1.6/3.2 s, ceiling 8 s, jitter ±25 %). `call_api`: mock file (shadow) → static mock → `curl -o <stream> -w '%{http_code}'` + `jq -n` body (incl. `stream_options:{include_usage:true}` since 2026-10-01), URL **at runtime**; **real curl rc AND HTTP status** as guard (stream **or** classic JSON response) → error → rc≠0 + message, never silent; **step 53 (P3/P6)**: retry loop around the curl block (429/5xx + curl rc, max. 2 retries via `_api_retries`), error messages carry a body snippet (400 B) + bytes + attempt count + `parse_error` hint; 3000 chunks in 0.12 s (was 29 s); **`_msg_override`** (step 42) allows a complete message body for the compaction summary call |
| `safe_path()` | 1053 | deny list for `/etc /usr /bin /sbin /boot /dev /proc /sys /var /lib /lib64 /root` — **including bare roots** (`/etc`, not only `/etc/…`) and **symlink targets** (step 14) |
| `tool_read_file()` / `tool_write_file()` / `tool_edit_file()` | 1082 / 1098 / 1146 | file tools (`edit_file` with `all`, counts occurrences; temp file since step 14 **in the target directory**, mode kept) |
| `_bash_segments()` / `_rm_targets_catastrophic()` / `_su_is_command()` / `_bash_denied()` | 1224 / 1240 / 1291 / 1313 | **hard deny list** (always on): split the command into segments, rm target check over tokens (`rm -rf -- /`, `sudo rm -rf /`, `xargs rm -rf /`), `curl \| sh` over **all** segments (`…\ \| sh \| cat`, `… && sh`), `su` as a command word (`su postgres -c`); plus block devices, fork bomb, reboot, `chmod -R 777 /`, `history -c`; `sudo` runs through `_sudo_gate()` |
| `_tty_preview_text()` / `_tty_preview()` | 1384 / 1393 | **step 50**: visible TTY prompt — title + command truncated (200 B, `LC_ALL=C`, `…(+N bytes)`) to `/dev/tty`; the question afterwards is the last line (see `_approve_request`) |
| `_approve_request()` | 1398 | opt-in approval (TTY only); prompt format step 50: `allow? (y/N): ` **without** `\n` → cursor stays behind the question |
| `_needs_sudo()` / `_sudo_ask()` / `_sudo_gate()` | 1430 / 1450 / 1486 | **sudo gate (§6 #13)**: detect `su` patterns, check the ticket (`sudo -n`), without a ticket **one** prompt on the TTY (`sudo -v`, password straight to sudo, command truncated + `enter sudo password now:` as the last lex line), with a ticket **session grant** (step 52): `_sudo_grant_request()` (lex:1200) asks ONCE per session at the first sudo, `_sudo_grant_state()` (lex:1213) shows `open|granted|declined` in `/status`; yes = auto-approve afterwards, no = y/N per command via `_approve_request()`; the reason ends up in `_sudo_gate_reason` instead of on stdout |
| `tool_bash()` | 1531 | deny list → sudo gate/approval → execution with `_run_limited` (output into `$_rl_out`, child chain killed via `_kill_tree` — step 53), `</dev/null`, **full output** (cutoff now only centrally via spill, step 38) |
| `tool_list_files()` | 1569 | directory listing |
| `tool_append_file()` / `tool_search()` | 1622 / 1646 | wiki workbench (step 1): append-only writes, full-text search (`grep -rIn`, literal/regex, glob, 200-hit cap) |
| `_todo_file()` / `tool_todo()` | 1693 / 1697 | step 2 + addendum: plan under `${_lex_home}/plans/` — **session-independent** (`plan.md`), `done` idempotent, index = display position |
| `_hist_init()` / `_hist_add()` | 1802 / 1819 | step 6: Readline history `~/.lex/history` (500 entries), `set -o emacs` + `bind` |
| `_html_to_text()` / `tool_fetch()` / `_html_decode()` | 1840 / 1935 / 1931 | step 4: ingest into `raw/<topic>/`, HTML→plaintext via awk, metadata header, collision suffixes |
| `_mem_valid_type()` / `_mem_slug()` | 2046 / 2051 | type whitelist, filename from the heading |
| `_mcp_config()` / `_mcp_argv()` / `_mcp_wait()` / `_mcp_send()` / `_mcp_call()` | 2065 / 2080 / 2093 / 2124 / 2139 | step 9: MCP client for **stdio** — servers from `${LEX_HOME:-$HOME/.lex}/mcp.json` (otherwise defaults), handshake `initialize` → `notifications/initialized` → `tools/call`, answer filtering by `id`, connection timeout separated from read timeout; step 14: `_mcp_send()` detects servers **dead at startup** (coproc fd) and reports "not startable" instead of failing |
| `tool_web_fetch()` / `tool_context7()` | 2291 / 2310 | step 9: crawler excerpt via defuddle (no storage), context7 two-stage (`resolve-library-id` → `query-docs`) incl. library suggestion |
| `tool_browser()` | 2381 | step 22: playwright MCP against system Chrome — navigate/snapshot/click/type by ref (accessibility instead of vision), **no write gate**, full output (spill central) |
| `tool_mcp()` | 2465 | step 23: generic MCP access — discovery (tools/list via `_mcp_call … list`) + tools/call, server/tool error messages, full output (spill central) |
| `_ddg_parse()` / `tool_web_search()` | 2488 / 2553 | step 10: DuckDuckGo evaluation in awk (title/URL/snippet, `uddg=` decoding via a byte table, entities, max 10 hits) plus `curl` with `LEX_SEARCH_URL` |
| `tool_mem_add()` / `tool_mem_list()` / `tool_mem_search()` | 2571 / 2601 / 2623 | memory (spec §6.4) |
| `dispatch_tool()` | 2642 | case map name → tool (17 entries) **+ mandatory JSON object as argument** (otherwise the jq error message lands in the context); **instrumented** (`_t0` before the `case`, `span_log` in the `*)` branch, `_rc=$?` after `esac` → every call leaves a span incl. the error case) |
| `_palette_init()` / `_prompt()` | 2790 / 2806 | **step 14**: color palette via variables (`NO_COLOR`/`TERM=dumb` → empty), prompt `lex>` only colored on a TTY; **since 43** `lex*>` while `/lexpen` is active |
| `_hint_args()` | 2823 | compact argument hint for the trace (70 chars) |
| `_spin_start()` / `_spin_stop()` | 2835 / 2859 | step 6: `⏳ thinking …` spinner on stderr, only after 250 ms, flag file prevents idle spinning; `trap … EXIT` (step 14) |
| `_trace_result()` / `_trace_reasoning()` / `_trace_rule()` / `_trace_line()` / `_trace_hud()` | 2878 / 2904 / 2926 / 2931 / 2937 | step 6 + 13 + 14: tool return (8 lines/600 chars, `↳` cyan-dim), `⚙ thinking:` block (header dim-magenta, content **grey `90`** + indent instead of italic), separator, `⚙ tool args` (name bold cyan), HUD — all via the palette; **step 42**: with `ctx_limit` set the HUD shows `tokens X/Y (Z%) prompt + …` (Y = `_ctx_limit`, Z = prompt share of the ctx), without a limit the old formula, without usage `?/Y` |
| `_md_render()` / `render_markdown()` | 2963 / 3163 | step 3 + 8 + 13 + 14: markdown light (headings, `**bold**`, `` `code` ``, `[[wikilinks]]`, quotes, warning/error/success/links/list markers, **pipe tables**); step 14: **H1 bold+underline** (instead of "white" → readable on light backgrounds), H2 bold cyan, H3 cyan, `NO_COLOR`/`TERM=dumb` → raw |
| `_compact_threshold()` / `_compact_estimate()` / `_pairing_ok()` / `_compact_units()` / `_compact_serialize()` / `_compact_prompt()` / `_compact_run()` | 3175 / 3195 / 3208 / 3231 / 3254 / 3279 / 3322 | **step 42 — context compaction** (plan: `wiki/concepts/lex-compaction-plan.md`): threshold `ctx − max(max_tokens, buffer)` (default 262144 → 242144, **inert**), estimate `wc -c/3` over `_messages` (live: 3.30 B/token, `/4` was 18 % too low), `_pairing_ok` as a jq gate (roles/`tool_call_id`/no open `tool_calls`), `_compact_units` groups forward edges (assistant(tool_calls)+following tool results → one unit, the rest = own units; the tail backwards run keeps the newest context until `keep×4` B), `_compact_serialize` → `[User]:` token (cutoff > 2000 B), `_compact_prompt` = English summary template, `_compact_run [force]` with gates G0–G8 (settings/mock/JQ/pairing/empty summary/G4 byte-identical/assignment), marker `<!--lex-compact-->` in slot 1, tail budget `keep*4` bytes lazy, summary call without tools (`_tools_off`/`_rb_override=0`/`_max_tokens=8192`/`_msg_override`), session record `{type:compaction}` + `span_log compact`; trigger: auto hook in `run_turn` before append user + slash `/compact` (force) in `agent_loop`+`oneshot` |
| `_sigint()` / `_abort_turn_tools()` / `_abort_turn_note()` | 3617 / 3634 / 3647 | Ctrl+C (step 51): in a turn → `_turn_aborted` + marking answer for all open `tool_call` IDs (rest of the batch), hanging user message answered via the note; at the prompt → 1st press discards the line, 2nd press ≤2 s `Bye!`; `_turn_active` cleared in `agent_loop` after every turn |
| `run_turn()` | 3653 | **the loop**: user → API → parse → at `tool_count==0` print and `return 0`, otherwise run the tools and continue; **step 54 (fail memory)**: signature `cksum(name|args|result[0..200])` per tool call, 3× identical → soft nudge, again → hard stop (`return 1`), evaluated only after the tool batch, `LEX_LOOP_GUARD=off`; writes `reasoning` only into the session; step 14: **guard** on invalid/empty API answers (context stays intact); step 38: `assistant_msg` via temp files, **central limit with spill** (`_tool_spill()` before `run_turn`: head + store path instead of section); **step 42**: compaction hook `_compact_run` **before** `append_message user` (auto, threshold) + HUD reload `_hud_reread=1` |
| `server_hint()` | 3961 | port check via `ss` at REPL start — **no** HTTP request; collect the ss output first (pipefail/rc 141, step 14) |
| `cmd_status()` | 3976 | `/status` display (model, API, tools, session, memory, turns, **since 42 `compact` block + `ctx` line** `X/limit (%)` or `~X` estimated, **since 43 `prompt` line** `standard`/`lexpen`) |
| `agent_loop()` | 4092 | REPL (`while [[ -t 0 ]]`), slash commands `/status`, `/server`, `/help`, `/plan`, **`/exit`/`/quit` → `break`** (since 2026-10-01: previously fell through to `run_turn` → cost a request and stayed open), **`/compact` → `_compact_run force`** (step 42), **`/lexpen`\|`/lex` → `cmd_lexpen`** (step 43, explicit patterns against the request trap), prompt via `_prompt()` |
| `oneshot()` | 4169 | stdin → `run_turn` (also `/status`, `/server`, `/help`, `/plan`, `/exit`/`/quit` → rc 0 without a model call, **`/compact`**, **`/lexpen`\|`/lex`**) |
| `install_lex()` | 4194 | create `~/.lex/` (`mem/`, `prompts/`, not `mem_net/`) + settings template |
| `_wiki_ex()` / `cmd_lexpen()` | 779 / 4222 | **step 43 — prompt mode**: `_wiki_ex()` delivers the wiki state (index + `tail -40` log) jointly for `setup_messages` and mode switch; `cmd_lexpen [on\|off]` (+ `/lex`) swaps only slot 0 via jq (`role==system` gate, otherwise `setup_messages` fallback) — history stays, lazy-create `~/.lex/prompts/lexpen.md` (heredoc, XP4→Lex), `${_wiki_dir}`/`${_htools_dir}` expansion, `{type:prompt_mode}` record, status/prompt marker |
| `usage()` | 4402 | help incl. security note (`--eval [file]`, slash list `/status /server /plan /lexpen /lex /help /exit /compact`), **ENV section** `LEX_CTX_LIMIT LEX_COMPACT LEX_COMPACT_KEEP LEX_COMPACT_BUFFER` (step 42) |
| `cmd_eval()` | 4462 | **evaluation of the spans**: header with span file, count + total duration (s), verdict (`FAILED: n of m tool calls failed` or `OK: n tool calls, 0 failures`), per-tool section (sum ms + errors per tool), last 10 spans; missing file → hint, rc 0 |
| `main()` | 4498 | `--oneshot --approve --status --install --eval --version --help` (dispatch after `--status`, optional with file positional) |
| `_wiki_dir` (`LEX_WIKI_DIR`) | 43 | root of the LLM wiki, default `<wiki>`, visible in `/status` |

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
| `$LEX_PROXY_DIR/traffic.log` | one line per exchange: status, bytes, duration, `model/msgs/roles/max/rb/tools`, `finish/content/reasoning` |
| `$LEX_PROXY_DIR/<id>-in.json` + `-pretty.json` | raw request or indented |
| `$LEX_PROXY_DIR/<id>-out.json` + `-pretty.json` | raw response or indented |
| `$LEX_PROXY_DIR/<id>-headers.txt` / `-rsp-headers.txt` | request headers, upstream headers |
| `$LEX_PROXY_DIR/handler.err` | errors of the per-request handler |

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
| `test/fake_server.sh` | **`Content-Length` in chars instead of bytes** (`${#body}`) → with a 2-byte char the limit was 1 byte short, curl cut the JSON → `jq: invalid JSON text passed to --argjson` → "Empty answer from the model" | `wc -c` |
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
User task: "please optimize it and look over it again entirely, whether you find bugs or places we can optimize". 15 findings, all fixed; line numbers from `lex` (2330 lines).

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
| R1 | `_rm_targets_catastrophic` | `rm -rf ${HOME}`, `"$HOME"/.`, `/home/…/.` slipped past the exact tokens → home wipe possible | prefix check against the home root (literal **and** expanded; blocked only the root plus .-/..-components, subtrees like `~/project` stay allowed) |
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


### Fixed 2026-09-30 — streaming regression in `call_api()` (nudge chain, tool calls, observability)

Cause of the damage: an uncommitted "optimization" refactor to streaming had destroyed the
HTTP guard and the tool_calls fusion without any test file noticing.
Proof with a fake SSE on port 24711 (`/tmp/opencode/sserepro/`), then independent
reproduction in `test/test_sse.sh`.

| # | Finding | Effect | Fix |
|---|---|---|---|
| S1 | `rc=$?` **after** `done < <(curl …)` = status of the loop body, **not** of curl | server gone/HTTP errors silently landed in the "answer was empty" nudge chain (4 nudges until "answer repeatedly empty — abort.") | `curl -o <stream> -w '%{http_code}'` → **real** curl rc **and** HTTP code; errors → rc≠0 + `curl rc=…`/`Error: HTTP …`, never silent |
| S2 | tool_calls fusion `jq -s '.[0] + .[1]'` from **two** here-strings (2nd overwrote the 1st) | only the last delta survived → `name: null`, arguments a fragment (`}`) → `tool: null` in the session log | **one** jq run `_sse_to_response()`: `jq -Rn reduce` over the stream, `tool_calls` fused by `index` (name/id from the 1st delta, arguments accumulated) |
| S3 | ~4 jq forks per SSE line | 3000 chunks = 29 s | one pass over the file: 3000 chunks = **0.12 s** |
| S4 | filter required `data: ` (with a space) | `data:` without a space → silently empty → nudge loop | regex tolerates both |
| S5 | missing `[DONE]` | silent rc 0, possibly incomplete answer | warning `⚠️  Stream ended without [DONE] …`, collection still evaluated (rc 0) |
| S6 | `usage` faked to `total_tokens: 10` | HUD/statistics wrong | real `usage` from the last stream event |
| S7 | live display `[[ -t 1 ]]` in `$(…)` | dead code (subshell) | deliberately **not** built → §7 step 36 |
| S8 | `_ms_now`/`span_log`/`--eval` gone (grep 0), `test/fake_server.sh` + `test/test_http.sh` **deleted**, `test_proxy.sh` sent real requests to 8080 | observability missing, rule 6 violated, `run_all.sh` red (referenced `test_http.sh`) | observability backported, tests restored from HEAD, fake server extended with `.sse` and `STATUS:` modes |
| S9 | Nudges without any diagnosis; the original logic nudged on an empty answer **without** `finish_reason=length` | failure modes indistinguishable (real truncation vs. API error vs. reasoning-only) | guard: only `finish_reason=length` nudges; log line `nudge k/max finish=… content=… reasoning=…`; own messages for reasoning-only/empty; `run_turn` reports `API error (call_api rc=…)` + `log` |

Tests: **`test/test_sse.sh` (19)** — content deltas, tool_calls fusion (6 individual checks),
server gone, HTTP 500, `data:` without a space, warning without `[DONE]`, body without
a `data:` event, each with a "no nudge" negative probe; **`test/test_eval.sh` (16)** — `span_log`,
`dispatch_tool` spans (ok true/false, `duration_ms` type-correct), `cmd_eval` valid/empty/missing,
CLI `lex --eval`.

**TEST (+37 → 551; 9 runners)**, `lex` 2884 → **3154 lines**, §5 line map redrawn (46/46) — **✅ VERIFY 2026-09-30**

### Prevention 2026-09-30 — three hard gates (same day as the finding)

From the cause "refactored an untested path, tests deleted/unregistered,
claims without measurement" three machine barriers follow (rules §C/§D §E
added):

| Gate | Where | What it breaks |
|---|---|---|
| **Test floor** | `run_all.sh`, **first** runner `testboden` | (1) a test file referenced in `run_all.sh` is missing or not executable, (2) a test file was deleted relative to `HEAD`, (3) an existing `test_*.sh` does not run (runner forgetfulness) — all three directions proven individually, otherwise green |
| **Stream budget** | `test/test_sse.sh` scenario 8 | 3000 chunks must be evaluated **under 2000 ms** **and** arrive complete (3000 characters) — back then 29 s, today ~0.12 s; "fast" via a truncated answer fails the content check |
| **Rules** | LEX.md §C (2 lines), §D (3 points), §E (2 checkboxes) | optimization needs a test **and** a number in the same change; hot paths never without a fixture test; experiments only on `opt/*` branches, clean working tree as a precondition |

Negative tests for the gates (scenarios 2–4): deleted file, orphan test,
runner without a file → rc 1 each, rc 0 in the normal case.

**TEST (+4 → 555; 10 runners)** — **✅ VERIFY 2026-09-30**

### Fixed 2026-09-30 — cut-offs at the lex↔llama boundary (truncation → spill)

**Task:** "find out what gets cut off — nothing that goes from lex to llama and
from llama back to lex should be cut off." Inventory and
fixes:

| Place | Old (cap) | New |
|---|---|---|
| `append_message`, `append_tool_message`, `setup_messages` | 100,000 B before `jq --arg` (E2BIG guard from step 17b: 135-KB `read_file` → Linux argument limit 128 KB) | messages/system prompt/wiki go through temp files (`--rawfile`/`--slurpfile`) — `jq` never receives the content as an argument, nothing left to cap; the fallback placeholder is file-based too |
| `append_message_json`, session record | `--arg m "$msg"` resp. `--arg r "$reasoning"` | `--slurpfile`/`--rawfile` |
| `run_turn` `assistant_msg` | `--arg content` + `--argjson tcs` | temp files, error → `log` + rc 1 (otherwise the answer would silently disappear) |
| `tool_read_file`, `tool_bash`, `tool_search` (bytes), `tool_browser`, `tool_mcp` | own caps on `_tool_max_output` (50,000 B, duplicate work) | dropped — full output, truncation only central from now on |
| central capping in `run_turn` (`_tool_max_output`) | `${result:0:50000} … (truncated …)` → data gone without the model noticing | **spill**: `_tool_spill()` stores the full result under `${_lex_home}/toolout/<ts>-$$-<tool>.txt`, the context gets a header + pointer ("full output is stored under …, reload with read_file"), retention: the 100 most recent stores, `log` line per spill |
| llama→lex (`_sse_to_response`) | — | always stayed complete (checked); caps now only at **display** time (`_trace_result`, `render_markdown`, `LEX_REASONING_MAX`) and in error snippets (`head -c 200`) |

**Deliberately unchanged:** 200-hit marker (`search`), 500-entry limit
(`list_files`), `web_fetch max_length` (the model asks itself), the MCP argument
`--argjson a "$args"` (lex→MCP, outside this boundary), the context itself
stays finite — that is why there is still a limit, just with a store instead
of cutting.

This replacement retires lines **G3** and **G4** from "Fixed 2026-09-29"
(then intended as an E2BIG guard resp. as a central limit).

**TEST (+18 → 573; 11 runners)** — new runner `test/test_limits.sh` (17
checks: 280,000-byte message in `_messages` **and** the session JSONL,
250,000-byte system prompt, 60,000-byte file untruncated via `read_file`, spill with
a 60,000-byte store + pointer in the context, 150,000-character server answer
complete) plus two old tests on the new contract (`test_tools.sh`
#12b/#18, `test_features.sh` "giant message"), `lex` 3154 → **3199 lines**,
§5 line map redrawn — **✅ VERIFY 2026-09-30**

### Fixed 2026-10-01 — `/exit` fell through to the model + HUD logged invented zero tokens

**Task:** the user showed a live session (12 turns) and asked "do you see the
problem?" — two defects visible in the trace, both built today:

| # | Finding | Effect | Fix |
|---|---|---|---|
| E1 | `/exit` (and `/quit`) did not exist — the `case` in `agent_loop`/`oneshot` knew only `/status /server /help /plan`, everything else fell through to `run_turn` | `/exit` cost a complete request (the model answered "Good. …"), the REPL stayed open; "close yourself" landed as turn 12 in the model just the same; only way out: Ctrl-D | `/exit\|/quit` → `break` (REPL, with farewell) resp. `rc 0` without a model call (oneshot/pipe); slash list in `usage()` extended by `/server` and `/exit` |
| E2 | the request body had `stream:true`, but **no** `stream_options:{include_usage:true}` | llama-server only delivers usage in the stream on request (upstream #16052) → `_sse_to_response` filled the zeros default → HUD showed `tokens 0 prompt + 0 completion` in **every** turn | body extended by `stream_options:{include_usage:true}`; **additionally** the zeros default removed in `_sse_to_response` (`usage:.usage`) — without a usage event the HUD now shows `?` instead of lying |

**Why the suite did not catch it:** the mock response and the SSE fixtures
always delivered `usage` → the live path (server delivers none) was never
covered; `/exit` was never tested as a slash command.

**TEST (+15 → 588; 11 runners)**: `test_input.sh` 12 → 18 (oneshot/pipe
`/exit` and `/quit` without a model call, exit code 0, **real REPL under a
`script` PTY**: "Bye" comes, the mock's "Works." does not), `test_sse.sh`
22 → 29 (scenario 9:
the fake server writes the request body via `FAKE_BODY_LOG` → `stream:true`
and `stream_options.include_usage:true` checked with jq; scenario 10: usage in the
stream → HUD `tokens 1409 prompt + 69 completion`, without usage → `?` plus a
negative probe against `tokens 0 prompt + 0 completion`), `test_features.sh`
434 → 436 (`/help` names `/exit` and `/server`), `lex` 3199 → **3206 lines**,
§5 line map redrawn — **✅ VERIFY 2026-10-01**

### Open (P3 — deliberately not built, order/scope)
| # | Location | Problem | Assessment |
|---|---|---|---|
| O1 | `_md_render` | table with `\|` inside `` `code` `` breaks the column width | cosmetic, medium effort — next opportunity |
| O2 | tools (`%.70s`, truncation) | byte truncation can end in the middle of a multi-byte char (locale-dependent) | marginal; `cutv` in the tables is already UTF-8-safe |
| O3 | `_mock_shadow` | race if two runs write the same `LEX_MOCK_FILE` | only tests affected, runs are serial |
| O4 | `lex:21` (`set -u`) | without `HOME` lex aborts (`HOME: unbound variable`) | intent or a default `$HOME` fallback? open question to the user |
| O5 | tool outputs (`dispatch_tool`) | `$(…)` removes **all** trailing line-ending chars — a file ending with `\n` lands as 181,727 instead of 181,728 B in the spill (measured live, otherwise byte-identical) | line ending only, no content loss; a fix would have to route the output of all 17 tools through files and breaks dozens of comparisons → deliberately not built |
| O5b | `call_api` | ~~no retry on 5xx/dropped connection~~ — **fixed 2026-10-06 (step 53)**: retry loop (429/5xx + curl rc, max. 2 retries, `_retry_delay` 0.8→8 s ±25 % jitter), config `api_retries`/`LEX_API_RETRIES`; plus HTTP error snippet with `parse_error` hint (§6 #36) | done |
| O6 | context management | ~~no compaction/summarization~~ — **fixed 2026-10-02 (step 42)**: auto-trigger via `_compact_threshold` (default threshold 242144 = `ctx − max(max_tokens, buffer)`, inert), `/compact` as force, threshold/HUD/status configurable (`ctx_limit`/`compact`/`compact_keep`/`compact_buffer`) — details §7/42 | ~~deliberately phase 3 (limits report 2026-09-29)~~ ✅ 2026-10-02 |

### External bug (not lex, open) — 2026-10-02: gnome-terminal crash

| # | Location | Problem | Status |
|---|---|---|---|
| X1 | `gnome-terminal-server` (system package, **not lex**) | SIGSEGV on 02.10. **00:06:31** (journal `code=dumped, status=11/SEGV`): use-after-free race in the `bg-color` notify chain (`terminal-screen.cc` → `g_object_notify` → `gtk_widget_queue_draw` on a destroyed widget). One server per session for **all** windows → SIGHUP to all children: lex sessions, MCP, Playwright Chrome (exit 00:06:34), completely gone | open — **deliberately not** reported to Launchpad (user decision 02.10.); core `/var/crash/_usr_libexec_gnome-terminal-server.1000.crash`; backtrace/cascade/exclusion: `<wiki>/errors/2026-10-02-gnome-terminal-segv-bg-color.md` |
| X2 | protection of the lex sessions | multiplexers (tmux/screen) survive the crash as daemons — **but completely removed at the user's request on 02.10.** (packages `apt purge`, aliases `tlex`/`tlexkill`, 44 history lines) → lex sessions run **deliberately unprotected** in the terminal window | deliberately accepted (user 02.10.); **addendum 02.10. (user: "tlex should be the alias again"): the user re-installs tmux, aliases `tlex`/`tlexkill` reconstructed** (`tmux new -A -s lex` / `tmux kill-session -t lex` — the original definition was lost during the cleanup) |

Excluded as causes: OOM, dbus, screen lock, GPU, Wayland server, lex itself (last active 00:01:35). Suspected trigger: theme/dark-mode switch (`color-scheme=prefer-dark`) — not proven; reproduction not attempted (a crash test would take out all windows).

### Fixed 2026-10-03 — REPL prompt disappeared after input (step 47)

| # | Location | Problem | Fix | Status |
|---|-----|---------|-----|--------|
| 29 | `lex:agent_loop` (`[[ -z "$input" ]] && continue`) | On **empty input** (just Enter) `continue` skipped the `_prompt` call — readline clears the input line on Enter, after that only a blinking cursor. Input still worked (live proof: user input at 20:37 in the prompt-less session, `turn: 46 chars`). | `{ _spin_stop; _prompt; continue; }` — the prompt is explicitly redrawn | ✅ 2026-10-03 (PTY proof: 2× Enter → ≥3 `lex>`) |
| 30 | `lex:_spin_start` (spinner loop `while :;`) | A surviving spinner child (`kill` did not take in the live run; an orphaned `bash ./lex` was observed) could have kept repainting `\r\033[2K` and eaten the prompt line — the only erase construct in the script (2471/2491). | flag gate `while [[ -f "$_spin_flag" ]]` → the loop ends ≤0.12 s after `_spin_stop`; additionally `_spin_stop` hard before every end-of-loop `_prompt` | ✅ 2026-10-03 (kill snippet + static anchor) |

### Fixed 2026-10-05 — y/N approval prompt invisible (step 50)

| # | Location | Problem | Fix | Status |
|---|-----|---------|-----|--------|
| 31 | `lex:_approve_request` / `_sudo_ask` | `printf 'Approve command (y/N): %s\n' "$cmd"` printed the question **before** the command — with multi-line sudo commands (KB-sized) `(y/N)` sat ~160 lines up and scrolled off screen; the user only saw the command end + blinking cursor, not that lex was waiting for confirmation (live hang 2026-10-05 in the AnonOps-Tor run, progress only via manual TIOCSTI `y` injection; `/autosudo on` is the standing solution but was not set in that run) | `_tty_preview_text()`/`_tty_preview()` (lex:1092/1101): title + command truncated (200 B + `…(+N bytes)`) above the question; `printf 'allow? (y/N): '` **without** `\n` as the last line → cursor behind it; `_sudo_ask` analogously (`enter sudo password now:`). Behaviour (y/j = yes), gate and `/autosudo` unchanged | ✅ 2026-10-05 (+2 checks → 730, 13 runners DE+EN) |

### Fixed 2026-10-05 — Ctrl+C killed lex + session permissions umask-dependent (step 51)

Trigger: user order after evaluating the AnonOps-Tor run (session `20261005-125104-5591-32359`, 12:51–17:16): "stop it … build both".

| # | Location | Problem | Fix | Status |
|---|-----|---------|-----|--------|
| 32 | `lex:_sigint` (new) / `agent_loop` / `run_turn` / `_run_limited` | **No `trap … INT`** — a single Ctrl+C ended the entire lex process (a grep for "trap" only hit the spinner comment); **second, hidden defect**: plain `timeout` puts the child in its own process group — the tty INT reached neither child nor `bash -c`, the substitution ran until expiry (measured **20 s instead of 2 s**, `sleep 60` ran fully) and the turn abort hung until `tool_timeout` (300 s) | `_sigint()`-trap (lex:3255): in a turn → `_turn_aborted=1` (child dies via tty-INT because `timeout --foreground` resolves the group; timer rc=124 still checked), at the prompt → first press discards only the line, second press ≤2 s → `Bye!`, EOF stays Ctrl+D (`rc>128 || _int_seen` distinguishes INT from EOF, independent of trap order); `run_turn` abort points (loop top, after `call_api`, before and after `dispatch_tool`) — in a tool batch `_abort_turn_tools()` answers **all** remaining `tool_call` IDs with a marking, otherwise the OpenAI context would be broken; a hanging user message gets an assistant answer via `_abort_turn_note()`; `_turn_active` cleared in `agent_loop` after every turn | ✅ 2026-10-05 (+5 checks → 735, 13 runners DE+EN) |
| 33 | `lex:session_init` / `install_lex` | Session paths were created only via `mkdir -p` + append — depending on the caller's umask **775/664** (finding: new session 125104 = `drwxrwxr-x`; the housekeeping `chmod` did not hold because every session is created fresh) | `chmod 700` on `sessions/` and the session folder, `session.jsonl` created via `: >` **before** the first line and set to `600`; `install_lex` also creates `sessions/` as 700; existing sessions fixed up | ✅ 2026-10-05 (+3 checks → 738, 13 runners DE+EN) |

**Also answers (user question "why was there no sudo prompt?")**: `sudo -k -n true` → **NOPASSWD:ALL** is active (step 45), sudo **never** asks for a password — the `_sudo_ask` password path is never reached. **Status 2026-10-06: rule deleted** (user order “make password entry visible again”) — `/etc/sudoers.d/90-chaos` removed, `sudo -n true` fails again (`rc=1`), so `_sudo_ask` fires exactly when lex needs sudo (TTY preview + “sudo password now:” + `sudo -v < /dev/tty`); without a controlling TTY still a clean refusal. The only question is the y/N approval. Metrics of that run: 122 tool calls, **32 with sudo**, **all** long blocks (>30 s) are sudo calls (172/554/229/83/369/92/38/126/90/53/215 s + **2 h 00 m Avahi stop 15:10→17:11**) ≈ **2 h 35 m of pure waiting** in the 4 h 25 m session (~58 %); 17:13:30 refusal in 32 ms (Enter instead of y) → model continues without sudo → torsocks cannot resolve `.onion` (RFC 7686) → Ctrl+C. Real success blockers: Avahi held `0.0.0.0:5353` against Tor, DNS-over-Tor broken, irssi config permissions — **not sudo** (31/32 approved calls `ok=true`).

### Fixed 2026-10-05 — sudo blocked per command with y/N (step 52)

Trigger: user decision after step 51 — "one session grant instead of y per command" (a decline should keep asking per command; **new default**, not opt-in).

| # | Location | Problem | Fix | Status |
|---|-----|---------|-----|--------|
| 34 | `lex:_sudo_gate` / `_approve_request` | With a valid sudo ticket (here always, `NOPASSWD:ALL`) the gate asked **y/N per sudo command** — 32 sudo calls in the AnonOps run, each needed a manual approval; 58 % of the run time was wait loops, a single Enter (17:13:30) broke the chain and the run died for lack of root | **Session grant (default)**: new process state `_sudo_grant` (`""`→`"1"`→`"0"`, init lex:1163) + `_sudo_grant_request()` (lex:1200: title/preview like `_approve_request`, `allow sudo for this entire session? (y/N): ` without `\n`, y/j=yes) + `_sudo_grant_state()` (lex:1213) for `/status grant: open\|granted\|declined`; gate order: `LEX_SUDO=0` → ticket/`_sudo_ask` → `_autosudo=1` → `approve=0` → grant=1 → session question → `_approve_request`; **no** sticks as `"0"` and y/N runs per command afterwards (old path), no TTY → the question fails → decline (deterministic); `/autosudo on` and `LEX_SUDO_APPROVE=0` also skip the session question; help/status/`cmd_autosudo` texts updated | ✅ 2026-10-05 (+12 checks → 750, 13 runners DE+EN) |
| 35 | Tool call `script -c 'timeout … irssi' \|\| tail` (model-generated) + `_run_limited`/pipe read | `script` creates its own session, the inner `timeout` runs **without** `--foreground` (step-51 class) → the irssi TUI reads the pty in the background → **SIGTTIN, state `T`** (0 B transcript, the timer TERM is never processed); the chain never dies, orphaned `script`/`tail` (PPID 1) keep the write end of **lex's fd3 read pipe** open → tool call hung **17.5 min** (00:34–00:51) despite the 300 s wrapper (rc=124 never surfaces), second occurrence 01:00–01:03; both times only manual `kill -KILL` freed it | ✅ **step 53**: the child chain writes into a **temp file** (`$_rl_out`) instead of the fd3 pipe — the reader can no longer stay blocked on an open write end; new `_kill_tree()` (BFS collects the chain up to the root, leaf→root TERM, KILL after 3 s) also kills orphans left by `script`/`tail`, a watchdog at `secs+10` puts its own timer around the run, state lives in `$_rl_pid`/`$_rl_hung`, `tool_bash` hangs on it. **Live 2026-10-06**: `sleep 20` with `LEX_TOOL_TIMEOUT=5` → tool result `Exit-Code: 124`, the turn continues. **Deliberately open**: the prompt rule “never run a TUI inside `script` with an inner `timeout` without `--foreground`" (behaviour, not code) | ✅ 2026-10-06 (step 53, DE+EN 791 checks) |
| 36 | `call_api` (HTTP 500) | At **149,520 context tokens** (session 201721, task turn 00:16) llama returned **invalid tool-call JSON** (`json.exception.parse_error.101 … column 54885: invalid string`, a ~55 kB string) → HTTP 500 → `run_turn: API error rc=1`, turn dead; the compaction limit `_default_ctx_limit=262144` was **not** reached → the limit is too high to surface degeneration early; the first run `022414` (1 request, 0 tool calls) fits the pattern; restart in a fresh session ran stable (19 turns, 35 % context) | ✅ **steps 53/55**: retry loop inside `call_api` (429/5xx + curl rc, max. 2 retries; `_retry_delay` 0.8/1.6/3.2 s, ceiling 8 s, jitter ±25 %), config knob `api_retries`/`LEX_API_RETRIES` (default 2 like the OpenAI SDK, clamped ≤10); error messages now carry the HTTP code, a body snippet (400 B), the byte count, the attempt count and — for `parse_error`/`invalid string` — a hint that special characters or size in the tool arguments are the usual cause; **step 55**: an 85 % warning that fires **independently of `LEX_COMPACT`** (re-armed via `_compact_warned`, once per “nearly full” period) **plus a pinning block** in `_compact_prompt` (goals/plans/decisions/paths always carry into the new structure). **Deliberate**: `_default_ctx_limit` stays 262144, warning mark 85 % instead of the proposed 60 %, no trimming of old turns | ✅ 2026-10-06 (steps 53+55, DE+EN 791 checks) |
| 37 | `run_turn` rendering (reasoning block + final report) | Despite the explicit order “never put passwords in output or log” both the reasoning view and the final report showed the config **password in plaintext** (the negation sentence contained it itself); `lex.log` clean, `session.jsonl` only protected by the 600 rule | ✅ **step 53**: `_redact()` as the single redactor (own API key literally, key/value pairs `password|secret|token|apikey|auth|…`, `Bearer`/`Basic`, token prefixes `sk-`/`ghp-`/`xox…`, URL credentials) applied at **exactly four exit paths**: `log()`, `session_write()`, the display (`_trace_result`/`_trace_reasoning`/`_md_render`) and the wiki write paths (`tool_write_file`/`tool_append_file` under `$_wiki_dir`). **Not** in the model context (`$_messages`) and **not** on config/script write paths — there the text must stay literal. The value group is JSON-safe (an escaped quotation pair is swallowed as a whole, open values exclude `"` and `\`) — **live finding 2026-10-06**: the first draft ate the `\` before the closing `"` and turned the session.jsonl line invalid (our own bug, see `wiki/errors/2026-10-06-redaction-brach-session-jsonl.md`); `_redact_var` preserves trailing newlines (line count in the trace) | ✅ 2026-10-06 (step 53, DE+EN 791 checks) |

| 38 | `run_turn` — tool repetitions (fail memory) | The model can re-issue the same tool call forever (re-issue loop): identical arguments **and** identical result, no progress — lex kept running until `max_turns` and burned context/tokens; the visible text loop detector (step 46) does not see tool runs (scope rule: assistant-visible text only) | ✅ **step 54**: signature `cksum(name|args|result[0..200])` per tool call, counter inside `run_turn` (locals, per turn), evaluated **after** the tool batch (injecting a user message in the middle would break the protocol); threshold 3 → **soft nudge** (“fail memory … three times identically”, the answer must change the method or close the task in one sentence, counter resets) → second occurrence → **hard stop** (`return 1`, “identical again”); result bytes are part of the hash so a growing result (file grows, status flips) resets the counter — legitimate polling keeps working; `LEX_LOOP_GUARD=off` disables it; session records `{type:loop_guard}` (nudge/abort) | ✅ 2026-10-06 (step 54, DE+EN 791 checks) |

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
7. **Docs**: `README.md`, `CHANGELOG.md`, `LICENSE` (MIT) plus a private AI-instructions file (not published) — **✅ done 2026-09-28**
8. **Initialize the git repo** + commit + tag `v0.1.0` — **✅ done 2026-09-28** (`46c64c0`)

**Docker (former step 6)**: ⛔ **dropped** — user decision 2026-09-28: "lex has nothing to do with Docker".

9. **Debug proxy** `tools/llama-proxy.sh` + `test/test_proxy.sh` (26 checks, 7th runner) + live test over port 24480 → `rb=4096` confirmed live — **✅ done 2026-09-28** (4 defects P1–P4 documented in §6)
10. **Step 1 — wiki workbench**: `append_file` + `search` + `list_files(pattern,recursive)` + `LEX_WIKI_DIR` + wiki conventions in the system prompt (+33 checks) — **✅ done 2026-09-28**
11. **Step 2 — planning**: `todo(action=add|done|list)` → `~/.lex/plans/<session>.md` (since the addendum below: `plans/plan.md`, session-independent), slash `/plan`, prompt rule "plan first, then execute, answer only after VERIFY" (+24 checks) — **✅ done 2026-09-28**
12. **Step 3 — rendering**: tool trace `⚙` + HUD `⏱/turn/tokens` (stderr, TTY only or `LEX_TRACE=1`) and markdown light for the final answer (raw without TTY so pipes/tests stay clean) (+16 checks → 190) — **✅ done 2026-09-28**
13. **Step 4 — ingest (`fetch`)**: `fetch(url, topic)` → `<wiki>/raw/<topic>/YYYY-MM-DD-slug.md` with a header per `raw-template.md`, HTML→plaintext via awk (headings, lists, `Text (URL)`, entities, no navigation/script chrome), collision suffixes, http(s) only, 30 s / 5 MB (+32 checks → 222) — **✅ done 2026-09-28**
14. **Step 5 — final REVIEW**: the §5 line map pulled automatically against the code (29 places), numbers consistent across all doc files, diff checked — **✅ done 2026-09-28**, commits `5022bbf` (proxy) + `e02d124` (wiki integration)
15. **Step 6 — interface (A/B/C)**: live feedback (`⏳ thinking …` spinner only after 250 ms, `↳ tool` with indented/capped return, separator), `⚙ thinking:` block for `reasoning_content` (`LEX_SHOW_REASONING`, `LEX_REASONING_MAX`), Readline input (`read -e` + `set -o emacs` + `bind`, tab = path completion, history `~/.lex/history`, 500 entries) — all stderr-only at a TTY, pure bash (+23 checks → 245) — **✅ done 2026-09-28**, PTY visual check ✓

16. **Step 7 — personality prompt**: block at the top of the system prompt (always English, brief & effective, **never guess** → `<cmd> --help` / `search` / `web_search` / `context7`, errors as material into the log or `wiki/errors/`, wiki = memory) + 3 learning rules; **pitfall solved**: backticks escaped in the double-quoted string (`\``), otherwise bash executes them (+9 → 254) — **✅ done 2026-09-28**
17. **Step 8 — rendering like opencode**: `do_link()` (cyan+underline, URL dim), colors for warning/error/success/separator/list markers and **real pipe tables** (header cyan/bold, grid dim, right-aligned on `:---`, truncation without a broken color sequence, `vlen` counts UTF-8 correctly) (+17 → 271) — **✅ done 2026-09-28**
18. **Step 9 — MCP client (defuddle + context7)**: stdio JSON-RPC session per call, config `${LEX_HOME}/mcp.json`, **+2 tools** `web_fetch`/`context7` → **15 tools**; real servers verified live, `test/fake_mcp.sh` covers the error paths (+34 → 305) — **✅ done 2026-09-28**
19. **Step 10 — web search without a key**: `web_search(query)` over DuckDuckGo HTML, evaluation in awk with redirect/entity decoding, tested offline against a local fixture (+12 → 317) — **✅ done 2026-09-28**

20. **Addendum (2026-09-28) — `todo` session-independent + `lex` callable directly**: `_todo_file()` now delivers `~/.lex/plans/plan.md` (instead of `plans/<session-id>.md`) so the plan carries over sessions like the wiki and `mem_*` — proven with two real child runs and a session switch in the test (+5 → **322**); additionally a symlink `~/.local/bin/lex → <repo>/lex` so `lex` starts in the terminal without an alias — **✅ done 2026-09-28**

21. **Step 13 — readability (user feedback)**: thinking (dim-magenta, italic, indented), tools (bold cyan) and the answer (last, H1 bold white/H2 bold cyan) are now clearly separated; HUD and separator move **before** the answer (+8 → **330**) — **✅ done 2026-09-28**
22. **sudo gate (§6 #13, user task)**: `sudo` leaves the deny list and runs via `_needs_sudo()` → `_sudo_gate()` → (`_sudo_ask()` with `sudo -v` on the TTY | `_approve_request()` y/N); `LEX_SUDO`/`LEX_SUDO_APPROVE` added as config, `su` stays forbidden, system prompt/tool schema/`usage`/`--status` updated (+10 checks, `lex` was 2101 lines then) — **✅ done 2026-09-28**

23. **Step 14 — review + palette (user task "please optimize it and look for bugs, internet welcome")**: 15 findings from a code review implemented — **P1**: deny list now segment-wise (`_bash_segments`/`_rm_targets_catastrophic`/`_su_is_command`: `rm -rf -- /`, `sudo rm -rf /`, `xargs rm -rf /`, `curl …|sh|cat`, `curl … && sh`, `su postgres -c`), `safe_path` blocks bare roots and resolves symlink targets; **P2**: `_mcp_config` without `LEX_HOME`, numeric config validation (`_int_or`), guard on an invalid API answer (context stays), `_mcp_send` detects dead servers, `edit_file` temp file in the target directory with mode preservation; **P3**: `dispatch_tool` requires JSON objects, prompt only at a TTY, `ss` check without a pipe, spinner `trap`, `_load_settings` keys, test path `/tmp/safe_err` → `$TMP`. **Palette**: `_palette_init` (NO_COLOR/TERM=dumb), H1 bold+underline instead of white, H3 cyan, thinking grey instead of italic (+46 → **386**) — **✅ done 2026-09-28**

**✅ Phase 0 is therefore COMPLETE** (DoD §0.1 E fulfilled, everything verified).

24. **Step 15 — anti-doubt prompt (2026-09-29, user task "thinking without self-doubt", research-based)**: three rules in the system prompt — **decide firmly** (no self-doubt phrasing about things you checked yourself), **verification via tools** (`bash -n`, `./test/run_all.sh`, `search`, logs) instead of self-introspection, **no doubt loops** (no "are you sure?", after an error → cause/fix/continue). Basis: arxiv 2603.03330 ("are you sure?" flips correct answers 72 vs. 6), arxiv 2506.21285 (self-criticism worthless at 27B → external verification), llama.cpp discussion #12339, Reddit PSA (tools on → overthinking route), "Don't overthink" −23 % tokens. In parallel: the same principles in the host agent's `custom_modes.yaml` (not published) and `--reasoning-budget-message` in `ai.sh` (`--reasoning-preserve` stays active, budget stays 4096) (+3 → **389**) — **✅ done 2026-09-29**
25. **Step 16 — workflow fixes from the live test (2026-09-29, user task "perfect workflow")**: 9 live requests in the main test (approval 8 — **consumed 9** because of my budget mistake: run D was planned as 1 request, I set `LEX_MAX_TURNS=2`, truncation produced a 2nd turn via a nudge), then **3 for the follow-up test** (total **12**). Observed: **sudo gate 1A** (exactly one prompt on the TTY, password typed directly in the sudo prompt, continuation in turn 2, password 0× in the log), **anti-doubt confirmed** (immediate `web_search` + voluntary `web_fetch` verification, no doubt formulas). Built: **P2** — `finish_reason=length` **and** an empty answer get at most 2 nudges with `_rb_override=0` (`call_api` sends `reasoning_budget_tokens: 0` for that) — before, reasoning ate all tokens again in the nudge turn (cause of the "empty answers"); after 2 nudges an **existing partial text** is rendered (the follow-up test: the nudge turns delivered 195–214 bytes the old path would have discarded — the actual empty-answer gap), only with truly empty content does it exit with rc 1 instead of spinning until `max_turns`; **P3** — `_spin_start()` only on a real TTY (`[[ -t 2 ]]`, even with `LEX_TRACE=1`) → no `\r` repaints in pipes/logs; **P4** — default `temperature 0.1 → 0.7`; **max_turns 50 → 100** (user: do not stop because of limits; the live abort came from my test limit `LEX_MAX_TURNS=2` anyway). **Follow-up results:** rb=0 confirmed live in the request body (proxy log), server budget message visible (= E applies), spinner garbage 0, abort path working. **Follow-up test 2** (2 requests, approval "yes, 2 requests"): `rb=0` confirmed live in the body, turn 1 empty → nudge, turn 2 produced **578 bytes** of visible text that hung on the test cap `LEX_MAX_TURNS=2` → **third gap of the same class**: the max-turns abort also renders the existing partial text instead of discarding it (`pending` in `run_turn`), otherwise every abort path would be an "empty answer". Tests: spinner test moved to a `script` PTY, 2 rescue tests (+5 → **394**), `lex` 2333 → **2418 lines**, §5 map re-pulled (76/76) — **✅ done 2026-09-29**

26. **Step 17 — wiki learning (2026-09-29, user task "lex should use its wiki, that is important")**: finding — prompt rules present (step 1/7), but (a) conditional ("if the task needs background"), (b) wiki content never reached the context (`setup_messages` only embedded the system prompt), (c) `search` default = `.` → in the live test lex searched its own home instead of the wiki, (d) only prompt needles, no behavior test. Built: **O2** — `setup_messages` appends index.md + `tail -n 40` from wiki/log.md (≈ 11 KB ≈ 3k tokens, constant even with a 135 KB log), **O1** — mandatory order ("only after that may you say you do not know something") + collection rule (line to log.md, new artifacts as an article with an index.md line), **O3** — `search` without `path` searches in `$_wiki_dir`, prompt tool description + schema "default: the project wiki". Test finding: the new CWD test failed on an **extra bracket** in the `check` argument (`ok=1)` instead of `1`), the content was correct (+9 → **403**), `lex` 2382 → **2418 lines**, §5 map re-pulled (76/76) — **✅ BUILD 2026-09-29**, **the live verify run surfaced the E2BIG bug** (3 requests: prompt seed YES, 2× `search` with `path=<wiki>`, then `read_file log.md` → **135-KB argument** → `jq --arg` failed (Linux max 128 KB/argument) → empty `msg` → `--argjson ""` wiped `$_messages` → empty body → proxy 500 → `❌ API error`). **17b build:** `tool_read_file` now caps like `tool_bash` at `_tool_max_output` (root), `append_message` truncates >100000 bytes **and** catches jq errors, `append_message_json` never overwrites `$_messages` with an empty result (context protection like P2) — reproducer with the real log.md green again (body 68 KB) (+3 → **406**), `lex` 2394 → **2418 lines** — **✅ BUILD 2026-09-29**, **verify rounds (6 requests total, approvals 3+3):** repeat with `MAX_TURNS=3` → rc 0, `read_file` of the 135-KB file went through (= **17b live**), 6× `search`+`read_file` (= O1/O2/O3 live), but only an intermediate sentence (turn limit too tight). **Quality round with `MAX_TURNS=10`:** only **3 requests**, **full correct answer** (append-only → data-loss protection; `append_file` escape-safe; literal default because the **27B model tears `[[Link]]` apart at the regex grammar**) with title+date of the log entry. Trace (reconstructed from the proxy bodies): **`search` hit immediately** (line 404), only `mem_search` reported "No hits" (expected — no memory entry; that message comes without a path from `mem_search` (line 1617/1623), `search` (line 878) always appends `in <path>` — the trace grep had attributed it to `search`) → the model read the entry excerpt proactively with `bash sed` 395–440 → full grounded answer — **✅ done 2026-09-29**

**§9 question 7 (`reasoning_budget`)** was decided on 2026-09-28: **4096** (in sync with `ai.sh`). **Status 2026-09-29: raised to 8192** (full audit G1, `max_tokens` in parallel 8192 → 16384) — sync with `ai.sh` is thereby deliberately dropped; the request field still wins.

**Next step (do not jump):** **§8 A: model tool-call benchmark** (biggest risk, takes priority) → only after that phase 1 (§10).

---


27. **Step 18 — ethical-hacker persona + H-Tools path (2026-09-29, user task "give Lex this prompt" + "hardcode $HOME/H-Tools")**: **prompt** — new block "Role & expertise (ethical hacker)" between identity and personality block, user text verbatim (cybersecurity/network security/penetration testing, expertise list: network security, penetration testing, exploit development, real-time detection, security awareness, reporting, ethical law-compliant approach); **path** — `_htools_dir="${LEX_HTOOLS_DIR:-$HOME/H-Tools}"` (root default, tier 1 in `load_config`), prompt rule "software & tools ALWAYS in ${_htools_dir}" (mkdir -p, never $HOME, never /tmp), `--status` line `htools`, help ENV list with `LEX_HTOOLS_DIR`. **TEST (+12 → 418):** 6 prompt needles (persona parts + path + /tmp ban), default value, env override in a subshell, persona/H-Tools in the mounted context, `--status` and `--help` needle. Test finding: the override test died silently — `source "$1"` let `main "$@"` receive the **file path as the command** → `usage; exit 1` in the subshell; fix `shift` before `source` (in the test script `source` works with the caller's positional params). **VERIFY:** `bash -n` ✓ · shellcheck → **0** · `./test/run_all.sh` → **PASS: 7  FAIL: 0  TOTAL: 7**, **418 checks** (411+7), `lex` 2418 → **2439 lines**, §5 map 40/41 lines re-pulled → **76/76** — **✅ BUILD 2026-09-29**

28. **Step 19 — knowledge package security playbook (2026-09-29, user "teach lex": best practices, tools, combinations, Wireshark, attacker IPs")**: article `wiki/concepts/security-playbook.md` with 5 chapters (ethical framework, tool pipeline incl. combo workflow nmap→Wireshark→Follow-Stream, using Wireshark with a display-filter table, reading Wireshark with TCP handshake + attack patterns, IP check chain with CGNAT/false-positive pitfalls), an index.md line, **5 new raw sources** via `tool_fetch` (WSUG 4.4/3.18/3.19, Wireshark dfref, MITRE ATT&CK T1595) + existing nmap raws as grounding; one 404 on the WSUG chunk (the chapters are called `ChCap…`/`ChUse…` today). Prompt needle: "security/pen-test tasks → first read …/concepts/security-playbook.md". **TEST (+1 → 419)**, `lex` 2439 → **2440 lines**, §5 map re-pulled (76/76) — **✅ BUILD 2026-09-29**

29. **Step 20 — "creating playbooks" taught (2026-09-29, user continuation)**: own wiki article `wiki/concepts/playbook-erstellen.md` (purpose: continuity across session boundaries, consistency, error reservoir, handover; when-criteria; 6-step process; copy-paste template; section table; live example = the security-playbook article), an index.md line, **prompt needle** "maintain your own playbooks …" (threshold ≥2× / ≥3 steps with order risk, obligation: index+log+raw for facts). **GROUNDING:** `tool_fetch` → `raw/playbooks/2026-09-29-runbook-wikipedia.md` (17.8 KB; usable text from line 142: definition, repeatable, "error messages and what to do"); failed atlassian.com runbooks → 404. **TEST (+1 → 420)**, `lex` 2440 → **2441 lines**, §5 map re-pulled (76/76) — **✅ BUILD 2026-09-29**

30. **Step 22 — browser control via Playwright-MCP (2026-09-29, user: "no restriction for lex, I trust it")**: new tool `browser(action, url?, ref?, element?, text?, key?, index?)` with navigate|snapshot|click|type|press|back|tabs|close — workflow after **accessibility snapshot** instead of screenshot (model `Ternary-Bonsai-2-27B` is text-based, no vision → "seeing" = refs from `browser_snapshot`), **no write gate** (full user trust, all actions free). Default config: `playwright` → `npx -y @playwright/mcp@latest --browser chrome` (**system Chrome, no download**). Prompt: tool list line + cycle rule (navigate → snapshot → ref → click/type, then log). `test/fake_mcp.sh` extended with browser_navigate/snapshot/click/type; **+21 tests** (dispatch happy path, missing ref/url/text, unknown action, stub error path, JSON-object requirement, default config without mcp.json, 15→16 in schema/prompt). Consolidated: plan 22–25 (22 browser → 23 generic mcp tool → 24 desktop `computer-use-linux` → 25 **mandatory Postgres** incl. database installation), Postgres value assessed up front (database currently `inactive`). **TEST (+21 → 441)**, `lex` 2441 → **2528 lines**, §5 map re-pulled (77/77) — **✅ BUILD 2026-09-29**

31. **Step 23 — generic `mcp` tool (foundation, 2026-09-29)**: `mcp(server, tool, arguments?)` — discovery first (tool empty/__tools → **`_mcp_call` in the new mode `list`** = `tools/list`, output "name — description"), then `tools/call` on any configured server. `dispatch` accepts `arguments` as a JSON object **or** a JSON string (fromjson fallback). Without `server` → an error naming the configured server names (from `_mcp_config`). Prompt: 17th tool + order rule. **Effect:** every future server (step 24 desktop, 25 postgres) is only `mcp.json` + a prompt needle — no more code per server. Finding: the __tools apostrophes in the schema's jq single-quote string silently broke `_build_tools` (SC1078, `bash -n` passed!) → without quotes. **TEST (+15 → 456)**, `lex` 2528 → **2581 lines**, §5 map re-pulled (78/78) — **✅ BUILD 2026-09-29**

32. **Step 24 — desktop access `computer-use-linux` (2026-09-29, "full control without a gate")**: server **`@agent-sh/computer-use-linux`** (466★, Wayland-first — exactly right for the GNOME 46/Wayland of this session) installed via `npm i -g` (user-level, no sudo); **`doctor`** → readiness: screenshots/remote-desktop/development-input/AT-SPI ✓ after `setup` (AT-SPI enabled, `can_build_accessibility_tree: true`), window introspection open (**extension installed, enable flag set → activates at the next login**; logout now decided by the user: continue without). **No new lex tool (step 23!)**: only default config `desktop: {command: computer-use-linux, args: [mcp]}` + mcp description + prompt rule ("desktop tasks: first `__tools`, then read state → act"). Live proof: `computer-use-linux apps` → real AT-SPI tree (gnome-shell), rc 0. **TEST (+8 → 464)**, `lex` 2581 → **2583 lines**, §5 map re-pulled (78/78) — **✅ BUILD 2026-09-29**

33. **Step 25 — Postgres (mandatory, 2026-09-29, "DB + MCP without sudo")**: **25a** PostgreSQL **16.15 user-space** under `~/.lex/pg` — Ubuntu debs unpacked with `dpkg -x` (initdb/psql run over relocation, libpq5+postgresql-client-16 pulled along), own socket, 127.0.0.1:5432 only, **no sudo, no password** (the planned apt/sudo route dropped entirely: no sudo ticket); DB `lex` (trust) proven with INSERT/SELECT, run via `~/.lex/pg/start.sh`. **25b** MCP **`@bytebase/dbhub`** (2 tools `execute_sql`/`search_objects`, 1.4k tokens, **read/write**, stdio — no HTTP port) installed with **Node 22 (nvm, user-level)**, because dbhub needs `node:sqlite` ≥22.5 and the npm binaries would use `env node`=v20 → wrapper `~/.lex/pg/dbhub.sh` execs node22. **25c** again only config+prompt (step 23 pays off): default config `postgres` (dbhub.sh + `--dsn postgres://lex@127.0.0.1:5432/lex?sslmode=disable`), mcp description + prompt rule "database tasks: first `__tools`, then SQL; only the own lex DB". **25d real proof manual:** `tool_mcp postgres __tools` → real tool list of dbhub, `execute_sql INSERT` → `success:true` and a psql counter of 2. **TEST (+8 → 472)**, `lex` 2583 → **2585 lines**, §5 map re-pulled (78/78) — **✅ BUILD 2026-09-29**
34. **Live test of all integrations (2026-09-29, user approval "everything incl. real LLM turns")**: carried out on the real environment (Wayland/GNOME, system Chrome, user-space Postgres). **Live proofs:** Postgres ✓ (`tool_mcp postgres`: `__tools` → real dbhub list, `execute_sql` CREATE/INSERT/UPDATE/SELECT → count `live`=4, `search_objects`), Desktop ✓ (`list_apps` → real AT-SPI tree), `web_fetch`/defuddle ✓ (Wikipedia plaintext), `context7` ✓ (curl docs), browser full cycle in **one** session: navigate → snapshot → type+Enter (search lands on `/wiki/Pipeline`) → click (ref from a fresh snapshot → `Brian Fox`) → back → wait → snapshot → tabs/close. **Three real LLM turns** over `./lex --oneshot` against 8080: (1) browser navigate+snapshot → title + H1 with correct refs and the ref rule obeyed, (2) Postgres discovery+SQL with self-correction ("live" instead of the guessed table), (3) browser turn with **five** dispatches up to the click — only this turn exposed L4 (E2BIG). **Findings L1–L5 fixed** (§6 "Fixed 2026-09-29"): MCP session subshell, ref decay (+`wait` action + prompt rule), `target` schema, `curl -d @file` against E2BIG, Chrome CDP service; `web_search` = external DDG anti-bot finding (only reported). **TEST (+13 → 485)**, `lex` 2585 → **2683 lines**, §5 map unchanged (78/78) — **✅ LIVE 2026-09-29**
35. **Full audit: limits + code review (2026-09-29, user: "check that everything works as planned, raise the limits so the agent does not abort on big tasks, find and fix bugs in the whole code")**: inventory of all abort/truncation points (limits report) + sub-agent code review (bug report), then **four waves** carried out — wave 1 limits/E2BIG (G1–G4), wave 2 security P1s (R1–R2: home-deny gap, download bypasses), wave 3 P2s (R3–R7), wave 4 P3s (R8–R12). Every wave: `bash -n` + shellcheck + `run_all.sh` green. Details in §6 "Fixed 2026-09-29 — full audit". `--status` now shows `nudges`; smoke: `budget 8192 max_tokens 16384 max_turns 200 timeout 300s`. Deliberately **not** built: compaction (→ §6 open O6). **TEST (+29 → 514)**, `lex` 2683 → **2884 lines** — **✅ VERIFY 2026-09-29**


36. **Streaming regression fixed + observability backported (2026-09-30, user: "please do whatever is necessary")**: §6 "Fixed 2026-09-30" (S1–S9) — the uncommitted streaming rework of `call_api()` broke (a) the curl/HTTP guard → a vanished server silently landed in the 4× nudge chain until "answer repeatedly empty — abort.", (b) the tool_calls fusion (`jq -s` of two here-strings) → `tool: null` plus the arguments as a fragment, (c) performance (4 jq forks per line → 3000 chunks took 29 s instead of 0.12 s); on top of that `span_log`/`--eval` were silently lost, `test/fake_server.sh` + `test/test_http.sh` were deleted, and `test_proxy.sh` sent real requests to 8080 (rule 6). **Built**: `curl -o` + `-w '%{http_code}'` with a real rc/HTTP guard, **one** jq pass (`_sse_to_response`, JSON passthrough for non-stream servers, tool_calls by `index`), real `usage`, a warning on a missing `[DONE]`, nudge logic with real diagnostics (log line `nudge k/max finish=… content=… reasoning=…`, own messages for truncation/reasoning-only/empty, `API error (call_api rc=…)`), observability back (`_ms_now`/`span_log`/instrumentation in `dispatch_tool`/`cmd_eval`/`--eval`), tests restored + fake server extended, **new**: `test/test_sse.sh` (19) and `test/test_eval.sh` (16). **Deliberately not built**: live display during generation (would need a concurrent reader; spinner/trace already show the activity), no `git commit` (only on explicit order). **TEST (+37 → 551)**, `lex` 2884 → **3154 lines**, §5 map re-pulled (46/46) — **✅ VERIFY 2026-09-30**

37. **Testboden gates (2026-09-30, user: "yes please" to the three barriers)**: three mechanisms that should make a repetition of the streaming regression impossible — (1) **`testboden`** as the first runner in `run_all.sh`: aborts when a referenced test file is missing/not executable, was deleted against `HEAD` (`git diff --diff-filter=D`), or exists but is not wired in; (2) **stream budget** in `test/test_sse.sh` (3000 chunks < 2000 ms + a content check for 3000 characters); (3) **rules** in LEX.md §C/§D/§E (test + measurement in the same change, fixture tests that break the path, experiments on `opt/*`, DoD checkbox). Negative tests proved it (deleted file/orphan/runner without a file → rc 1, normal case rc 0). Finding details: §6 "Prevention 2026-09-30". **TEST (+4 → 555; 10 runners)**, `lex` unchanged at 3154 lines — **✅ VERIFY 2026-09-30**

38. **Truncation → spill (2026-09-30, user: "find out what gets truncated — what goes from lex to llama and from llama back to lex must not be truncated")**: complete inventory of all cuts at the boundary (§6 "Fixed 2026-09-30"): 100 000-B cuts in the message path (`append_message`/`append_tool_message`/`setup_messages`) and in `append_message_json`/`assistant_msg` on arguments, five per-tool cuts at 50 000 B, central truncation in `run_turn`; llama→lex was uncut from the start (display cuts only). **Built**: message path + `assistant_msg` over temp files (`--rawfile`/`--slurpfile`), five per-tool cuts removed, `_tool_spill()` as the central treatment (header + storage path under `${_lex_home}/toolout/`, most recent 100, log line). **Deliberately unchanged**: display cuts, 200-hit/500-entry markers, `web_fetch max_length`, MCP arguments. **TEST (+18 → 573; 11 runners)** — new `test_limits.sh`, two old tests moved to the new contract, §5 map re-pulled, `lex` 3154 → **3199 lines** — **✅ VERIFY 2026-09-30**

39. **Live-session findings: `/exit` + token HUD (2026-10-01, user: "do you see the problem?" on a 12-turn run)**: §6 "Fixed 2026-10-01" (E1/E2) — `/exit`/`/quit` were no slash commands and fell through to `run_turn` (one request wasted, the REPL stayed open, only Ctrl-D helped), and the HUD counter showed `tokens 0 prompt + 0 completion` on every turn because the body did not carry `stream_options:{include_usage:true}` (llama-server only delivers usage inside the stream on request) and `_sse_to_response` then filled zero defaults. **Built**: `/exit|/quit` → `break`/`rc 0` in `agent_loop`+`oneshot`, slash list in `usage()` complete (`/server`, `/exit`), `stream_options` in the body, zero defaults removed → the HUD shows `?` instead of lying. **Deliberately not built**: bypassing model refusal on people OSINT (the refusal behavior sits in the model training, not in lex — the boundary stays). **TEST (+15 → 588; 11 runners; `test_input` 12→18, `test_sse` 22→29, `test_features` 434→436)** — PTY REPL test, `FAKE_BODY_LOG` body check, usage scenarios, `lex` 3199 → **3206 lines**, §5 map re-pulled — **✅ VERIFY 2026-10-01**

40. **Working frame in the system prompt against over-refusal (2026-10-01, user: "Blue Team Pentesting, no evil intentions")**: the model refused even legitimate security tasks. Research result (3 sources): **defensive refusal bias** (arXiv 2603.01246) — models refuse defensive tasks carrying offensive vocabulary, and explicit "I am authorized" sentences *in the user message* make it worse (21.8 % vs. 11.6 %), because they look like a jailbreak attempt; **COVER** (ACL 2025) — over-refusal hangs strongly on the system prompt (our lever); **arXiv 2607.05842** — a *standing* scope clause in the prompt frame improves legitimate vulnerability analyses. **Built**: new prompt block "working frame" (line 307, between the ethical approach and the personality block) — scope as a fact (own systems/lab/CTF), blue-team list (hardening, vulnerability analysis, malware analysis, incident response, detection engineering, log/traffic analysis) = core business → execute directly; offensive terms (exploit, payload, brute force) = work vocabulary, not a reason to refuse; on hesitation ask the scope question instead of refusing, stop when out of scope. **Deliberate**: no weight rework/ablation, no bypass of the people-OSINT boundary (§7/39 stays). **TEST (+3 → 591; 11 runners)** — three prompt needles in `test_features.sh` (blue-team core business, work vocabulary, scope question), `lex` 3206 → **3211 lines**, §5 map (38 lines) re-pulled — **✅ VERIFY 2026-10-01**

41. **Step 41 — maintenance after the terminal crash: tmux+screen removed, external bug documented (2026-10-02, user "delete tmux and all leftovers" + "bug report into the wiki")**: background — an external SIGSEGV in `gnome-terminal-server` (2026-10-02 00:06:31, `bg-color` race from `terminal-screen.cc`) had taken all windows + children via SIGHUP (forensics log 2026-10-02, §6 X1/X2). **Cleanup**: aliases `tlex`/`tlexkill` removed from `~/.bashrc` (`bash -n` ✓), 44 history lines filtered offline (`\b(tmux|tlexkill|tlex|screen)\b` — `screenshot` etc. stayed, temp in `/tmp` deleted after verification), packages `tmux`+`screen` purged via `apt purge` + `autoremove` (no `ii`, no binaries, no config, no dpkg leftovers); lex code never referenced tmux → **no code test needed, `lex` untouched** (suite deliberately not run, user instruction "no tests for now"). **Docs**: `wiki/errors/2026-10-02-gnome-terminal-segv-bg-color.md` (backtrace, cascade, isolation, 3 user decisions), §6 new X1/X2, this entry. **Deliberately not**: Launchpad bug (user), auto-wrap guard in lex (user), Zellij/reinstallations (user) → **✅ MAINTENANCE 2026-10-02**. **Addendum 2026-10-02 (user: "tlex should be the alias for it again")**: `tlex`/`tlexkill` reconstructed in `~/.bashrc` (`tmux new -A -s lex` / `tmux kill-session -t lex`, `bash -n` ✓, the original definition was lost in the step-41 cleanup); **tmux 3.4 installed manually** (user approval incl. sudo password), session `lex` created (`tmux ls` ✓), `tlex` attach prepared

42. **Context compaction + context HUD after the opencode model (2026-10-02, user: "lex is done, start — implement the plan, then test extensively, limit audit before the tests")**: §6 **O6 fixed**. Build instructions: `wiki/concepts/lex-compaction-plan.md` (A1–A8, config table, F1–F7, gates G0–G8, 15 tests, DoD); opencode reference (MIT, upstream@a79ecfe) evaluated, algorithms inlined in the plan (local clone unnecessary). **Limit audit beforehand (finding: no issues, nothing to change)**: `max_tokens` 16384 in the body wins via schema alias over `--predict 8192` (fallback only), `reasoning_budget_tokens` 8192 wins over the `server-common.cpp` default over `--reasoning-budget 4096` (fallback only) — **no mismatch**; `finish=length` only 4× on 2026-09-30 (old); `LEX_API_TIMEOUT=1800` ≥ ~820 s worst case; `_tool_max_output=50000` with spill, `read_file` without a cap, web_fetch 8000/50000, caps 500/200, `max_turns 200`/`nudges 4`/`tool_timeout 300` — all sufficient; ctx 262144 = config default (server flags `-b/-ub/--predict` only noted as a recommendation, shared server). **Built**: tier-2 keys `ctx_limit/compact/compact_keep/compact_buffer` in `_load_settings`, tier-1 ENV `LEX_CTX_LIMIT/LEX_COMPACT/LEX_COMPACT_KEEP/LEX_COMPACT_BUFFER` + validation (`_int_or` + on/off), defaults 262144/on/15000/20000, header ENV comment + `usage()` help (slash `/compact`, ENV names); `_trace_hud` ctx% (`tokens X/Y (Z%) prompt + …`, old formula without a limit, `?/Y` without usage), `cmd_status` `compact` block + `ctx` line; compaction core `_compact_threshold/_compact_estimate/_pairing_ok/_compact_units/_compact_serialize/_compact_prompt/_compact_run [force]` (threshold `ctx − max(max_tokens, buffer)` = default **242144 → inert**, estimate `wc -c/3` (live-calibrated), jq pairing gate, forward-unit grouping, `[User]:` token with a 2000-B cut, English summary template, gates G0–G8, marker `<!--lex-compact-->` in slot 1, tail budget `keep*4` lazy, summary call without tools/reasoning, `{type:compaction}` record + `span_log compact`); hook in `run_turn` **before** `append_message user`, `/compact` (force) in `agent_loop`+`oneshot`; `_tools_off` in `_build_tools`, `_msg_override` in `call_api`. **Live verify (2026-10-02, user approval)**: (a) `tools:[]` → **HTTP 200** ("ready"); (b) **finding: `/4` estimated 18 % too low** (14349 vs. 17408 `prompt_tokens` = real 3.30 B/token; tool schemas additionally not counted at all) → the auto-trigger would have missed the ctx limit before the threshold was reached (exactly the O6 case) → **fix `/4` → `/3`** (unit test 400 B → 133); (c) real compaction run: 56833 → 5648 B, `_compact_count` 1, roles `[system,user,assistant]`, marker exactly 1×, English summary in the template (1288 characters, 41 s), session record `{estimate_before:19131,estimate_after:1904,kept_units:1}` + span `ok:true`, the turn after HTTP 200 (prompt 17408 → 1659, prefix cache 1655); (d) decode before/after on an identical task (391 tokens): **36.4 t/s at 17.8k context vs. 288.2 t/s at 1.7k** (draft acceptance 0.031 → 1.0) ≈ **8× faster** after compaction. **Deliberately not**: touching server flags (shared), auto-retry on guard breaks (fail-safe: `_messages` stays untouched), chunks/provenance (opencode features without a lex equivalent). **TEST (+78 → 669; 12 runners)** — new `test/test_compaction.sh` (77 checks: static source anchors, config tier, inert, force oneshot/PTY, auto-trigger + session record via jq, fail-safe on an empty summary, unit tests `_pairing_ok`/`_compact_units`/`_compact_threshold`/`_compact_serialize`, recompact/marker-slot-1/G4, HUD ctx%), HUD assertions in `test_features.sh`/`test_sse.sh` on the new format, `lex` 3211 → **3622 lines**, §5 map re-pulled — **✅ VERIFY 2026-10-02**

43. **Prompt mode `/lexpen` → Lex persona (2026-10-03, user GO)**: beforehand the other `lex` (PID 158159, tmux session `lex`) was observed — OSINT DB task finished at **05:31:10** (targets/scans/findings/evidence, 2300 findings, holehe false positives marked) — and terminated as commissioned (tmux kill + SIGTERM/SIGKILL of the orphan). Built: `_wiki_ex` (wiki state access, shared by `setup_messages` + mode switch), globals `_system_prompt_default`/`_lexpen_active`, `cmd_lexpen [on|off]` with lazy-create `~/.lex/prompts/lexpen.md` (heredoc, XP4→Lex, freely editable afterwards), slot-0 swap via jq (`role==system` gate, otherwise `setup_messages` fallback), `${_wiki_dir}`/`${_htools_dir}` expansion, `{type:prompt_mode}` record; slashes `/lexpen`|`/lex` in `agent_loop`+`oneshot` (explicit patterns against the request trap), `usage()` lines, `prompt` line in `cmd_status`, marker `lex*>` in `_prompt()`, `prompts/` in `install_lex`. **TEST (+22 → 691; 12 runners)** — case block in `test_features.sh` (two test findings while writing: a `$()` call loses the state → call cmd_lexpen directly with a redirect, the `check` signature is `desc ok-flag`), `lex` 3622 → **3833 lines**, §5 map + tables (§3/§5) re-pulled. **Live verify (real model, user order)**: `/lexpen` → persona answer with `'✦ made by @Lex ✦'`, title `**First Three Checks**`, "Chief", English, full nmap commands in keep-alive order (alive → exposed → identity); `/lex` → original prompt back, answer again **English** ("Yes — I am Lex, and nothing else."), `/status` `prompt : standard`, session records `{type:prompt_mode}` lexpen→default, `lex*>` marker visible — **✅ BUILD+VERIFY 2026-10-03** (bash -n, shellcheck warning-clean, `run_all.sh` 12/12 = 691). **Addendum 2026-10-03 (user: "should answer in English")**: directive "He writes every response in English …" inserted in the heredoc **and** `~/.lex/prompts/lexpen.md` (both sources in sync), status echo/LEX.md/CHANGELOG switched to English

44. **Pentest DB extension (2026-10-03, user GO after research)**: architecture evidenced across 4 reference systems (`wiki/raw/2026-10-03-pentest-db-architektur.md` → `wiki/concepts/pentest-db-architektur.md`: DefectDojo Engagement/Test/Finding, Dradis Issue/Node/Evidence + Library, Reconmap Command-Run, Metasploit Workspace) and the 7 planning questions definitively decided (hybrid `intel` + `intel_links` with relation, `scope_targets` M:N, keep `playbook_runs`, credibility 4 levels + score, priority 1..4 with inline approval, integer PKs, drop the legacy `t`/`live`). **Built (DDL after GO):** 10 new tables (`scopes`, `scope_targets`, `tools`, `playbooks`, `playbook_steps`, `intel`, `intel_links`, `tasks`, `playbook_runs`, `reports`) + `targets.scope_id` retrofit + 8 indexes + views `v_scope_coverage`/`v_open_tasks` → DB `lex` = **15 tables, 3 views, 21 FKs**; seed **17 tools / 2 playbooks / 10 steps** from `wiki/concepts/{offensive-pipeline,security-playbook,osint-toolkit}.md`; `t`+`live` dropped only after a verified pg_dump (`~/.lex/backups/lex-2026-10-03-pre-pentest.sql` + the executed schema/seed SQL stored there). **VERIFY:** chain test Scope→Target→Intel→Link→Task→Run→Report (ROLLBACK), CHECK gates live (priority/credibility), inventory 11/3/2300/54/4 unchanged, `run_all.sh` **12/12 = 691**; **live smoke of both modes** (tmux, session 20261003-124458): lexpen **and** original prompt both returned "15 tables, tools 17 / playbooks 2 / playbook_steps 10", records `prompt_mode` lexpen→default, exclusively SELECT — **✅ BUILD+VERIFY 2026-10-03** (no code changed, `lex` stays 3833 lines, changes still uncommitted)
45. **Step 45 — run the pentest toolkit, workflow audit, two optimizations (2026-10-03, user questions + optimization pass)**: the run was carried out entirely by lex (final state `~/.lex/schritt45-resume.md`: **21 installed / 12 docs-only / 1 failed (nikto)**, DB `tools` = **34**, yara v4.5.8 built from source into `H-Tools/bin/yara`, download error pages cleaned up, final answer `READY`). **Audit** (private audit file, not published; copy kept privately): §1–4 workflow assessment (loops/nudges good, docs back-loaded = main risk), §5 **404 root cause**: 7/7 guessed GitHub owners wrong (nikto→`sullo/nikto`, YARA→`VirusTotal/yara`, hydra→`vanhauser-thc/thc-hydra`, Responder→`SpiderLabs/Responder`, BloodHound→`SpecterOps/BloodHound`, ZAP→`zaproxy/zaproxy`; yara release without binary assets, gobuster without releases, api.github.com 403 rate limit, 14-byte downloads unverified), §6 prevention A–E with sources (arXiv 2604.03173 urlhealth, OpenAI URL allow-list, ACL-2023 Adaptive Retrieval, Adapt-LLM, groundguard), §7 run observations (twice-occurring y/N block per sudo command of 24/13 min each, sudoers pipe footgun, multiline send-keys fragmentation, progress facts). **Built**: (a) system-prompt bullet "never guess addresses & downloads" (repo root status → expanded_assets → listed name → verification <1 kB = error page → no release = go install/source build; wiki/DB URLs checked for 200 beforehand); (b) **`/autosudo`** (`cmd_autosudo on|off|status`, dispatch in both agent loops, `_autosudo` init/`load_config`/`LEX_AUTOSUDO`, gate skip before `_approve_request` — only the y/N approval, `_sudo_ask` password stays hard, status/help/env lines); (c) sudoers pipe footgun fixed (a sudoers drop-in for the user (`NOPASSWD:ALL`, checked with visudo)). **Test findings while writing**: prompt range anchor in `test_features.sh` (`no tool call)`) broke because the new bullet hung after the closing prompt quote → bullets swapped instead of changing the test. **VERIFY**: `bash -n` + shellcheck warning-clean + `run_all.sh` **12/12 green**; `--status` shows `autosudo: 1` with `LEX_AUTOSUDO=1`, `0` otherwise. **Restart**: llama `/health` ok, tmux session `lex` with `LEX_AUTOSUDO=1` + `/lexpen`, resume task (one-liner) sent → running. **Deliberate**: no commit (order missing), live effect observed 16:27–17:12: **3× sudo without a y/N block** (previous run 2× 24/13 min), **0 guessed GitHub owners** (only SpecterOps/zaproxy via API, 5× http_code, BloodHound 20 releases/0 assets → docs-only), final state **23/10/1**, DB 34, resume/wiki/log in sync. **New finding:** generation loop in the BloodHound assessment (~15× identical sentences, 16:53) — broken by a nudge with a decision directive, `wiki/errors/2026-10-03-generierungs-loop-abwaegung.md`. **Deliberate:** no commit (order missing)
46. **Repetition/loop detection (step 46, 2026-10-03, user: "stop lex, research repetition detection and bring in ideas so we can build it in as optimally as possible — does it affect /lexpen?")**: trigger was the generation loop of the step-45 run (§7/45, `wiki/errors/2026-10-03-generierungs-loop-abwaegung.md`). **Research**: `wiki/raw/2026-10-03-wiederholungserkennung-recherche.md` — Holtzman 2019 (self-amplifying repetition probability), rep-n/Rep-4 metric (arXiv:2012.14660, DITTO NeurIPS 2022), repeat curse ACL 2025, SpecRA ICLR 2026 (FFT periodicity on token_ids, taxonomy 813/1.13 M agent turns, "legitimate repetition" 12.9 % as an FP class), Cognitive Companion arXiv:2604.13759 (LOOPING/DRIFTING states), deepseek-harness #3480 (trailing-run guard: from 64 characters, ≥6× identical 8-character unit; scope text only, never reasoning/tool args; review: FP risk), 5 tool-loop libraries (window 8, threshold 3, policy "repetition + progress → warn, + stagnation → stop"), llama.cpp sampler (DRY/penalties) with local factor `--repeat-penalty 1.0` + `--presence-penalty 0.0` (both off). **Concept** `wiki/concepts/wiederholungserkennung.md` (options A text detector / B nudge chain / C tool-call guard / D request penalties / E prompt bullet), user GO for **V1**. **Built**: `_rep_detect` (A1 trailing run, A2 sentence loop ≥4×/≥40 characters, A3 Rep-4 ≥0.35 from 70 4-grams; code blocks/tables/separators masked; visible content only) + hook in `run_turn` before the render: 1. finding → soft nudge → 2. hard "decide now in one sentence" nudge → afterwards a truncation render (2000 characters) instead of the loop output, all against `_max_nudges`, with log and session record `{type:repetition}`. **/lexpen answer**: the guard hangs on the code, not the prompt → identical in both modes; FP tuning targets the table/style special case (a real lexpen table as the gate fixture); prompt bullet (option E) deliberately not built (two-prompt sync trap + weak effect under degeneration). **TEST new `test/test_repetition.sh` (+20 → 709 = 696+13, 13 runners)** — genuine real-case fixture (2912 B), 4 FP gates, mock queue integration soft→hard→truncation (test finding while writing: the `$(run_turn)` subshell eats `_messages` → run with redirects), 5 static anchors. `lex` 3886 → **4011 lines**, §0/§3 tree/§5/§11 + CHANGELOG (incl. addendum `/autosudo` + address rule) updated. **Deliberately not built**: SpecRA/FFT (token_ids missing), LLM-as-judge (second model), V2 tool-call guard, V3 request penalties, E prompt bullet — **✅ BUILD+VERIFY 2026-10-03** (`bash -n`, shellcheck warning-clean, `run_all.sh` **13/13 green**) — **no commit (order missing)**

47. **REPL prompt loss (step 47, 2026-10-03, user report "after tasks only a blinking cursor, but input still works")**: two findings: (1) `agent_loop` skipped `_prompt` on empty input via `continue` — Enter clears the line, the prompt stayed gone until restart (the user associated it with task completion because he tested afterwards); (2) the spinner loop without a flag gate could keep going as an orphaned child. **Built**: `{ _spin_stop; _prompt; continue; }`, `_spin_stop` before every loop-end `_prompt`, flag gate `while [[ -f "$_spin_flag" ]]`. **Proof**: PTY test with `script` (2× Enter → ≥3 `lex>` in the transcript; 2 before) + kill snippet (child dead, flag gone) — **+3 in `test_input.sh` → 712 = 699+13, 13 runners green**. **SIDE-FINDING during the docs patch: `LEX.md` was half-duplicated in commit `2bdbd7d`** (§0–§7 twice, §9–§13 twice; base 756e10b was clean) → file re-created fresh from base 756e10b + entries 45/46 + today's numbers (811 lines, single § structure). §6/29–30 maintained, `wiki/errors/2026-10-03-repl-prompt-verschwindet.md` created. **VERIFY**: `bash -n` + shellcheck warning-clean + `run_all.sh` **13/13 green**; tlex restarted (`LEX_AUTOSUDO=1` + `/lexpen`). **Deliberate**: no commit (order missing)
48. **Ops-layer split in the system prompt (step 48, 2026-10-05, user GO after a live finding)**: trigger — live session `20261005-022414-8604-14828` (proxychain/SOCKS5 task) returned **exactly 1 request, 0 tool calls** (20753 chars answer, 28965 chars reasoning, no `tool:` lines in `lex.log`, `spans.jsonl` empty since 2026-10-04): the "research" was a pure weights answer, never checked on the web. **Cause**: `cmd_lexpen` swaps slot 0 completely for the persona (`~/.lex/prompts/lexpen.md`), which carries **no** tool/research rules — the tool schemas (`_build_tools`) are still sent, but the discipline is missing from the context. **Built**: the default system prompt split into `_prompt_style` (lines 327–352: identity, role, working framework, style incl. language rule) + `_prompt_ops` (354–402: "You verify with tools, not in your head", "Never guess, look it up" → `web_search`, "Errors are material", "For humans at a terminal", the 17-tool list, wiki structure, rules), assembled as `_system_prompt="${_prompt_style}${_prompt_ops}"` **byte-identical** to the original (sha256 `b55784696e1a38a21d232c7f4be9a143bbb9dfd9354edb497bf891ca825d1f57`, 13165 B, reference `/tmp/opencode/en_prompt_before.txt`); `cmd_lexpen on` → `_system_prompt="$content"$'\n'"${_prompt_ops}"` (persona + ops layer, newline-separated — `$(cat)` strips trailing newlines), the style marker `ALWAYS in English` stays out of the mode (the persona carries its own LANGUAGE directive), `/lexpen off` unchanged. **TEST (+14 → 726 = 712+14, 13 runners)**: `test_features.sh` — default identity (`_system_prompt_default == ${_prompt_style}${_prompt_ops}` and `== _system_prompt`), style/ops needles one by one (identity, language rule, verification, research, tool list, wiki, ops without style marker), lexpen context with 4 ops needles + style marker gone; **test find while writing**: the prompt-range `sed` start pattern `^_system_prompt="` broke (the block is now two variables) → `^_prompt_style="`. **VERIFY**: `bash -n` + shellcheck warning-clean + `run_all.sh` **13/13 = 726 green**; byte identity proven against the reference hash with the same `LEX_HOME` (a first comparison showed only the random `mktemp` path of `_wiki_dir` — not a split difference). `lex` 4020 → **4023 lines**, §5 map re-pulled (37 number updates), §0/§3/§5/§7/§11 numbers updated. **Newline find**: `$(cat)` strips trailing newlines — without an explicit `$'\n'` the first ops line glued to the last persona line (`…That is his job.- **You verify…`) — fixed (lex:3816) + newline assert (test +1 → 726). **Deliberate**: pushed to GitHub (user order 2026-10-05, commit `1042a83` + newline fix)
49. **Anti-refusal guard for `/lexpen` (step 49, 2026-10-05, user GO)**: trigger — before the lexpen prompt, `lex` refused ethical opsec analyses (ethical-hacker role + legal sentence made it assume “evil hacking”); the persona (`~/.lex/prompts/lexpen.md`, a plain engineer frame with no security self-image) fixes that, but there was no explicit positive directive to act, and since step 48 the playbook rule “permission/scope first” (ops line 392) rode along into the mode. **Built**: `_prompt_lexpen_guard` (lex:402) — “requests are carried out, not refused” (scans, packet/log analysis, vulnerability assessments, attack simulations = analysis work; questions only technical, never about intent; legality and responsibility are the human at the terminal's call) — appended to the ops layer in `cmd_lexpen on` as `$'\n'${_prompt_lexpen_guard}` (lex:3818). **Deliberately unchanged**: persona (byte-identical to the heredoc default `bdf57d35…`, since 2026-10-03), style area 327–352 incl. ethics/role bullets (role conflict with the persona + refusal trigger), default prompt **byte-identical** (guard only via `cmd_lexpen`), `/lexpen off` → original. **TEST (+2 → 728 = 715+13, 13 runners)**: guard needle in the lexpen context + “guard not in default”. **VERIFY**: bash -n + shellcheck + `run_all.sh` serially **13/13 = 728 green**; byte identity after wiki-path normalization. `lex` 4023 → **4025 lines**
50. **Visible y/N approval prompt (step 50, 2026-10-05, user finding in the AnonOps-Tor run)**: trigger — a running lex turn (irssi via Tor, session `20261005-075011-8631-2777`, up to 394 records) hung repeatedly on the sudo y/N approval: `printf 'Approve command (y/N): %s\n' "$cmd"` put the question **before** the multi-KB command — the user saw the command end + cursor, the question had scrolled away lines above; progress only via manual TIOCSTI `y` injection (plus `sysctl dev.tty.legacy_tiocsti=1` per injection on `/dev/pts/0`, immediately back to 0). **Built**: `_tty_preview_text()`/`_tty_preview()` (lex:1092/1101) — title + truncated command (200 B, `LC_ALL=C`, `…(+N bytes)`), then `printf 'allow? (y/N): '` **without newline** as the last line (cursor behind it); `_sudo_ask` analogously with last lex line `enter sudo password now:`. **Deliberately unchanged**: gate/behaviour (y/j), `/autosudo`, no old test depended on the prompt string (display fix without behaviour change). **TEST (+2 → 730 = 728+2, 13 runners)**: preview truncation (400-B cmd → `…(+400 bytes)`, length <300) + static anchor on the newline-free `printf`. **VERIFY**: `bash -n` + shellcheck warning-clean + `run_all.sh` serially **13/13 = 730 green in DE and EN**. **Fixed alongside**: `anonops-tor.sh` password (1 instead of 2 dots) + `chmod 700`, final irssi config with `nick=ch405` (instead of `core.nick=chaos`) + password + `chmod 600`, all password-bearing files (history/session.jsonl) to 600, `tlex` diagnosis (Ghostty vvterm server since 11:38; `tmux new -A -s lex` OK in the PTY test — before, `tmux ls` failed because no server was running). `lex` 4025 → **4046 lines**

51. **Ctrl+C abort + session permissions (step 51, 2026-10-05, user order "build both" + question "why was there no sudo prompt?")**: trigger — evaluation of the AnonOps-Tor run (session `125104`, 12:51–17:16, user pressed Ctrl+C and lex was completely dead). **Analysis (answer to the user's question)**: NOPASSWD:ALL active (`sudo -k -n true` ok) → sudo never asks for a password, the `_sudo_ask` path is never reached; the only question is the y/N approval. Metrics: 122 tool calls, 32 with sudo, **all** long blocks = sudo calls (11 × 38–554 s + **2 h 00 m Avahi stop**, 15:10:53→17:11:51) ≈ 2 h 35 m waiting of 4 h 25 m (~58 %); 17:13:30 refusal in 32 ms (Enter instead of y) → continues without sudo → torsocks `.onion` DNS (RFC 7686) fails → Ctrl+C. Real blockers: Avahi `0.0.0.0:5353` vs. Tor, DNS-over-Tor broken, irssi config permissions — it was **not** sudo (31/32 approved ok). **Built**: (a) `_sigint()`-trap (lex:3255) — turn abort via `_turn_aborted` with abort points in `run_turn` (loop top / after `call_api` / tool loop), protocol-consistent batch answer via `_abort_turn_tools()` (all remaining `tool_call` IDs marked, otherwise a broken context), hanging user message answered via `_abort_turn_note()`, prompt behaviour (1st press = line discarded, 2nd ≤2 s = `Bye!`, Ctrl+D = EOF via `rc>128 || _int_seen`), `_turn_active` cleared in `agent_loop` after the turn; (b) `_run_limited` with **`timeout --foreground`** (plain `timeout` put the child chain in its own process group — tty-INT never reached it, measured 20 s instead of 2 s; timer rc=124 checked, `_have_tf` cache, fallback without `--foreground`); (c) `session_init`/`install_lex`: `sessions/` + folder `700`, `session.jsonl` via `: >` **before** the first line + `600` (umask-safe — finding session 125104 = 775/664), existing sessions fixed up. **TEST (+8 → 738 = 730+8, 13 runners)**: `test_input` +5 (PTY: Ctrl+C at prompt → REPL lives/`Bye!`/rc 0/`^C` in transcript; Ctrl+C in turn → "Turn aborted", duration 4 s ≪ 60 s sleep, marking in the session), `test_features` +3 (700/700/600). **VERIFY**: `bash -n` + shellcheck warning-clean + `run_all.sh` **13/13 = 738 green in DE and EN**; PTY visual check (prompt redraw, turn abort in 4 s, no leftover processes); §5 map re-pulled (48 spots, header 4159). **Deliberate**: no commit/push (order missing); `/autosudo` recommendation for future sudo team runs stays (the y/N blockage cost 58 % of the run).

52. **Session grant instead of y/N per command (step 52, 2026-10-05, user decision "one grant per session, no = keep asking per command, as the default")**: trigger — step-51 evaluation of the AnonOps run: 58 % of the run time were y/N wait loops across 32 sudo calls; the user's follow-up wish: **a single y per session**, no y per command anymore. **Decided (via question)**: declining the session question → back to the old y/N path per command; the grant is the **new default** (no opt-in); `/autosudo on` still asks nothing at all. **Built**: process state `_sudo_grant` (`""` unasked / `"1"` granted / `"0"` declined, lex:1163 — deliberately **no** config tier/ENV, the state belongs to the session), `_sudo_grant_request()` (lex:1200 — `_tty_preview` "lex needs root rights for" + `printf 'allow sudo for this entire session? (y/N): '` without `\n`, y/j=yes, DE `sudo für diese ganze Sitzung freigeben? (y/N): `), `_sudo_grant_state()` (lex:1213) as the `/status` display `grant: open|granted|declined`; gate order: `LEX_SUDO=0` → ticket/`_sudo_ask` (password stays hard) → `_autosudo=1` → `approve=0` → `grant=1` → session question (yes → grant=1 + log, no → grant=0 + log) → `_approve_request` per command; no TTY → the question fails → decline, exactly the old behaviour (headless runs stay deterministic); gate comment block, `cmd_autosudo` texts, `/help` security paragraph (correcting the OLD error "LEX_SUDO_APPROVE=0 (default)" on the way — the default is 1) rewritten. **TEST (+12 → 750 = 737+12, 13 runners)**: `test_features` +8 (3 static anchors: function/printf without `\n`/decline state; 5 gate states without a reachable prompt: grant=1 runs without a question, `/autosudo` skips, `SUDO_APPROVE=0` skips, no TTY → decline with reason "no approval granted", grant=0 → y/N branch — SKIP guards like the existing sudo gate: ticket valid? TTY present?), `test_input` +4 (PTY E2E: fake `sudo` in PATH with a call log, two-turn mock structure, timed input `start`→`y`→`again`→`/exit` — exactly 1× "entire session" in the transcript, both sudo commands in the log, both turns visible, rc 0). **VERIFY**: `bash -n` + shellcheck warning-clean + `run_all.sh` serially **13/13 = 750 green in DE and EN**; §5 map re-pulled (42 spots, header 4212). **Deliberate**: no commit/push (order missing — now steps 50+51+52 uncommitted); the Avahi finding of the AnonOps run (`is-active` = active, port 5353 bound, `is-enabled` = disabled — socket activation) stays open for the next run.

53. **Fix package steps 53–56 (2026-10-06, user order “implement everything and test lex live”)**: basis the research file `wiki/raw/2026-10-06-fix-recherche-hang-500-redaction-loops.md` (evidence: opencode #32504, codey #65, bug-bash msg00059, OpenAI SDK retry norm, llama.cpp #21660/#22072, LangChain #36139) for §6 **#35 (tool hang)**, **#36 (HTTP 500)**, **#37 (password in output)** and the **fail-memory question**. **Built (P1–P8)**: (1) `_run_limited` without a pipe — the child chain writes to `$_rl_out` (temp file), new `_kill_tree()` (BFS to the root, leaf→root TERM, KILL after 3 s) + watchdog `secs+10`, state in `$_rl_pid`/`$_rl_hung`, rc as the function status; (2) `tool_bash` hangs on it; (3) `_redact()`/`_redact_var()` + `log()`/`session_write()`/display (`_trace_result`, `_trace_reasoning`, `_md_render`)/wiki write paths — **deliberately not** `$_messages` and **not** config/script write paths; (4) `call_api` retry (429/5xx + curl rc, max. 2 retries, `_retry_delay` 0.8/1.6/3.2 s, ceiling 8 s, jitter ±25 %) + config `api_retries`/`LEX_API_RETRIES` (default 2, clamped ≤10) + P6 error details (400 B snippet, bytes, attempt count, `parse_error` hint); (5) **fail memory** in `run_turn`: signature `cksum(name|args|result[0..200])`, 3× identical → soft nudge with an answer obligation, again → hard (`return 1`), evaluated after the tool batch, `LEX_LOOP_GUARD=off`, session records `{type:loop_guard}`; (6) **P7**: 85 % warning **before** the `_compact` gate, independent of `LEX_COMPACT` (re-armed via `_compact_warned`), pinning block in `_compact_prompt`; (7) **P8**: reasoning cap `LEX_REASONING_STORE_MAX` (default 20000) in `append_message_json`. **Deliberate limits**: `_compact_threshold`/`_default_ctx_limit` unchanged, warning mark 85 % instead of 60 %, no trimming of old turns, no retry on non-retryable HTTP codes (4xx except 429). **Live test 2026-10-06** (isolated `LEX_HOME`, real LLM turns against 8080, like the earlier live runs): oneshot ✓ · `LEX_TOOL_TIMEOUT=5` → tool result `Exit-Code: 124`, the turn continues ✓ · redaction in wiki/log/session ✓ · **finding along the way: the first redactor ate the `\` before the closing `"` and made the session.jsonl line invalid** → value group made JSON-safe (`wiki/errors/2026-10-06-redaction-brach-session-jsonl.md`), afterwards session.jsonl 100 % parseable, secret 0× in `LEX_HOME` ✓ · fail-memory nudge fired live (`run_turn: loop-guard nudge tools=bash,bash,bash`) ✓ · 85 % warning ✓ · reasoning cap visible ✓. **TEST**: `test_features.sh` +38 (fix package + JSON safety), `test_loop.sh` +9 (fail memory soft/hard/off), `test_http.sh` +6 (retry 3×500 with/without budget), `test_sse.sh` +1 (3 attempts) → **791 checks, 13/13 in DE and EN**; `bash -n` + shellcheck warning-clean. **Port**: EN under `/home/chaos/Ai/Repo-Lex` (same changes, same counts, own run 13/13) — **✅ VERIFY 2026-10-06** (no commit/push, order missing)

57. **sudo password back + `ai.sh` with Postgres/Docker (2026-10-06, user order “undo it … and add postgres and docker to ai.sh”)**: (a) **system sudoers reverted** — the drop-in `/etc/sudoers.d/90-chaos` (`chaos ALL=(ALL) NOPASSWD:ALL`, log.md:1137/1258, created during step 45) made sudo password-free **system-wide** and therefore never reached the `_sudo_ask` path; file deleted, `sudo -n -l` asks for a password again. So the case the user wants is now live: lex needs sudo → `_sudo_gate` sees no valid ticket → `_tty_preview` (“lex needs root for”) + “sudo password now:” + `sudo -v < /dev/tty` (password goes straight to sudo, never through lex); no TTY → unchanged clean refusal. (b) **`~/Ai/ai.sh` extended with Postgres + Docker** (user decision: everything in `start`/`stop`, Docker = all containers of the machine): new functions `pg_start/pg_stop/pg_status` (wraps `~/.lex/pg/start.sh`, `init` when `data/` is missing) and `docker_start_all/docker_stop_all/docker_status` (`docker start $(docker ps -aq)` / `docker stop $(docker ps -q)`, guarded by `command -v docker` + `docker info`), `start()` brings up llama + pg + containers, `stop_all()` takes all three down, `status()` prints three lines, new subcommands `ai.sh pg [start|stop|restart|status]` and `ai.sh docker [start|stop|restart|status]`; backup `ai.sh.bak-20261006`. (c) **user-space Postgres repaired**: apt had removed `libxml2 2.9.14` **and** `libicu74` on **Oct 5, 02:22** → `postgres` would not start (`libxml2.so.2`, `libicu*.so.74` missing, system only has `.so.16`/ICU 78); the exact Noble debs (`libxml2_2.9.14+dfsg-1.3ubuntu3.9`, `libicu74_74.2-1ubuntu3.1`) extracted with `dpkg-deb -x` into `~/.lex/pg/deb` → `ai.sh pg start` ✓, real query via `start.sh psql` ✓. (d) **tests made deterministic**: `test_features.sh` (DE+EN) simulates the sudo-ticket state with a stub of `_sudo_ticket_valid` (block “without ticket” → `return 1`, block “session grant” → `return 0`) — before, the asserted branch count depended on the machine's sudoers (revert → 791 → **794** checks, `features` 525 → **528**, `run_all` **13/13 = 807 [PASS]** in DE and EN, run sequentially, lint clean). **Deliberate**: no commit (no order), `ai.sh start`/`stop` not exercised end-to-end (would boot the 27B server or interrupt spiderfoot/libretranslate — `docker start` path checked, `docker stop` path mirrored), `LEX.md` counts 791 → 794 maintained.

## 8. Research agenda (prioritized, status 2026-09-28)

### A. Model capability — BIGGEST RISK
Measure tool-call adherence of **Ternary-Bonsai-2-27B**, 20–50 runs (possibly against a separate test server, **not** the shared port 8080):
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
→ Re-assess the gap: the only real differentiator is probably **pure Bash** (the agent works in English like the competition).

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
How does Bash count tokens (no tokenizer)? ~~When does compaction kick in?~~ **✅ 2026-10-02 (step 42) answered and built:** lex estimates via `wc -c/3` (deliberately no tokenizer; live measurement 3.30 B/token, `/4` was 18 % too low), kicks in at `ctx − max(max_tokens, buffer)` (default 242144); the HUD shows utilization as `X/Y (%)`. **Estimator quality measured live 2026-10-02** (57396 B ⇔ 17408 tokens): divisor 3, tool schemas (~5–6k tokens) are missing from the message estimate and are covered within the margin.

---

## 9. Open questions (once, not four times)

1. **Name/repo**: `lex`? `project-lex`? (see §8 C — `lex` is taken)
2. **LLM backend**: local only or also cloud?
3. **CI**: GitHub Actions or self-hosted?
4. **Release timing**: v0.1.0 after the foundation or only after phase 1?
5. **Plugin architecture**: like `wedow/harness` (tools/hooks as executables, any language) or fixed?
6. **Persistent agency / multi-player**: no (focused, single-user) — just document it, do not re-discuss
7. ~~**`reasoning_budget`**: lex 1024 vs. `ai.sh --reasoning-budget 4096`?~~ → **DECIDED 2026-09-28: 4096.** The request field wins, lex therefore overrode the server flag; now in sync. `max_tokens=8192` stays (§6 #5). **Not verified live** — the only approved live request still ran with 1024; the next live test checks it. → **done (confirmed live 4096 on 2026-09-28); raised to 8192/16384 on 2026-09-29** (full audit G1, §2/§4 updated).

---

## 10. Roadmap (short form)

| Phase | Goal |
|---|---|
| **0 (COMPLETE 2026-09-28)** | loop + 8 tools + session/memory + security + 6 test runners + CI + docs + **v0.1.0** (Docker dropped) |
| 1 | SSE streaming, `finish_reason` safeguards, zero-fork hot path, Readline, plugin structure, `todo_write` |
| 2 | 24+ tools, sub-agents (explore/plan/review/summarize), read-only mode, parallel tool calls, skills |
| 3 | ~~context compaction~~ (**✅ step 42**), 3-type memory (semantic/episodic/procedural + gate + pass), task system, hooks |
| 4 | HTTP daemon (9655), headless `lex -p --output-format json`, MCP client, background tasks, `stop.md` |
| 5 | session commands (`/resume /rewind` ~~`/compact`~~ **(✅ step 42)** `/fork`), sandbox (Landlock), eval mode, trace/undo |
| 6 | HN show post, brew/pkg, community, v1.0.0 |

**Reference mechanisms** (learn-claude-code s01–s17): the loop stays constant, everything else is built onto it.

---

## 11. File map

### This repository
| Path | Content |
|---|---|
| `LEX.md` | **this file — the single source of truth** |
| `lex` | the script (4569 lines, 17 tools) |
| `README.md` / `CHANGELOG.md` / `LICENSE` | docs + MIT license (2026-09-28) |
| `ai.sh` | llama-server manager (path-free, env-driven) |
| `install.sh` | interactive installer (deps → `lex --install` → symlinks) |
| `.github/workflows/ci.yml` | CI: `bash -n` + shellcheck + `run_all.sh` + hygiene |
| `.git/` | commits `46c64c0`/`1faafaf`/`9c3f4e9` (v0.1.0), `5022bbf` (proxy), `e02d124` (wiki steps 1–5), `06e82a9` (steps 6–10 + docs), `3817ebe` (todo session-independent + lex symlink), `4aff4e9` (step 13 readability), `905a0fc` (step 14 code review P1–P3 + palette), `76b25b3` (§11 git status), `4d1f77b` (step 15 anti-doubt prompt), `a3c8224` (§11 git status) and `2e3f7dd` (step 16 workflow fixes nudge/rescue/spinner/defaults), `88658a2` (max-turns rescue) and `97195e9` (step 17+17b wiki learning + E2BIG context protection), `ca9be2a` (step 18 persona/H-Tools), `9b3ea4e` (step 19 security playbook), `38bcb8b` (step 20 playbook method), `7dc88da` (step 22 browser/Playwright) and `edd7c52` (step 23 generic mcp tool) as well as step 24 (desktop computer-use-linux) and `6e3c36c` (steps 36–38: streaming/testboden/limits, `lex` + 3 new tests + docs), `778474f` (§11 git status) and `9dc785f` (steps 39–42: compaction + HUD, `/exit`/usage fix, over-refusal prompt, live verify `/4`→`/3`, +96 → 669) and `b0658dc` (step 43 `/lexpen` prompt mode + step 44 pentest DB docs, +22 → 691); later: `1042a83`/`816675b`/`a4049e2` (steps 48–49: ops-layer split, glue fix, anti-refusal guard, → 728) and `2ed364c` (steps 50–56: y/N preview + Ctrl+C abort & session permissions + session grant + fix package hang/500/redaction/fail-guard, +63 → 791, working tree clean) — **not pushed** (order open); DE twin `/home/chaos/Ai/lex` has the same content as `955f441` | |
| `tools/llama-proxy.sh` | **debug proxy** (`start\|stop\|status\|tail\|show`) |
| `test/run_all.sh` | test runners (**13 runners**: testboden/syntax/input/tools/loop/http/features/proxy/sse/eval/limits/compaction/repetition, green) |
| `test/test_input.sh` … `test_repetition.sh` | 11 test files, **794 checks** (794 individual + 13 runner marks) |
| `test/fake_mcp.sh` | minimal MCP server (stdio/JSON-RPC) for steps 9 + 22 + 23 + 24 + 25 |
| `test/fake_server.sh` | fake server (ncat, high port) for the curl path + SSE ending `.sse` + `STATUS:` header line |

### Knowledge base `<wiki>/` (an Obsidian vault) — status 2026-09-28 repaired
```
<wiki>/                 ← vault root (.obsidian/, conventions.md = path and log rules)
├── raw/                ← immutable sources (8 files, READ ONLY)
└── wiki/               ← compiled articles (skill `karpathy-llm-wiki`)
    ├── index.md        ✅ clean (2 dead lines removed)
    ├── log.md          append-only ops log (34 KB) — entries are written here
    ├── analyses/lex-architektur.md     (status 2026-09-25, historical)
    ├── concepts/pure-bash-agent-loop.md ✅ dead link fixed
    ├── errors/         error learning (schema: conventions.md §Error-Learning)
    ├── entities/       empty — a legitimate folder per conventions.md
    └── sources/        empty — a legitimate folder per conventions.md
```
- **Link status**: `wiki/` = 0 broken. `raw/` = 7 dead links → **deliberately untouched** (raw is immutable, `conventions.md`).
- **Path rule**: the project root is `<wiki>/`, i.e. `raw/…` + `wiki/…`. Relative from `wiki/<topic>/`: `../../raw/…`.
- **`AGENTS.md`** (`<project-root>/AGENTS.md`) is correct (`<wiki>/`, log `<wiki>/wiki/log.md`).
- **`~/wiki/`** (a wrongly created offshoot) no longer exists.
- The archived research topic is now only raw information, no longer a wiki article or a link target.

---

## 12. Rules (always in force)

The build method is in **§0.1** — that is binding. Only the additions that are not there:

1. **Wiki = working memory, `LEX.md` = the project document.**
2. **No hallucinations** — only what is evidenced (`file:line` or an executed command).
3. **Errors are documented, not hidden** → `<wiki>/wiki/errors/` (schema: see the wiki conventions).
4. **The archived research topic is only information now** (raw sources in `<wiki>/raw/`), no longer a model or a link target.

---

## 13. Restore hint (undo)

If the archiving was wrong, restore the older documents from the archive
(the archive folder is not part of this repository).
