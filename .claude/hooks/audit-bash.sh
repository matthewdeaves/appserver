#!/usr/bin/env bash
# audit-bash.sh — PostToolUse Bash hook
#
# Append every Bash invocation Claude makes to .claude/audit.log so we
# have a forensic trail. Useful when something goes wrong: "what did the
# agent run between when X was healthy and when it broke?"
#
# Each line is a single JSON object with timestamp, working directory,
# command (truncated), status, and truncated stdout/stderr. Easy to
# grep and easy to feed back into Claude when investigating.
#
# The log is gitignored — local-only by design. Rotates at MAX_BYTES;
# one previous file is kept (.audit.log.1) so we always have at least
# the latest tranche.

set -euo pipefail

CLAUDE_DIR="${CLAUDE_PROJECT_DIR:-.}/.claude"
LOG_FILE="$CLAUDE_DIR/audit.log"
MAX_BYTES=$((10 * 1024 * 1024))  # 10 MB
CMD_TRUNC=500
OUT_TRUNC=300

input=$(cat)
cmd=$(echo "$input" | jq -r '.tool_input.command // ""')
# Claude Code reports failure via is_error (boolean) — exit code is not
# directly surfaced. Log "ok" / "err" instead.
is_error=$(echo "$input" | jq -r '(.tool_response // {}) | .is_error // false')
status=$([[ "$is_error" == "true" ]] && echo "err" || echo "ok")
# tool_response shape varies by Claude Code version — try a few likely
# fields. Empty string if none present.
stdout=$(echo "$input" | jq -r '(.tool_response // {}) | (.stdout // .output // .content // "") | tostring')
stderr=$(echo "$input" | jq -r '(.tool_response // {}) | (.stderr // "") | tostring')
ts=$(date -Iseconds)
cwd=$(pwd)

mkdir -p "$CLAUDE_DIR"

# Rotate if log exceeds size cap. stat -c is GNU; -f is BSD.
if [ -f "$LOG_FILE" ]; then
  size=$(stat -c%s "$LOG_FILE" 2>/dev/null || stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)
  if [ "$size" -ge "$MAX_BYTES" ]; then
    mv -f "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null || true
  fi
fi

trunc() {
  local s="$1" max="$2"
  if [ "${#s}" -gt "$max" ]; then
    printf '%s' "${s:0:$max}…[truncated]"
  else
    printf '%s' "$s"
  fi
}

short_cmd=$(trunc "$cmd" "$CMD_TRUNC")
short_stdout=$(trunc "$stdout" "$OUT_TRUNC")
short_stderr=$(trunc "$stderr" "$OUT_TRUNC")

jq -n -c \
  --arg ts "$ts" \
  --arg cwd "$cwd" \
  --arg cmd "$short_cmd" \
  --arg status "$status" \
  --arg stdout "$short_stdout" \
  --arg stderr "$short_stderr" \
  '{ts: $ts, cwd: $cwd, status: $status, cmd: $cmd, stdout: $stdout, stderr: $stderr}' \
  >> "$LOG_FILE"

exit 0
