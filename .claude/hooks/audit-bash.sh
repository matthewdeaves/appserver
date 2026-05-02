#!/usr/bin/env bash
# audit-bash.sh — PostToolUse Bash hook
#
# Append every Bash invocation Claude makes to .claude/audit.log so we
# have a forensic trail. Useful when something goes wrong: "what did the
# agent run between when X was healthy and when it broke?"
#
# Each line is a single JSON object with timestamp, working directory,
# command (truncated to keep the log readable), and exit code. Easy to
# grep and easy to feed back into Claude when investigating.
#
# The log is gitignored — local-only by design.

set -euo pipefail

input=$(cat)
cmd=$(echo "$input" | jq -r '.tool_input.command // ""')
# Claude Code's Bash tool reports failure via is_error (boolean) — exit
# code is not surfaced. We log "ok" / "err" instead.
is_error=$(echo "$input" | jq -r '(.tool_response // {}) | .is_error // false')
status=$([[ "$is_error" == "true" ]] && echo "err" || echo "ok")
ts=$(date -Iseconds)
cwd=$(pwd)

log_dir="${CLAUDE_PROJECT_DIR:-.}/.claude"
log_file="$log_dir/audit.log"
mkdir -p "$log_dir"

# Truncate at 500 chars — long heredocs blow out the log otherwise.
short_cmd=$(printf '%s' "$cmd" | head -c 500)
if [ "${#cmd}" -gt 500 ]; then
  short_cmd+=" …[truncated]"
fi

jq -n -c \
  --arg ts "$ts" \
  --arg cwd "$cwd" \
  --arg cmd "$short_cmd" \
  --arg status "$status" \
  '{ts: $ts, cwd: $cwd, status: $status, cmd: $cmd}' \
  >> "$log_file"

exit 0
