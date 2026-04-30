#!/bin/bash
# PreToolUse hook for Bash: block commands that touch credential files.
# Belt-and-braces on top of permissions.deny (which handles direct
# Read/Edit tool calls). This catches cat/grep/head/tail/sed/awk/less/jq
# on credential paths inside shell commands.
#
# Outputs a PreToolUse deny decision to stderr-safe JSON on stdout.

set -euo pipefail

input=$(cat)
cmd=$(echo "$input" | jq -r '.tool_input.command // ""')

# Boundary trick: [^a-zA-Z0-9.] ensures we match .env but not .env.example,
# and credentials but not credentials.bak. The trailing ($|[^...]) handles
# end-of-string and separators (space, ;, |, >, &, etc).
patterns=(
  'terraform/\.env([^a-zA-Z0-9.]|$)'
  '\.aws/credentials([^a-zA-Z0-9.]|$)'
  '\.aws/config([^a-zA-Z0-9.]|$)'
  '\.git-crypt/'
  # bash xtrace leaks any sourced credentials (e.g. CLOUDFLARE_API_TOKEN
  # exported by scripts/appserver.sh). Block xtrace flags entirely.
  '(^|[[:space:]])bash[[:space:]]+-[a-zA-Z]*x'
  '(^|[[:space:]])set[[:space:]]+-[a-zA-Z]*x'
)

for pat in "${patterns[@]}"; do
  if echo "$cmd" | grep -qE "$pat"; then
    jq -n \
      --arg reason "Blocked: command references a credential file (matched: $pat). Use interactive tooling (./scripts/appserver.sh setup local, aws configure) rather than reading credential files through the LLM. Edit .claude/settings.json to adjust." \
      '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'
    exit 0
  fi
done

exit 0
