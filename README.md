# lex

A pure-Bash LLM terminal agent (v0.1.0) for a **local** llama-server.
Core dependencies: `bash`, `jq`, `curl` — optionally `node` for the MCP
tools and `python3` for two test fixtures. No Docker, no Python runtime,
no compiled helper.

Full build and operations documentation: **[LEX.md](LEX.md)** (the single
source of truth — read §0 and §0.1 first).

```bash
./install.sh          # interactive: ~/.lex/ + links `lex` and `ai` into ~/.local/bin
./ai.sh start         # start the local llama-server (port 8080)
lex                   # interactive REPL
```

## Requirements

| Tool | Purpose | Missing? |
|---|---|---|
| bash | the script itself (tested on 5.2; no Bash-4-only constructs) | hard requirement |
| jq | JSON for the OpenAI protocol | hard requirement |
| curl | HTTP to the server | hard requirement |
| `timeout`, `realpath`, `readlink -f` | time limit / path normalisation | **fallbacks built in** (`command -v` guard) |
| ncat | fake server used by the tests | only for `test_http.sh` |
| shellcheck | lint | only for CI / development |
| python3 | fake web server (HTML and search fixtures) in `test_features.sh`, JSON helper in `test_proxy.sh` | only for tests |
| node (v20) + MCP servers | `web_fetch`, `context7` | only for those two tools — without them you get a clear error message |

## Quick start

```bash
./install.sh          # interactive setup, every step is asked for first
ai.sh start           # llama-server on port 8080
lex                   # interactive REPL (symlinked to ~/.local/bin/lex, no alias needed)
./lex                 # the same via the full path
./lex --oneshot       # one prompt from stdin, answer to stdout
./lex --status        # config and runtime status
./lex --eval          # trace-level report from the span log (spans.jsonl)
./lex --approve       # REPL, every bash run is confirmed first (needs a TTY)
./lex --install       # create ~/.lex/ (log/, sessions/, mem/, …)
./lex --version       # show version
./lex --help          # modes, slash commands, ENV list (same as /help)
```

REPL slash commands — exactly as listed by `lex --help`:

| Command | Effect |
|---|---|
| `/status` | same as `--status` |
| `/server` | server/port status |
| `/compact` | compress context now (keep summary + tail) |
| `/plan` | show the current plan (todo list) |
| `/lexpen` | set system prompt to the Lex persona (senior-engineer style) |
| `/autosudo` | automatically answer y/N approvals in the sudo gate (`on\|off\|status`) |
| `/lex` | back to the original prompt |
| `/help` | this help |
| `/exit`, `/quit` | leave the REPL (also Ctrl-D) |

## Tools (17)

`read_file`, `write_file`, `edit_file` (with `all` for every occurrence),
`append_file`, `bash`, `list_files` (+ `pattern`, `recursive`), `search`,
`fetch` (raw source into `<wiki>/raw/<topic>/`), `todo` (planning),
`mem_add`, `mem_list`, `mem_search`, plus:

- `web_search(query)` — web search **without an API key** (DuckDuckGo):
  title, URL and snippet, redirects (`uddg=`) and HTML entities resolved
- `web_fetch(url, max_length?)` — a known page as plain text via a
  **crawler** (MCP defuddle), without storing it (for sources you want
  kept, use `fetch(url, topic)`)
- `context7(query, library?)` — **current** library documentation
  (MCP context7), the counterweight to the model's trained knowledge
- `browser(action, …)` — drives a real browser (MCP playwright): navigate
  → snapshot → click/type by ref
- `mcp(server, tool, arguments?)` — generic MCP access, including the
  `desktop` and `postgres` servers

Memory lives as Markdown with YAML frontmatter under `~/.lex/mem/`
(types: `memory`, `fact`, `preference`, `note`).
Every conversation is stored append-only as JSONL under
`~/.lex/sessions/<id>/session.jsonl` — including `reasoning_content`,
which is deliberately **not** written back into the model context
(context protection, see LEX.md §4).

## The system prompt

lex builds exactly one system prompt per session, in this order:

1. **Identity** — "You are Lex — a locally running terminal agent …"
2. **Role & expertise (ethical hacker)** — cybersecurity, penetration
   testing, exploit development, real-time detection, security awareness,
   reporting; the goal is to help organisations defend their systems, and
   the ethical approach guarantees that the work is legal and transparent.
   The persona is a *framing for defensive work* — it does not weaken the
   hard deny list below.
3. **Personality & style** — the rules that shape every answer:
   - **ALWAYS in English** — answers, intermediate steps, files, log entries
   - **Short and effective** — think first, then act; no filler, no preamble
   - **Think decisively, then commit** — no "actually I'm not sure" about
     things just verified
   - **You verify with tools, not in your head** — `bash -n`,
     `./test/run_all.sh`, `search`, `read_file` and the logs are where
     certainty comes from
   - **Never guess, look it up** — `<command> --help` for flags,
     `search`/`web_search`/`web_fetch` for facts, `context7` for libraries
   - **Errors are material** — find the cause, apply the fix, write it into
     `wiki/log.md`; recurring problems get a page in `wiki/errors/`
   - **Your wiki is your memory** — read `index.md` + the newest log lines
     + `mem_search` *before* saying "I don't know"
   - **Back up untrained knowledge** — versions/prices/new APIs are
     verified against the web and anchored in `raw/` + `wiki/`
   - **No doubt loops** — never ask "are you sure?" when the information is
     sufficient; verification replaces self-introspection
4. **The tool list** — one line per tool with its exact signature
5. **Wiki rules** — Karpathy layout: `raw/` is immutable, `wiki/log.md` is
   append-only (`append_file`, never `write_file`), new articles get an
   `index.md` line, sources are linked with `[[wikilinks]]`, everything in
   English, no invented facts
6. **Task rules** — tasks with more than 3 steps go through
   `todo(action=add)` first; read before editing; security/playbook,
   browser, desktop and database procedures; software always goes to
   `$LEX_HTOOLS_DIR` (default `$HOME/H-Tools`), never `$HOME`, never `/tmp`
7. **Wiki state** — `index.md`, the last 40 lines of `log.md` and a
   `mem_search` result are appended, so the agent starts every session
   with its own memory in context

The prompt is not cast in stone: `/lexpen` swaps the system prompt for
the Lex persona (senior-engineer style) and `/lex` restores the original
one — `--status` shows the active mode (`prompt : lexpen …` or
`standard`).

The whole prompt is visible at any time:

```bash
./lex --status | head -40        # config + wiki excerpt
LEX_TRACE=1 ./lex --oneshot hi    # everything lex does, on stderr
```

## Why this llama.cpp fork

lex talks the OpenAI protocol to a local `llama-server`. Two things it
relies on are **not** in upstream `ggml-org/llama.cpp`:

| What lex uses | Why |
|---|---|
| `--reasoning on/off/auto`, `--reasoning-effort`, `--reasoning-budget`, `--reasoning-budget-message`, `--reasoning-preserve` | the server puts the thinking into `message.reasoning_content` of the OpenAI response — that is what lex renders as `⚙ thinking:` and what it stores (but never re-sends) |
| `--cache-ram`, `--ctx-checkpoints`, `--cache-idle-slots` | lets a 262 144-token context live on a 16 GB card by spilling KV to system RAM |
| `--spec-type ngram-mod` (+ `--spec-ngram-mod-n-*`) | ngram speculative decoding, big speedup on long generations |
| `--kv-mean-center <file>` | per-(head,channel) K-cache bias for the ternary Bonsai models |
| `PQ2_0` / Bonsai model support | 27 B ternary model that actually fits next to a large KV cache |

That is the fork: **<https://github.com/PrismML-Eng/llama.cpp>**, branch
`prism`. It carries the Bonsai/ternary model family, the PQ2_0 low-bit
quantisation for weights and KV cache, the `--reasoning` surface, and
dspark/ngram speculative decoding.

Upstream `llama.cpp` still works — start it without the flags listed
above and lex degrades gracefully: `reasoning_content` is simply absent,
so there is no `⚙ thinking:` block, and the context size is whatever your
VRAM allows. Everything else (tools, sessions, memory, wiki) is
independent of the server build.

## Running it on a 16 GB VRAM GPU

Reference setup: **AMD RX 7700/7800 XT (16 GB)**, model
**Ternary-Bonsai-2-27B-PQ2_0.gguf** (≈ 6.8 GB on disk), context
**262 144** tokens with a single slot.

```bash
llama-server -m Ternary-Bonsai-2-27B-PQ2_0.gguf \
  -ngl 99 -fa on \
  -c 262144 -np 1 \
  -b 2048 -ub 1024 \
  -ctk q4_0 -ctv q4_0 \
  --ctx-checkpoints 32 \
  --cache-ram 8192 \
  --cache-idle-slots \
  --spec-type ngram-mod \
  --spec-ngram-mod-n-match 24 --spec-ngram-mod-n-min 48 --spec-ngram-mod-n-max 64 \
  --temp 1.0 --top-p 0.95 --top-k 20 --min-p 0.05 \
  --predict 8192 \
  --reasoning on --reasoning-effort medium \
  --reasoning-budget 4096 --reasoning-preserve \
  --jinja \
  --host 127.0.0.1 --port 8080
```

What each group is for:

| Flag | Meaning |
|---|---|
| `-ngl 99` | push all layers into VRAM (99 = "as many as fit") |
| `-fa on` | FlashAttention — required for long contexts, also saves VRAM |
| `-c 262144` | total context; with `-np 2` each slot gets `262144 / 2` |
| `-np` | slots = parallel clients; 1 slot = one client with the full context |
| `-b 2048`, `-ub 1024` | prompt/ubatch size — small on purpose so the compute buffer does not eat into the KV cache |
| `-ctk q4_0`, `-ctv q4_0` | KV cache quantised to 4 bit; this is what makes 262k context affordable |
| `--cache-ram 8192` | keep up to 8 GiB of evicted KV in **system RAM**, so the context survives slot churn |
| `--ctx-checkpoints 32` | snapshot the context periodically → fast recovery after a long generation |
| `--cache-idle-slots` | park idle slots in the prompt cache (needs `--cache-ram`) |
| `--spec-type ngram-mod` + `--spec-ngram-mod-n-*` | ngram speculative decoding: predict the next tokens from the ngram cache and verify them in one batch |
| `--temp/--top-p/--top-k/--min-p` | sampling; the low `min-p 0.05` keeps the tail of a reasoning model from wandering |
| `--reasoning on` + `--reasoning-effort medium` + `--reasoning-budget 4096` | thinking on, medium effort, at most 4096 tokens of thought per turn |
| `--reasoning-budget-message "…"` | text injected when the budget runs out, telling the model to commit to the best answer instead of doubting |
| `--reasoning-preserve` | keep the reasoning trace in the history, not just in the last assistant message |
| `--jinja` | render the chat template (pair it with `--chat-template-file` for a custom one) |

`./ai.sh` runs exactly this command line. Everything is configurable
through the environment — no file needs editing:

```bash
AI_MODE_DIR=$HOME/ai-models AI_LLAMA_BIN=$HOME/llama.cpp-prism/build/bin/llama-server ./ai.sh start
./ai.sh start 2     # split: 2 slots x 131072, separate KV cache per slot
./ai.sh status
./ai.sh stop
```

VRAM budget in short: ~7 GB weights + FlashAttention + a q4_0 KV cache
for the tokens actually in use. The rest of the 262k context is spooled
to RAM by `--cache-ram`, which is why a 16 GB card can hold a context
that would otherwise need far more VRAM.

## Interface (CLI with a TUI feel)

No curses TUI — but structured output, all via ANSI and without new
dependencies:

- `lex>` prompt (blue/bold, TTY only — without a terminal, or with
  `NO_COLOR`, it stays colourless), input via **Readline**: arrow keys,
  Ctrl-A/E/W/U, **Tab = path completion**, history under
  `~/.lex/history` (500 entries, across sessions)
- `⚙ thinking:` — what the model thought (`reasoning_content`): header
  dim-magenta, content **grey and indented** on stderr — deliberately
  separated so thinking and answer are never confused; off with
  `LEX_SHOW_REASONING=0`, truncation via `LEX_REASONING_MAX` (default 4000)
- `⏳ thinking …` spinner while generating (starts only after 250 ms)
- `⚙ tool args` for running tools: name **bold cyan**, arguments grey;
  `↳ tool` (cyan-dim) with an indented return value truncated to 8 lines
- `⏱ 3.2s · turn 2/50 · tokens 1409/262144 (1%) prompt + 69 completion` —
  with a context limit the HUD shows the fill level as `X/Y (Z%)` (without
  a limit the plain `tokens N` form stays, missing usage shows `?`) — and the
  line appears **before** the answer, so the answer is the last thing on
  screen (otherwise it visually drowns)
- final answer with markdown lighting: H1 **bold + underlined** (instead
  of "white" — invisible on a light terminal), H2 **bold cyan**, H3 cyan,
  `**bold**`, `` `code` ``, `[[wikilinks]]`, quotes, warning orange,
  `❌`/`Error:` red, `✓` green, links cyan+underlined, **pipe tables**
  aligned properly (header cyan/bold, grid dim, right-aligned at `:---`)

All sequences go through one central palette: **`NO_COLOR`** and
`TERM=dumb` switch colours completely off (standard convention,
https://no-color.org), `LEX_TRACE=1` shows the trace without a terminal.

Only the answer itself goes to **stdout** — everything else runs on
**stderr** and only with a terminal (or `LEX_TRACE=1`). Pipes, files and
tests therefore stay raw and unchanged.

## Context compaction, spill & guards

- **Context compaction** (automatic, plus `/compact` as a force): as soon
  as the estimated context — `wc -c` divided by 3, i.e. roughly 3 bytes
  per token, deliberately conservative — reaches `LEX_CTX_LIMIT −
  max(LEX_MAX_TOKENS, LEX_COMPACT_BUFFER)` (defaults 262144 − 20000 =
  242144), the head of the history is replaced by a summary the model
  writes itself into a fixed Markdown template (`## Goal`,
  `## Key details`, `## Status` with Done / In progress / Blocked,
  `## Next step`, `## Relevant files`), keeping the newest units as the
  tail (`LEX_COMPACT_KEEP`, default 15000). Pairing gates keep assistant
  tool calls and their results together, the prior summary is merged
  instead of stacked, and every error path leaves the context
  **byte-identical** (fail-safe: nothing is compacted if the summary
  fails). `LEX_COMPACT=off` switches it off; `--status` prints a
  `compact` line plus a `ctx` line with the fill level, and each
  compaction is logged and recorded in the session.
- **Spill instead of silent truncation**: a tool result larger than
  `LEX_TOOL_MAX_OUTPUT` (default 50000) is not cut off — the full output
  is stored under `~/.lex/toolout/` (the 100 newest spills are kept) and
  the context gets the head plus the path and a hint to reload it with
  `read_file`.
- **Repetition-loop detection**: `_rep_detect` looks only at the visible
  answer (code blocks and table rows masked, reasoning and tool
  arguments out of scope) and finds a trailing run (`A1`), an identical
  sentence repeated ≥ 4× (`A2`) or a duplicate 4-gram share ≥ 0.35 from
  70 4-grams (`A3`). The guard answers with a **budget**: soft nudge →
  hard nudge → a truncated render of the first 2000 characters. The
  budget is the shared nudge counter `LEX_MAX_NUDGES` (default 4), so
  repetition and empty answers cannot spin forever; every step is logged
  and written to the session as `{type:repetition}`.
- **`/autosudo` (on|off|status, `LEX_AUTOSUDO=1`)** — auto-approves the
  `y/N` question of the sudo gate so an unattended run does not stall at
  it; password prompts and other TTY questions stay manual (mechanics
  under Security).

## MCP & web search

Two bundled MCP servers run over **stdio** (JSON-RPC 2.0), one session
per call:

| Server | Tool(s) | Start command |
|---|---|---|
| `defuddle` | `web_fetch` | `node ~/.mcp/node_modules/defuddle-stdio-mcp/index.js` |
| `context7` | `context7` | `~/.local/bin/context7-mcp` |

Three more servers are part of the **default config** in `_mcp_config()`
(they are generic, not bundled — reachable through `mcp(server, …)`):

| Server | What it gives lex |
|---|---|
| `playwright` | real browser control (`browser` tool: navigate → snapshot → click/type by ref) |
| `desktop` | GUI without a CLI (`computer-use-linux`: screen state, mouse, keyboard) |
| `postgres` | **SQL over MCP** — see below |

**Postgres is wired in.** lex ships with a default `postgres` entry in
`_mcp_config()`:

```json
"postgres": { "command": "~/.lex/pg/dbhub.sh",
              "args": ["--dsn", "postgres://lex@127.0.0.1:5432/lex?sslmode=disable"] }
```

- MCP server: **`@bytebase/dbhub`** (stdio, tools `execute_sql` +
  `search_objects`, read/write), started by the wrapper `~/.lex/pg/dbhub.sh`
- Database: your **own `lex` database** on `127.0.0.1:5432` — the reference
  setup runs PostgreSQL **user-space under `~/.lex/pg`** (no sudo, own
  socket, trust auth on localhost, start/stop via `~/.lex/pg/start.sh`)
- The system prompt enforces the workflow: *database tasks → first
  `mcp(postgres, '__tools')` for the real tool list, then SQL — and only
  ever the own `lex` database*
- No Postgres running? The call fails with a clear error; everything else
  is unaffected

The locations for all servers live in **`~/.lex/mcp.json`** (without the
file the defaults above apply); `LEX_MCP=0` switches the MCP tools off and
`LEX_MCP_TIMEOUT` (seconds, default 60) bounds every call.
The web search (`web_search`) does not use MCP — it goes straight to
DuckDuckGo HTML, `LEX_SEARCH_URL` allows a different endpoint (the tests
use that so **no test ever goes to the network**).

## Security

- `tool_bash` has a **hard deny list that is always on** and splits the
  command into **segments** (`&&`, `||`, `|`, `;`, newline):
  - rm at the filesystem root or the home directory — also as `rm -rf -- /`, `rm -Rf /`,
    `rm --no-preserve-root -rf /`, `sudo rm -rf /`, `xargs rm -rf /`
  - downloads into a shell — also as `curl … | sh | cat` or
    `curl … && sh x.sh` (not just the last pipe); `curl … | cat` and
    `curl … | grep sh` stay allowed
  - `su` as a command word (`su postgres -c …`, also behind `sudo`)
  - block devices (`mkfs`, `of=/dev/`, `dd … of=/dev/…`), fork bombs,
    shutdown/reboot, killing system processes, recursively loosening
    permissions, `history -c`
- **sudo is not a ban but a gate** (LEX.md §6 #13): the first `sudo`
  command produces **exactly one prompt** on the terminal — with the
  command, and you type your password straight into the sudo prompt. The
  password goes **directly to sudo**, never through lex (no variable, no
  log). If the sudo ticket is already valid, `y/N` is asked instead.
  Without a controlling TTY there is no sudo run. `LEX_SUDO=0` blocks
  sudo completely, `LEX_SUDO_APPROVE=0` drops the `y/N` question for a
  valid ticket. `/autosudo on` (or `LEX_AUTOSUDO=1`) answers that same
  `y/N` approval live, without a restart — the mode for unattended runs;
  password prompts are never answered automatically.
- **Opt-in** approval gate for **all** bash runs: only with `--approve`
  or `LEX_APPROVE=1` and a controlling TTY is every run confirmed —
  without the flag the agent runs prompt-free (tests stay deterministic).
  The sudo gate applies **independently** of this.
- `safe_path` only allows paths outside `/etc`, `/usr`, `/bin`, `/sbin`,
  `/boot`, `/dev`, `/proc`, `/sys`, `/var`, `/lib`, `/lib64`, `/root` —
  **including the bare roots** (`/etc`, not just `/etc/…`) — and
  **symlink targets** are resolved and checked.

## Configuration (4 tiers)

`defaults → ~/.lex/settings.json → .lex/settings.json (CWD) → ENV`

Important ENV variables — the exact list from `usage()` / `lex --help`:
`LEX_API_URL`, `LEX_API_KEY`, `LEX_MODEL`, `LEX_MAX_TOKENS`,
`LEX_REASONING_BUDGET`, `LEX_TEMPERATURE`, `LEX_MAX_TURNS`,
`LEX_TOOL_TIMEOUT`, `LEX_TOOL_MAX_OUTPUT`, `LEX_CTX_LIMIT`,
`LEX_COMPACT`, `LEX_COMPACT_KEEP`, `LEX_COMPACT_BUFFER`, `LEX_LOG_DIR`,
`LEX_MOCK`, `LEX_MOCK_FILE`, `LEX_APPROVE`, `LEX_SUDO`, `LEX_SUDO_APPROVE`,
`LEX_AUTOSUDO`, `LEX_SESSION`, `LEX_MEM_DIR`, `LEX_WIKI_DIR`,
`LEX_HTOOLS_DIR`, `LEX_TRACE` (force trace/HUD/spinner on stderr),
`LEX_SHOW_REASONING` (0 = no thinking block), `LEX_REASONING_MAX`
(truncation), `LEX_MCP`/`LEX_MCP_TIMEOUT` (MCP on/off and time limit),
`LEX_SEARCH_URL`/`LEX_SEARCH_TIMEOUT` (search endpoint and time limit).

The compaction block in detail: `LEX_CTX_LIMIT` is the context size used
for threshold and HUD (default 262144), `LEX_COMPACT` is `on|off`
(default `on`), `LEX_COMPACT_KEEP` sizes the tail kept after a compaction
(default 15000, budgeted as `keep × 4` bytes) and `LEX_COMPACT_BUFFER`
the reserve below the limit that stays free for the answer (default
20000) — the threshold is `LEX_CTX_LIMIT − max(LEX_MAX_TOKENS,
LEX_COMPACT_BUFFER)`.

## Tests

```bash
./test/run_all.sh          # 13 runners / 726 checks (726 PASS + 1 SKIP), exit 0 only when all are green
shellcheck -S warning lex ai.sh install.sh test/*.sh tools/*.sh
```

13 runners over 11 test files: the first two are gates — `testboden`
(every runner named in `run_all.sh` exists and is executable, no test
file deleted against HEAD, no present test file left unwired) and
`syntax` (`bash -n` on `lex` and `tools/llama-proxy.sh`) — followed by
`input`, `tools`, `loop`, `http`, `features`, `proxy`, `sse`, `eval`,
`limits`, `compaction`, `repetition`.

The tests run **without network and without a server** — either with
`LEX_MOCK=done` (static), `LEX_MOCK_FILE` (sequence, source file left
untouched) or the bundled fake server (`test/fake_server.sh`). A real
request to `127.0.0.1:8080` never happens in the tests. The MCP tests
run against `test/fake_mcp.sh` (minimal stdio server), the search tests
against a local `python3 -m http.server` with a fixture.

## Observability (`lex --eval`)

Every tool run is appended as one JSONL line to `<log-dir>/spans.jsonl`
(`ts`, `name`, `args_hash`, `duration_ms`, `ok`) — the span-level layer.
`cmd_eval()` aggregates that log into a trace-level report:

```bash
./lex --eval                    # report over ~/.lex/log/spans.jsonl
./lex --eval <file>             # a specific span file
cat ~/.lex/log/spans.jsonl      # raw spans
```

```
=== Trace-level evaluation (lex --eval) ===
Spans file: ~/.lex/log/spans.jsonl
Tool calls: 4 (total duration: 0s)
FAILED: 1 of 4 tool calls failed

Per tool:
  bash: 170ms, 1 failures
  read_file: 25ms, 0 failures
```

The timing comes from `_ms_now()` (millisecond clock, falls back to whole
seconds where `date +%N` is not available), `ok` is the exit status of the
tool branch that just ran. The file is created on the first tool call —
until then `lex --eval` reports "No span log found".

## Debug proxy (read the traffic)

```bash
LEX_PROXY_UPSTREAM=http://127.0.0.1:8080 ./tools/llama-proxy.sh start 24480
LEX_API_URL=http://127.0.0.1:24480/v1/chat/completions ./lex --oneshot   # drive lex through it
./tools/llama-proxy.sh show 1     # n-th request AND response, raw + pretty
./tools/llama-proxy.sh tail 20    # traffic.log (status, bytes, rb, finish, reasoning)
./tools/llama-proxy.sh status     # or: stop
```

The proxy forwards to the llama-server and logs both sides under
`.proxy/` (gitignored). It listens **only on 127.0.0.1** and refuses
port 8080.

## Structure

```
lex              the agent — one file, 4023 lines, 17 tools
ai.sh            llama-server launcher (all paths via environment)
install.sh       interactive setup
LEX.md           working document (state, bugs, roadmap)
tools/           llama-proxy.sh (debug proxy to the llama-server)
test/            run_all.sh + 11 test files + fake_server.sh + fake_mcp.sh
.github/         CI (shellcheck + run_all.sh + installer smoke test)
```

## License

MIT — see [LICENSE](LICENSE).
