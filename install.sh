#!/usr/bin/env bash
#
# install.sh — interactive setup for lex.
#
#   ./install.sh
#
# What it does (every step is asked for first):
#   1. check the dependencies (bash, jq, curl, nc/ncat)
#   2. create ~/.lex/ + settings.json          (./lex --install)
#   3. link ./lex  into ~/.local/bin/lex
#   4. link ./ai.sh as ~/.local/bin/ai         (llama-server launcher)
#
# Nothing is written outside $HOME, and every question can be skipped with
# "n" (default is always no). Without a TTY it only prints the steps.
#
set -u

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEX_BIN="$REPO_DIR/lex"
AI_BIN="$REPO_DIR/ai.sh"
BIN_DIR="${LEX_BIN_DIR:-$HOME/.local/bin}"

say()  { printf '%s\n' "$*"; }
head1() { printf '\n== %s\n' "$*"; }

# ask "question" -> 0 = yes, 1 = no (default no)
ask() {
  local q="$1"
  if [ ! -t 0 ] || [ ! -t 1 ]; then
    return 1
  fi
  local a=""
  printf '%s [y/N] ' "$q"
  IFS= read -r a || return 1
  case "$a" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

say "lex installer"
say "repo: $REPO_DIR"

# ---------------------------------------------------------------- 1. deps
head1 "dependencies"
missing=""
for c in bash jq curl; do
  if command -v "$c" >/dev/null 2>&1; then
    printf '  ok   %s\n' "$c"
  else
    printf '  miss %s\n' "$c"
    missing="$missing $c"
  fi
done
if command -v ncat >/dev/null 2>&1; then
  printf '  ok   ncat\n'
elif command -v nc >/dev/null 2>&1; then
  printf '  ok   nc\n'
else
  printf '  miss ncat (only needed for test/fake_server.sh)\n'
fi
if [ -n "$missing" ]; then
  say ""
  say "missing:$missing"
  say "install them first (Debian/Ubuntu: sudo apt-get install jq curl)"
fi

if [ ! -x "$LEX_BIN" ]; then
  if [ -f "$LEX_BIN" ]; then
    chmod +x "$LEX_BIN"
    say "chmod +x lex"
  else
    say "err lex not found at $LEX_BIN"
    exit 1
  fi
fi

# ------------------------------------------------------------ 2. ~/.lex/
head1 "state directory"
if ask "create ~/.lex/ + settings.json now?"; then
  if "$LEX_BIN" --install; then
    say "done"
  else
    say "err lex --install failed"
  fi
else
  say "skipped (run later: lex --install)"
fi

# --------------------------------------------------------- 3. lex symlink
head1 "command lex"
if ask "link lex into $BIN_DIR (adds it to your PATH)?"; then
  mkdir -p "$BIN_DIR" || { say "err cannot create $BIN_DIR"; exit 1; }
  ln -sfn "$LEX_BIN" "$BIN_DIR/lex"
  say "ok   $BIN_DIR/lex -> $LEX_BIN"
  case ":$PATH:" in
    *":$BIN_DIR:"*) say "     $BIN_DIR is already in PATH" ;;
    *) say "     add it to PATH:  export PATH=\"$BIN_DIR:\$PATH\"" ;;
  esac
else
  say "skipped"
fi

# ----------------------------------------------------------- 4. ai symlink
head1 "command ai (llama-server launcher)"
if [ -f "$AI_BIN" ]; then
  if ask "link ai.sh into $BIN_DIR/ai?"; then
    mkdir -p "$BIN_DIR" || { say "err cannot create $BIN_DIR"; exit 1; }
    chmod +x "$AI_BIN"
    ln -sfn "$AI_BIN" "$BIN_DIR/ai"
    say "ok   $BIN_DIR/ai -> $AI_BIN"
    say "     configure it with AI_MODEL_PATH / AI_LLAMA_BIN (see ai.sh)"
  else
    say "skipped"
  fi
else
  say "ai.sh not present, skipped"
fi

# --------------------------------------------------------------- next
head1 "next"
say "  1. start a local model:   ./ai.sh start"
say "  2. point lex at it:       export LEX_API_URL=http://127.0.0.1:8080/v1/chat/completions"
say "  3. run lex:               lex"
say "  4. test everything:       ./test/run_all.sh"
say ""
say "all set."
