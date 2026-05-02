#!/usr/bin/env bash
# PreToolUse hook for Bash: block commands that read or print credentials.
# Belt-and-braces on top of permissions.deny (which handles direct
# Read/Edit tool calls). Two classes are blocked here:
#
#   1. File-reading commands targeting credential paths
#      (cat/grep/head/tail/sed/awk/less/jq on .env, ~/.aws, .git-crypt).
#   2. CLI commands that PRINT live credentials to stdout
#      (gh auth token, aws iam create-access-key, aws sts get-*-token,
#      aws sts assume-role). These evade class 1 because they're not
#      file reads — but the secret still ends up in Claude's context.
#
# Outputs a PreToolUse deny decision as JSON on stdout.

set -euo pipefail

input=$(cat)
cmd=$(echo "$input" | jq -r '.tool_input.command // ""')

deny() {
  local reason="$1"
  jq -n --arg r "Blocked: command references a credential file or prints live credentials ($reason). Use interactive tooling (./scripts/appserver.sh setup local, aws configure) rather than piping secrets through the LLM. Edit .claude/settings.json to adjust." \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
  exit 0
}

# === Class 1: credential-file reads ======================================
# Boundary trick: [^a-zA-Z0-9.] ensures we match .env but not .env.example,
# and credentials but not credentials.bak. The trailing ($|[^...]) handles
# end-of-string and separators (space, ;, |, >, &, etc).
file_patterns=(
  'terraform/\.env([^a-zA-Z0-9.]|$)'
  '\.aws/credentials([^a-zA-Z0-9.]|$)'
  '\.aws/config([^a-zA-Z0-9.]|$)'
  '\.git-crypt/'
  # bash xtrace leaks any sourced credentials (e.g. CLOUDFLARE_API_TOKEN
  # exported by scripts/appserver.sh). Block xtrace flags entirely.
  '(^|[[:space:]])bash[[:space:]]+-[a-zA-Z]*x'
  '(^|[[:space:]])set[[:space:]]+-[a-zA-Z]*x'
)

for pat in "${file_patterns[@]}"; do
  if echo "$cmd" | grep -qE "$pat"; then
    deny "credential file pattern: $pat"
  fi
done

# === Class 2: live-credential-printing CLIs ==============================
# These commands emit a live token / access key / session credential to
# stdout where Claude reads it and stores it in conversation context.
# `gh auth status` (without --show-token) is OK — only the variant that
# explicitly reveals the token is blocked.
print_patterns=(
  '(^|[[:space:]&;|])gh[[:space:]]+auth[[:space:]]+token([[:space:]]|$)'
  'gh[[:space:]]+auth[[:space:]]+status[[:space:]]+.*--show-token'
  'aws[[:space:]]+iam[[:space:]]+create-access-key'
  'aws[[:space:]]+sts[[:space:]]+(get-session-token|get-federation-token|assume-role)'
)

for pat in "${print_patterns[@]}"; do
  if echo "$cmd" | grep -qE -- "$pat"; then
    deny "live credential print: $pat"
  fi
done

exit 0
