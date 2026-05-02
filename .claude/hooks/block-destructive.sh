#!/usr/bin/env bash
# shellcheck disable=SC2016  # patterns and reason strings reference literal $HOME / $VAR — must not expand
# block-destructive.sh — PreToolUse Bash hook
#
# Blast-radius reduction for irreversible shell commands. Inspired by
# the PocketOS / Cursor incident (April 2026): a Claude-powered agent
# hit a permissions error, decided the fix was to delete the production
# database, and wiped both prod and backups in 9 seconds. The agent had
# broad tool access and no approval gate on destructive operations.
#
# This hook intercepts destructive verbs before execution. Claude Code's
# user-approval prompt is the primary gate; this is belt-and-braces in
# case (a) the user has approved bash invocations broadly, (b) the agent
# slips a destructive verb into a longer compound command, or (c) a
# future session reads CLAUDE.md and decides "rm -rf is fine here."
#
# When something is blocked, the user can still run it themselves from
# their own shell — the hook only fires for Bash tool invocations made
# by Claude.

set -euo pipefail

input=$(cat)
cmd=$(echo "$input" | jq -r '.tool_input.command // ""')

deny() {
  local reason="$1"
  jq -n --arg r "Blocked: $reason. If this is intended, run it yourself in your shell — Claude is gated on irreversible operations." \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
  exit 0
}

check() {
  local pattern="$1" reason="$2"
  if echo "$cmd" | grep -qE -- "$pattern"; then
    deny "$reason"
  fi
}

# === 1. Filesystem destruction ===========================================
# rm -rf on /, ~, $HOME, ..; dd to a block device; mkfs; find -delete on
# unbounded roots. Matches the "rm -rf $UNDEFINED_VAR" class of bug too
# because $HOME is in the pattern explicitly.
check 'rm[[:space:]]+(-[a-zA-Z]*r[a-zA-Z]*f|-[a-zA-Z]*f[a-zA-Z]*r)[[:space:]]+(/[[:space:]]*$|/[[:space:]]|~[[:space:]]*$|~/?[[:space:]]|\$\{?HOME\}?|\.\.?[[:space:]]*$|\.\.?[[:space:]])' \
  'rm -rf on /, ~, $HOME, ., or .. is unrecoverable'
check '(^|[^a-zA-Z])dd[[:space:]]+.*of=/dev/(sd|nvme|xvd|disk|mmcblk)' \
  'dd to a block device wipes the disk'
check '(^|[^a-zA-Z])mkfs(\.|[[:space:]])' \
  'mkfs reformats a filesystem'
check '(^|[^a-zA-Z])find[[:space:]]+(/[[:space:]]|~[[:space:]]|\$HOME)[[:space:]].*-delete' \
  'find -delete on /, ~, or $HOME is unbounded destruction'
check 'shred[[:space:]]+.*-[a-zA-Z]*[uz]' \
  'shred -u removes the file after overwriting'

# === 2. Git destruction ==================================================
# Force push rewrites remote history. reset --hard / clean -f / branch -D
# discard local work. filter-repo / filter-branch rewrite local history.
check 'git[[:space:]]+(.*[[:space:]])?push[[:space:]]+.*(--force([[:space:]]|=|$)|--force-with-lease)' \
  'force push rewrites remote history'
check 'git[[:space:]]+(.*[[:space:]])?push[[:space:]]+.*-[a-zA-Z]*f([[:space:]]|$)' \
  'force push (-f) rewrites remote history'
check 'git[[:space:]]+reset[[:space:]]+--hard' \
  'git reset --hard discards uncommitted work'
check 'git[[:space:]]+filter-(repo|branch)' \
  'git filter-repo/filter-branch rewrites every commit SHA'
check 'git[[:space:]]+branch[[:space:]]+-D[[:space:]]+(main|master|production|prod|develop)' \
  'cannot delete a protected branch'
check 'git[[:space:]]+clean[[:space:]]+-[A-Za-z]*f' \
  'git clean -f deletes untracked files irrecoverably'
check 'git[[:space:]]+checkout[[:space:]]+--[[:space:]]+\.' \
  'git checkout -- . overwrites all local changes'
check 'git[[:space:]]+restore[[:space:]]+\.' \
  'git restore . overwrites all local changes'

# === 3. Verification / hook bypass =======================================
# These flags skip the safety net. If a hook is failing, fix the hook.
check '--no-verify([[:space:]]|=|$)' \
  '--no-verify skips pre-commit hooks; investigate the failure instead'
check '--no-gpg-sign([[:space:]]|=|$)' \
  '--no-gpg-sign bypasses commit signing'
check '-c[[:space:]]+commit\.gpgsign=false' \
  'commit.gpgsign=false bypasses signing'

# === 4. Docker destruction ===============================================
# Volumes hold the persistent app state (postgres data, search indexes).
# `docker rm -v` removes the container AND its volumes in one call.
check 'docker[[:space:]]+volume[[:space:]]+(rm|prune)' \
  'docker volume rm/prune wipes persistent app data'
check 'docker[[:space:]]+system[[:space:]]+prune.*--volumes' \
  'docker system prune --volumes wipes persistent app data'
check 'docker[[:space:]]+(.*[[:space:]])?rm[[:space:]]+(-[a-zA-Z]*v|--volumes)' \
  'docker rm -v removes the container AND its volumes'
check 'docker[[:space:]]+compose[[:space:]]+down[[:space:]]+.*(-v|--volumes)' \
  'docker compose down -v removes named volumes'

# === 5. Database destruction =============================================
# DROP/TRUNCATE/DELETE FROM <table>; without WHERE. Cookie's postgres data
# is the highest-value persistent state on the appserver instance.
check '\b(DROP|TRUNCATE)[[:space:]]+(TABLE|DATABASE|SCHEMA|INDEX)\b' \
  'DROP/TRUNCATE is unrecoverable'
check '\bDELETE[[:space:]]+FROM[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*(;|$|--)' \
  'DELETE FROM <table> without WHERE deletes every row'
check '(^|[^a-zA-Z])dropdb([[:space:]]|$)' \
  'dropdb is unrecoverable'

# === 6. Terraform destruction ============================================
# `destroy` tears down infra. `state rm` desyncs state from reality.
# `apply -auto-approve` skips the human review step.
check 'terraform[[:space:]]+(.*[[:space:]])?destroy([[:space:]]|$)' \
  'terraform destroy tears down infra'
check 'terraform[[:space:]]+(.*[[:space:]])?state[[:space:]]+rm' \
  'terraform state rm desyncs state from infra'
check 'terraform[[:space:]]+(.*[[:space:]])?apply[[:space:]]+.*-auto-approve' \
  'terraform apply -auto-approve skips review'

# === 7. AWS destruction ==================================================
check 'aws[[:space:]]+s3[[:space:]]+rb([[:space:]]|$)' \
  'aws s3 rb deletes a bucket'
check 'aws[[:space:]]+s3[[:space:]]+rm[[:space:]]+.*--recursive' \
  'aws s3 rm --recursive deletes every object under a prefix'
check 'aws[[:space:]]+s3api[[:space:]]+(delete-bucket|delete-objects)' \
  's3api delete-bucket/delete-objects is unrecoverable'
check 'aws[[:space:]]+iam[[:space:]]+(delete-(role|user|policy|group|access-key)|detach-(role|user|group)-policy)' \
  'IAM deletion is operationally risky'
check 'aws[[:space:]]+ec2[[:space:]]+(terminate-instances|delete-(volume|snapshot|security-group|key-pair|network-interface))' \
  'EC2 deletion is unrecoverable'
check 'aws[[:space:]]+rds[[:space:]]+delete-(db-instance|db-cluster|db-snapshot)' \
  'RDS deletion is unrecoverable without snapshots'
check 'aws[[:space:]]+route53[[:space:]]+(delete-hosted-zone|change-resource-record-sets)' \
  'Route53 deletion / record changes can break DNS'
check 'aws[[:space:]]+kms[[:space:]]+(schedule-key-deletion|disable-key)' \
  'KMS key deletion / disable cascades to anything encrypted with it'

# === 8. SSM send-command — inspect embedded shell ========================
# SSM is the only path from the operator's laptop into the appserver
# instance (no SSH). aws ssm send-command --document AWS-RunShellScript
# embeds an arbitrary shell payload. We re-apply the destructive verb
# scan to that embedded payload so an agent can't smuggle `rm -rf` into
# the instance via SSM.
if echo "$cmd" | grep -qE 'aws[[:space:]]+ssm[[:space:]]+send-command'; then
  for entry in \
      'rm[[:space:]]+-[a-zA-Z]*r[a-zA-Z]*f|rm -rf inside SSM payload' \
      'mkfs|mkfs inside SSM payload' \
      '(DROP|TRUNCATE)[[:space:]]+TABLE|DROP/TRUNCATE inside SSM payload' \
      'dropdb|dropdb inside SSM payload' \
      'docker[[:space:]]+volume[[:space:]]+rm|docker volume rm inside SSM payload' \
      'docker[[:space:]]+rm[[:space:]]+.*-v|docker rm -v inside SSM payload' \
      'find[[:space:]]+/[[:space:]].*-delete|unbounded find -delete inside SSM payload'; do
    pat="${entry%%|*}"
    desc="${entry#*|}"
    if echo "$cmd" | grep -qE -- "$pat"; then
      deny "$desc — SSM is the entrypoint to the appserver instance, destructive payloads must be reviewed by a human"
    fi
  done
fi

# === 9. Appserver-specific destructive ops ===============================
check 'appserver\.sh[[:space:]]+destroy' \
  'appserver.sh destroy tears down the entire stack'
check 'appserver\.sh[[:space:]]+app[[:space:]]+remove' \
  'appserver.sh app remove stops + removes an app'

# === 10. Process / system =================================================
check '(^|[^a-zA-Z])kill[[:space:]]+-9[[:space:]]+1([[:space:]]|$)' \
  'kill -9 1 takes down PID 1'
check '(^|[^a-zA-Z])(shutdown|reboot|poweroff|halt)([[:space:]]|$)' \
  'system shutdown/reboot is operator-only'
check ':\(\)\{[[:space:]]*:\|:&[[:space:]]*\};:' \
  'fork bomb detected'

exit 0
