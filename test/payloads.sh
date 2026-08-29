#!/usr/bin/env bash
# Emits a named sample payload on stdout. Used by run-tests.sh.
set -euo pipefail
NOW=$(date +%s)
case "${1:-full}" in
  full)     jq -n --argjson n "$NOW" '{session_id:"s1",cwd:"/home/user/Work/project",workspace:{current_dir:"/home/user/Work/project",project_dir:"/home/user/Work/project"},model:{id:"claude-opus-5[1m]",display_name:"Opus 5"},effort:{level:"medium"},thinking:{enabled:true},context_window:{total_input_tokens:184300,total_output_tokens:9100,context_window_size:1000000,used_percentage:19.3,remaining_percentage:80.7},exceeds_200k_tokens:false,rate_limits:{five_hour:{used_percentage:42.5,resets_at:($n+7200)},seven_day:{used_percentage:88.1,resets_at:($n+270000)}}}' ;;
  no-rates) jq -n '{cwd:"/home/user",workspace:{current_dir:"/home/user"},model:{display_name:"Opus 5"},context_window:{used_percentage:73,total_input_tokens:146000,total_output_tokens:2000,context_window_size:200000}}' ;;
  null-ctx) jq -n '{workspace:{current_dir:"/tmp"},model:{id:"claude-sonnet-5"},context_window:null}' ;;
  deep)     jq -n '{workspace:{current_dir:"/home/user/a/b/c/d/e"},model:{id:"m"},context_window:{used_percentage:95,total_input_tokens:190000,total_output_tokens:0,context_window_size:200000}}' ;;
  no-effort) jq -n '{workspace:{current_dir:"/tmp"},model:{id:"claude-haiku-4-5"},context_window:{used_percentage:12,total_input_tokens:24000,total_output_tokens:500,context_window_size:200000}}' ;;
  max-effort) jq -n '{workspace:{current_dir:"/tmp"},model:{id:"claude-opus-5"},effort:{level:"max"},context_window:{used_percentage:5,total_input_tokens:10000,total_output_tokens:0,context_window_size:1000000}}' ;;
  bare)     jq -n '{}' ;;
  garbage)  printf 'not json at all' ;;
  empty)    printf '' ;;
  *) echo "unknown payload: $1" >&2; exit 2 ;;
esac
