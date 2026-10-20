# lex

[![lex CI](https://github.com/ch405canova-sudo/Lex-Bash-Agent/actions/workflows/ci.yml/badge.svg)](https://github.com/ch405canova-sudo/Lex-Bash-Agent/actions)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
![version](https://img.shields.io/badge/version-0.4.0-blue)
![tests](https://img.shields.io/badge/tests-15%20runner%20%C2%B7%201055%20checks-brightgreen)

**A terminal agent for a local LLM, written in pure Bash.** One executable
file, no runtime, no framework, no Docker: `bash`, `jq` and `curl` are the
only hard dependencies. lex talks the OpenAI chat protocol to a local
`llama-server`, runs tools on your machine, keeps its own memory — and never
leaves the endpoint you configure.

- **19 tools** (files, shell, search, web, browser, MCP, sub-agents, background tasks)
- **15 test runners / 1055 checks**, all offline — mocks plus a fake HTTP server, never port 8080
- **State lives in `~/.lex/`** — nothing is written outside `$HOME`
- **Security built in**: hard deny-list, sudo gate, opt-in approval mode, hooks, self-edit sandbox
- Language: lex itself answers in **German** (by design). Docs are bilingual.

**Documentation:** [docs/ARCHITEKTUR.md](docs/ARCHITEKTUR.md) ·
[docs/KONFIGURATION.md](docs/KONFIGURATION.md) · [CHANGELOG.md](CHANGELOG.md)
· deutsch: [README.de.md](README.de.md)

---

## Quick start

```bash
git clone https://github.com/ch405canova-sudo/Lex-Bash-Agent.git
cd Lex-Bash-Agent

./install.sh      # interactive: checks deps, creates ~/.lex/, links `lex` and `ai` into ~/.local/bin
./ai.sh start     # start the local llama-server (port 8080) — or use your own
lex               # REPL
```

Every command has a non-interactive form as well:

```bash
./lex --oneshot       # one prompt from stdin, answer to stdout
./lex --status        # configuration + runtime status
./lex --approve       # REPL, every shell command is confirmed first (needs a TTY)
./lex --eval          # report from the span log (spans.jsonl)
./lex --install       # create ~/.lex/ (log/, sessions/, mem/, …)
./lex --version       # lex 0.4.0
./lex --help          # modes, slash commands, ENV list
```

Nothing has to be configured first: lex defaults to
`http://127.0.0.1:8080/v1/chat/completions` and falls back to a mock mode
(`LEX_MOCK=done`) so you can try it without any server.

## Requirements

| Tool | Purpose | Missing? |
|---|---|---|
| Bash ≥ 4 | the script itself (`coproc`; tested on 5.2 — macOS system bash 3.2 is not enough: `brew install bash`) | hard requirement |
| jq | JSON for the OpenAI protocol | hard requirement |
| curl | HTTP to the server | hard requirement |
| `timeout`, `realpath`, `readlink -f` | time limits / path normalisation | **fallbacks built in** (`command -v` guard) |
| ncat | fake server used by `test_http.sh` | only for tests |
| shellcheck | lint | only for CI / development |
| python3 | HTML/search fixtures in `test_features.sh`, JSON helper in `test_proxy.sh` | only for tests |
| node (v20) + MCP servers | `web_fetch`, `context7`, `browser`, `mcp` | only those tools — without them you get a clear error message |

## REPL slash commands

Exactly as printed by `lex --help`:

| Command | Effect |
|---|---|
| `/status` | same as `--status` |
| `/server` | server/port status |
| `/compact` | compress the context now (summary + tail kept) |
| `/plan` | show the current plan (todo list) |
| `/lexpen` | switch the system prompt to the Lex persona (senior-engineer style) |
| `/lex` | back to the original prompt |
| `/autosudo` | answer the sudo gate's y/N prompts automatically (`on`/`off`, any other value prints the current status) |
| `/help` | this help |
| `/exit`, `/quit` | leave the REPL (also Ctrl-D) |

The prompt marker shows the active mode (`lex>` or `lex*>`); slot 0 of the
context is exclusive, one mode always displaces the other.

## Tools (19)

`read_file`, `write_file`, `edit_file` (with `all` for every occurrence),
`append_file`, `bash`, `list_files` (+ `pattern`, `recursive`), `search`,
`fetch` (raw source into `<wiki>/raw/<topic>/`), `todo` (planning),
`mem_add`, `mem_list`, `mem_search`, plus:

- **`web_search(query)`** — search **without an API key** (DuckDuckGo): title,
  URL and snippet, redirects (`uddg=`) and HTML entities resolved;
  `LEX_SEARCH_URL` swaps the endpoint (the tests use it so no test goes online)
- **`web_fetch(url, max_length?)`** — a known page as plain text via a
  **crawler** (MCP defuddle), not stored — for sources you want kept use
  `fetch(url, topic)`
- **`context7(query, library?)`** — **current** library documentation (MCP
  context7), the counterweight to the model's trained knowledge
- **`browser(action, …)`** — drives a real browser (MCP playwright): navigate
  → snapshot → click/type by ref; the snapshot is text, no screenshots
- **`mcp(server, tool, arguments?)`** — generic MCP access, `__tools` gives the
  discovery list first
- **`agent(task, mode)`** — sub-agent with a **fresh context**
  (explore/plan/review/summarize), depth gate, result is plain text
- **`task(action, …)`** — **background tasks** (`start/list/status/result/kill`)
  under `~/.lex/tasks/<id>/`, own session, readable after lex exits

### Memory and sessions

Memory is Markdown with YAML frontmatter under `~/.lex/mem/` (types
`memory`, `fact`, `preference`, `note`). `type: preference` entries are
injected directly behind the system prompt (newest wins, gates
`LEX_MEM_PREF=off`, budgets `LEX_MEM_PREF_MAX`/`LEX_MEM_PREF_TOTAL`).

Every conversation is stored append-only as JSONL in
`~/.lex/sessions/<id>/session.jsonl` — including `reasoning_content`, which
is deliberately **not** written into the model context (context protection).
`session_write` redacts each line before appending, so no secret lands on disk.

## Interface (CLI with a TUI feel)

No curses — structured output over ANSI, no new dependencies:

- `lex>` prompt (blue/bold, TTY only; `NO_COLOR` and `TERM=dumb` disable all
  colour), **Readline** editing: arrows, Ctrl-A/E/W/U, **Tab = path
  completion**, history in `~/.lex/history`
- `⚙ denken:` — what the model thought (`reasoning_content`): dim-magenta
  header, grey and indented on **stderr**, off with `LEX_SHOW_REASONING=0`
- `⏳ denke …` spinner after 250 ms, `⚙ tool args` for running tools,
  `↳ tool` with the indented result
- `⏱ 3,2s · turn 2/50 · tokens 1409/180224 (1%) prompt + 69 completion` —
  timing and context usage are printed **before** the answer, so they are the
  last thing on screen
- Markdown light for the answer: H1 bold+underlined, H2 bold cyan, tables
  aligned, `[[wikilinks]]`, warnings orange, errors red, `✓` green
- **Only the answer goes to stdout** — everything else runs on stderr and only
  on a terminal (or with `LEX_TRACE=1`), so pipes, files and tests stay raw

## Context compaction

lex estimates the prompt (`bytes ÷ 3`, calibrated live against
`prompt_tokens`) and, once it reaches
`ctx − max(max_tokens, buffer)` (default **160224** of **180224**), folds older
messages into a summary (marker `<!--lex-compact-->`, context integrity as
gate — if the summary comes back empty, nothing changes). `/compact` forces a
run, `LEX_COMPACT=0` disables it, `LEX_COMPACT_KEEP`/`LEX_COMPACT_BUFFER`
adjust tail/threshold, `LEX_CTX_LIMIT` sets the assumed context size. An 85 %
warning fires independently of the switch.

## MCP & web search

Two embedded MCP servers run over **stdio** (JSON-RPC 2.0), one session per
call:

| Server | Tool(s) | Default start command |
|---|---|---|
| `defuddle` | `web_fetch` | `node ~/.mcp/node_modules/defuddle-stdio-mcp/index.js` |
| `context7` | `context7` | `~/.local/bin/context7-mcp` |

Locations live in **`~/.lex/mcp.json`** (without that file the defaults
above, plus `playwright` and `desktop`, apply). `LEX_MCP=0`
disables both tools, `LEX_MCP_TIMEOUT` (default 60 s) caps every call.
Discovery results are cached in `~/.lex/mcp.cache.json`, so `--status` can
show the full native tool set.

## Security

- **`tool_bash` has a hard deny-list that is always active** and splits the
  command into segments (`&&`, `||`, `|`, `;`, newline):
  - `rm` on root/home/`.` — including `rm -rf -- /`, `sudo rm -rf /`, `xargs rm -rf /`
  - piping a download into a shell — including `curl … | sh | cat`
  - `su` as a command word, block devices (`mkfs`, `of=/dev/`, `dd … of=/dev/…`),
    fork bombs, shutdown/restart, killing system processes, `history -c`
- **sudo is a gate, not a ban**: without a valid ticket lex shows **exactly one**
  prompt on the TTY with the command — the password goes straight to sudo and
  never through lex (no variable, no log). With a valid ticket lex asks **once
  per session** (`sudo für diese ganze Sitzung freigeben? (y/N)`). No
  controlling TTY → clean refusal. `LEX_SUDO=0` blocks sudo entirely,
  `LEX_SUDO_APPROVE=0` removes the session question.
- **Opt-in approval for every shell command**: only with `--approve` or
  `LEX_APPROVE=1` *and* a controlling TTY — without the flag lex runs
  prompt-free, which keeps tests deterministic.
- **`safe_path`** only allows paths outside `/etc`, `/usr`, `/bin`, `/sbin`,
  `/boot`, `/dev`, `/proc`, `/sys`, `/var`, `/lib`, `/lib64`, `/root` — bare
  roots included, and symlink targets are resolved and checked.
- **Hooks**: executables in `~/.lex/hooks/pre_tool/` (rc ≠ 0 blocks the tool
  call) and `~/.lex/hooks/post_tool/` (observing), `LEX_HOOKS=off`,
  `LEX_HOOK_TIMEOUT`, per-run `LEX_HOOK_EVENT/TOOL/ARGS/RC`.
- **Self-edit sandbox**: an edit whose target is the `lex` script itself runs
  against a copy and must pass **two gates** (`tools/selfcheck_lex.sh`, then the
  full `test/run_all.sh`) before it is promoted atomically; a failing gate
  leaves the original byte-identical.
- **Redaction**: `_redact` masks credentials in logs, sessions, display and
  wiki writes; oversized tool output is spilled to disk
  (`~/.lex/log/tool_spill/`, mode 600) instead of being truncated silently.

## Configuration (4 tiers)

```
Defaults → ~/.lex/settings.json → .lex/settings.json (current directory) → ENV
```

Important ENV variables: `LEX_API_URL`, `LEX_MODEL`, `LEX_API_KEY`,
`LEX_MAX_TOKENS`, `LEX_REASONING_BUDGET`, `LEX_TEMPERATURE`, `LEX_MAX_TURNS`,
`LEX_TOOL_TIMEOUT`, `LEX_TOOL_MAX_OUTPUT`, `LEX_LOG_DIR`, `LEX_MOCK`,
`LEX_MOCK_FILE`, `LEX_APPROVE`, `LEX_SUDO`, `LEX_SUDO_APPROVE`, `LEX_SESSION`,
`LEX_MEM_DIR`, `LEX_WIKI_DIR`, `LEX_HTOOLS_DIR`, `LEX_TRACE`,
`LEX_SHOW_REASONING`, `LEX_REASONING_MAX`, `LEX_MCP`, `LEX_MCP_TIMEOUT`,
`LEX_SEARCH_URL`, `LEX_SEARCH_TIMEOUT`, `LEX_CTX_LIMIT`, `LEX_COMPACT`,
`LEX_COMPACT_KEEP`, `LEX_COMPACT_BUFFER`, `LEX_API_RETRIES`, `LEX_LOOP_GUARD`,
`LEX_SELFEDIT_GATES` — full list in `lex --help`, details in
[docs/KONFIGURATION.md](docs/KONFIGURATION.md).

## Tests

```bash
./test/run_all.sh          # 15 runners / 1055 [PASS], exit 0 only if everything is green
shellcheck -S warning lex ai.sh install.sh test/*.sh tools/*.sh
```

The first runner is **`testboden`**: it aborts if a test file was deleted, is
referenced by the runner but missing, or exists but is not wired in. Tests are
assert-based (`[ "$out" = "expected" ]`), print to stdout and exit 1 on
failure.

Rules the suite follows:

- **No network and no server** — `LEX_MOCK=done` (static), `LEX_MOCK_FILE`
  (sequence, source file untouched) or the bundled fake server
  (`test/fake_server.sh` over `ncat`). A real request to `127.0.0.1:8080`
  never happens.
- The **HTTP path is covered too**: `test/test_http.sh` runs a real fake
  server; `test/test_sse.sh` covers streaming (delta fusion, `data:` without a
  space, missing `[DONE]`, server gone, HTTP errors) **including a performance
  budget** (3000 chunks < 2 s with content checks — this used to take 29 s).
- Fixture tests must also be able to **break** the path: red runs are part of
  the definition of done, not just green ones.

## Observability

Every `dispatch_tool` call appends a span to `~/.lex/log/spans.jsonl`
(`ts`, `name`, `args_hash`, `duration_ms`, `ok` — arguments are stored as a
checksum, not as payload):

```bash
./lex --eval                 # current session
./lex --eval /path/spans.jsonl
```

The report gives a verdict, a per-tool section and the last spans.

The API path is hardened against both streaming and classic JSON answers:
curl's exit code **and** the HTTP status are checked, `tool_calls` are fused
across all deltas, `usage` comes from the stream, and a missing `[DONE]` is
reported explicitly. 429/5xx and curl errors are retried
(`LEX_API_RETRIES`, default 2, clamped ≤ 10, backoff 0.8 → 8 s with jitter).

## Debug proxy (read the traffic)

```bash
LEX_PROXY_UPSTREAM=http://127.0.0.1:8080 ./tools/llama-proxy.sh start 24480
LEX_API_URL=http://127.0.0.1:24480/v1/chat/completions ./lex --oneshot
./tools/llama-proxy.sh show 1     # n-th request AND response, raw + indented
./tools/llama-proxy.sh tail 20    # traffic.log
./tools/llama-proxy.sh status | stop
```

It logs to `.proxy/` (gitignored), listens **only on 127.0.0.1** and refuses
port 8080.

## Repository layout

```
lex                 the agent — one file (6242 lines, 19 tools)
install.sh          interactive setup (~/.lex/ + links into ~/.local/bin)
ai.sh               llama-server launcher (start/stop/status, configurable via env)
test/               run_all.sh + 13 test files + fake_server.sh + fake_mcp.sh (15 runners)
tools/              selfcheck_lex.sh, llama-proxy.sh, pentest_mcp.sh,
                    ctx_bench.sh, werkstatt_index.sh, amnesie_test_setup.sh
docs/               ARCHITEKTUR.md, KONFIGURATION.md
.github/workflows/  CI: bash -n → shellcheck → run_all → installer → hygiene check
```

## License

[MIT](LICENSE) — Copyright (c) 2026 ch405canova-sudo.
