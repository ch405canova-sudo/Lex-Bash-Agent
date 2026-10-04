#!/usr/bin/env bash
#
# lex/test/fake_mcp.sh — minimal MCP server (stdio, JSON-RPC 2.0) for tests.
# Answers initialize, notifications/initialized, tools/list and tools/call.
# Special cases for error paths: boom (isError), die (connection gone), hang (timeout),
# everything else → JSON-RPC error. No network, no dependencies besides jq.
#
set -u

while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  method="$(jq -r '.method // empty' <<< "$line" 2>/dev/null)" || continue
  [[ -z "$method" ]] && continue
  id="$(jq -r '.id // empty' <<< "$line" 2>/dev/null)"

  case "$method" in
    initialize)
      _f="${LEX_HOME:-/tmp}/fake_mcp.sess"
      _n="$(cat "$_f" 2>/dev/null || echo 0)"; _n=$((_n + 1))
      printf '%s' "$_n" > "$_f"
      jq -cn --arg i "$id" '{
        jsonrpc:"2.0", id:$i,
        result:{protocolVersion:"2024-11-05", capabilities:{tools:{}},
                serverInfo:{name:"fake-mcp", version:"0.0.1"}}}'
      ;;
    notifications/initialized|notifications/cancelled)
      ;;
    tools/list)
      jq -cn --arg i "$id" '{
        jsonrpc:"2.0", id:$i,
        result:{tools:[
          {name:"fetch", inputSchema:{type:"object",
            properties:{url:{type:"string"}, max_length:{type:"integer"}}, required:["url"]}},
          {name:"resolve-library-id", inputSchema:{type:"object",
            properties:{libraryName:{type:"string"}, query:{type:"string"}}, required:["query","libraryName"]}},
          {name:"query-docs", inputSchema:{type:"object",
            properties:{libraryId:{type:"string"}, query:{type:"string"}}, required:["libraryId","query"]}},
          {name:"pid", inputSchema:{type:"object", properties:{}}}
        ]}}'
      ;;
    tools/call)
      tool="$(jq -r '.params.name // empty' <<< "$line")"
      args="$(jq -c '.params.arguments // {}' <<< "$line")"
      case "$tool" in
        fetch)
          t="Auszug: $(jq -r '.url // ""' <<< "$args") (max $(jq -r '.max_length // 0' <<< "$args"))"
          jq -cn --arg i "$id" --arg t "$t" \
            '{jsonrpc:"2.0", id:$i, result:{content:[{type:"text", text:$t}]}}'
          ;;
        resolve-library-id)
          t='- Title: Fake
- Context7-compatible library ID: /fake/lib
- Description: Testbibliothek für lex
- Code Snippets: 7'
          jq -cn --arg i "$id" --arg t "$t" \
            '{jsonrpc:"2.0", id:$i, result:{content:[{type:"text", text:$t}]}}'
          ;;
        query-docs)
          t="DOKUMENTATION: $(jq -r '.query // ""' <<< "$args") (Quelle: $(jq -r '.libraryId // ""' <<< "$args"))"
          jq -cn --arg i "$id" --arg t "$t" \
            '{jsonrpc:"2.0", id:$i, result:{content:[{type:"text", text:$t}]}}'
          ;;
        browser_navigate)
          t="Gefahren nach: $(jq -r '.url // ""' <<< "$args")"
          jq -cn --arg i "$id" --arg t "$t" \
            '{jsonrpc:"2.0", id:$i, result:{content:[{type:"text", text:$t}]}}'
          ;;
        browser_snapshot)
          t='Snapshot (Accessibility-Baum):
- page "Startseite" [ref=s1e42]
- heading "Willkommen" [ref=s1e43]
- button "Absenden" [ref=s1e44]'
          jq -cn --arg i "$id" --arg t "$t" \
            '{jsonrpc:"2.0", id:$i, result:{content:[{type:"text", text:$t}]}}'
          ;;
        browser_click)
          t="Geklickt: ref=$(jq -r '.ref // ""' <<< "$args") auf \"$(jq -r '.element // ""' <<< "$args")\""
          jq -cn --arg i "$id" --arg t "$t" \
            '{jsonrpc:"2.0", id:$i, result:{content:[{type:"text", text:$t}]}}'
          ;;
        browser_type)
          t="Getippt nach ref=$(jq -r '.ref // ""' <<< "$args"): $(jq -r '.text // ""' <<< "$args")"
          jq -cn --arg i "$id" --arg t "$t" \
            '{jsonrpc:"2.0", id:$i, result:{content:[{type:"text", text:$t}]}}'
          ;;
        browser_wait_for)
          t="Gewartet: $(jq -r '.time // 1' <<< "$args")s"
          jq -cn --arg i "$id" --arg t "$t" \
            '{jsonrpc:"2.0", id:$i, result:{content:[{type:"text", text:$t}]}}'
          ;;
        pid)
          _f="${LEX_HOME:-/tmp}/fake_mcp.sess"
          t="sess=$(cat "$_f" 2>/dev/null || echo 0) pid=$$"
          jq -cn --arg i "$id" --arg t "$t" \
            '{jsonrpc:"2.0", id:$i, result:{content:[{type:"text", text:$t}]}}'
          ;;
        boom)
          jq -cn --arg i "$id" \
            '{jsonrpc:"2.0", id:$i, result:{content:[{type:"text", text:"absichtlich kaputt"}], isError:true}}'
          ;;
        hang)
          exec sleep 30
          ;;
        die)
          exit 0
          ;;
        *)
          jq -cn --arg i "$id" \
            '{jsonrpc:"2.0", id:$i, error:{code:-32601, message:"unbekanntes Tool"}}'
          ;;
      esac
      ;;
    *)
      if [[ -n "$id" ]]; then
        jq -cn --arg i "$id" \
          '{jsonrpc:"2.0", id:$i, error:{code:-32601, message:"unbekannte Methode"}}'
      fi
      ;;
  esac
done
