#!/usr/bin/env bash
# shellcheck disable=SC2016  # patterns reference literal $HOME / $VAR — must not expand
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
#
# Patterns are stored in three parallel arrays (scope/regex/reason) so
# the SSM payload scanner — which inspects the embedded shell of
# `aws ssm send-command` — can reuse the same ruleset rather than
# duplicating a subset that drifts.

set -euo pipefail

input=$(cat)
cmd=$(echo "$input" | jq -r '.tool_input.command // ""')

deny() {
  local reason="$1"
  jq -n --arg r "Blocked: $reason. If this is intended, run it yourself in your shell — Claude is gated on irreversible operations." \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
  exit 0
}

# === Pattern catalogue ===================================================
# Three parallel arrays. add_pat <scope> <regex> <reason>.
#   scope = "all"        → scan top-level AND inside SSM payloads
#         = "host-only"  → only scan top-level (e.g. terraform / git ops
#                          that don't apply on the EC2 instance)
declare -a PAT_SCOPE PAT_REGEX PAT_REASON
add_pat() { PAT_SCOPE+=("$1"); PAT_REGEX+=("$2"); PAT_REASON+=("$3"); }

# --- Filesystem destruction ---------------------------------------------
add_pat all \
  'rm[[:space:]]+(-[a-zA-Z]*r[a-zA-Z]*f|-[a-zA-Z]*f[a-zA-Z]*r)[[:space:]]+(/[[:space:]]*$|/[[:space:]]|~[[:space:]]*$|~/?[[:space:]]|\$\{?HOME\}?|\.\.?[[:space:]]*$|\.\.?[[:space:]])' \
  'rm -rf on /, ~, $HOME, ., or .. is unrecoverable'
add_pat all \
  '(^|[^a-zA-Z])dd[[:space:]]+.*of=/dev/(sd|nvme|xvd|disk|mmcblk)' \
  'dd to a block device wipes the disk'
add_pat all \
  '(^|[^a-zA-Z])mkfs(\.|[[:space:]])' \
  'mkfs reformats a filesystem'
add_pat all \
  '(^|[^a-zA-Z])find[[:space:]]+(/[[:space:]]|~[[:space:]]|\$HOME[[:space:]]).*-delete' \
  'find -delete on /, ~, or $HOME is unbounded destruction'
add_pat all \
  'shred[[:space:]]+.*-[a-zA-Z]*[uz]' \
  'shred -u removes the file after overwriting'

# --- Wide-permission filesystem ops -------------------------------------
add_pat all \
  'chmod[[:space:]]+(-[a-zA-Z]*[Rr][a-zA-Z]*[[:space:]]+)?(0?777|a\+rwx)([[:space:]]|/|$)' \
  'chmod 0777 / a+rwx is a privilege-escalation vector'
add_pat all \
  'chown[[:space:]]+(-[a-zA-Z]*[Rr][a-zA-Z]*[[:space:]]+)?[^[:space:]]+[[:space:]]+(/[[:space:]]*$|/[[:space:]]|~[[:space:]]*$|~/?[[:space:]]|\$\{?HOME\}?)' \
  'chown of /, ~, or $HOME breaks service ownership'

# --- Pipe-to-shell / remote code execution ------------------------------
add_pat all \
  '(curl|wget|fetch)[[:space:]]+[^|;&$]*\|[[:space:]]*(bash|sh|zsh|fish|python|python3|ruby|perl|node)([[:space:]]|$)' \
  'pipe-to-shell from the network is the standard malware install pattern'
add_pat all \
  '(bash|sh|zsh)[[:space:]]+<\((curl|wget|fetch)[[:space:]]' \
  'process substitution exec'\''ing remote content'
add_pat all \
  '(source|\.[[:space:]])[[:space:]]*<\((curl|wget|fetch)[[:space:]]' \
  'sourcing remote shell content from the network'

# --- Git destruction (operator host only) -------------------------------
# --force-with-lease is also blocked: with-lease refuses if upstream
# moved, but it still rewrites your own commits, so it remains a
# Layer-1 user-decision call.
#
# `.*` would greedily span shell separators (`&&`, `||`, `;`, `|`) and
# match `-f` from a totally different command — e.g. `git push origin
# main && rm -f /tmp/x` would trigger on the `rm -f`. `[^&;|]*`
# constrains the match to the same shell command.
add_pat host-only \
  'git[[:space:]]+([^&;|]*[[:space:]])?push[[:space:]]+[^&;|]*(--force([[:space:]]|=|$)|--force-with-lease)' \
  'force push (incl. --force-with-lease) rewrites remote history'
add_pat host-only \
  'git[[:space:]]+([^&;|]*[[:space:]])?push[[:space:]]+[^&;|]*-[a-zA-Z]*f([[:space:]]|$)' \
  'force push (-f) rewrites remote history'
add_pat host-only \
  'git[[:space:]]+reset[[:space:]]+--hard' \
  'git reset --hard discards uncommitted work'
add_pat host-only \
  'git[[:space:]]+filter-(repo|branch)' \
  'git filter-repo/filter-branch rewrites every commit SHA'
add_pat host-only \
  'git[[:space:]]+branch[[:space:]]+-D[[:space:]]+(main|master|production|prod|develop)' \
  'cannot delete a protected branch'
add_pat host-only \
  'git[[:space:]]+clean[[:space:]]+-[A-Za-z]*f' \
  'git clean -f deletes untracked files irrecoverably'
add_pat host-only \
  'git[[:space:]]+checkout[[:space:]]+--[[:space:]]+\.' \
  'git checkout -- . overwrites all local changes'
add_pat host-only \
  'git[[:space:]]+restore[[:space:]]+\.' \
  'git restore . overwrites all local changes'
# Remote-tampering: redirect origin to attacker URL, or delete remote
# refs. Quiet but high-impact.
add_pat host-only \
  'git[[:space:]]+remote[[:space:]]+(remove|rm|set-url)' \
  'git remote remove/set-url can re-route origin to an attacker URL'
add_pat host-only \
  'git[[:space:]]+push[[:space:]]+[^&;|]*--delete([[:space:]]|$)' \
  'git push --delete removes a remote ref'
# More-specific tag-delete patterns must come before the generic
# colon-branch pattern, which would otherwise swallow `:refs/tags/`.
add_pat host-only \
  'git[[:space:]]+push[[:space:]]+[^&;|]*:refs/tags/' \
  'git push :refs/tags/X deletes a remote tag'
add_pat host-only \
  'git[[:space:]]+push[[:space:]]+[^[:space:]]+[[:space:]]+:[a-zA-Z]' \
  'git push origin :branch deletes a remote branch (colon syntax)'
add_pat host-only \
  'git[[:space:]]+tag[[:space:]]+-d' \
  'git tag -d deletes a release marker locally'

# --- Verification / hook bypass -----------------------------------------
add_pat host-only \
  '--no-verify([[:space:]]|=|$)' \
  '--no-verify skips pre-commit hooks; investigate the failure instead'
add_pat host-only \
  '--no-gpg-sign([[:space:]]|=|$)' \
  '--no-gpg-sign bypasses commit signing'
add_pat host-only \
  '-c[[:space:]]+commit\.gpgsign=false' \
  'commit.gpgsign=false bypasses signing'

# --- Docker destruction -------------------------------------------------
add_pat all \
  'docker[[:space:]]+volume[[:space:]]+(rm|prune)' \
  'docker volume rm/prune wipes persistent app data'
add_pat all \
  'docker[[:space:]]+system[[:space:]]+prune[^&;|]*--volumes' \
  'docker system prune --volumes wipes persistent app data'
add_pat all \
  'docker[[:space:]]+([^&;|]*[[:space:]])?rm[[:space:]]+(-[a-zA-Z]*v|--volumes)' \
  'docker rm -v removes the container AND its volumes'
add_pat all \
  'docker[[:space:]]+compose[[:space:]]+down[[:space:]]+[^&;|]*(-v|--volumes)' \
  'docker compose down -v removes named volumes'

# --- Database destruction -----------------------------------------------
add_pat all \
  '\b(DROP|TRUNCATE)[[:space:]]+(TABLE|DATABASE|SCHEMA|INDEX)\b' \
  'DROP/TRUNCATE is unrecoverable'
add_pat all \
  '\bDELETE[[:space:]]+FROM[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*(;|$|--|")' \
  'DELETE FROM <table> without WHERE deletes every row'
add_pat all \
  '(^|[^a-zA-Z])dropdb([[:space:]]|$)' \
  'dropdb is unrecoverable'

# --- Terraform destruction (operator host only) ------------------------
add_pat host-only \
  'terraform[[:space:]]+([^&;|]*[[:space:]])?destroy([[:space:]]|$)' \
  'terraform destroy tears down infra'
add_pat host-only \
  'terraform[[:space:]]+([^&;|]*[[:space:]])?state[[:space:]]+rm' \
  'terraform state rm desyncs state from infra'
add_pat host-only \
  'terraform[[:space:]]+([^&;|]*[[:space:]])?apply[[:space:]]+[^&;|]*-auto-approve' \
  'terraform apply -auto-approve skips review'

# --- AWS destruction ----------------------------------------------------
add_pat all \
  'aws[[:space:]]+s3[[:space:]]+rb([[:space:]]|$)' \
  'aws s3 rb deletes a bucket'
add_pat all \
  'aws[[:space:]]+s3[[:space:]]+rm[[:space:]]+[^&;|]*--recursive' \
  'aws s3 rm --recursive deletes every object under a prefix'
add_pat all \
  'aws[[:space:]]+s3api[[:space:]]+(delete-bucket|delete-objects)' \
  's3api delete-bucket/delete-objects is unrecoverable'
add_pat all \
  'aws[[:space:]]+iam[[:space:]]+(delete-(role|user|policy|group|access-key)|detach-(role|user|group)-policy)' \
  'IAM deletion is operationally risky'
add_pat all \
  'aws[[:space:]]+ec2[[:space:]]+(terminate-instances|delete-(volume|snapshot|security-group|key-pair|network-interface))' \
  'EC2 deletion is unrecoverable'
add_pat all \
  'aws[[:space:]]+rds[[:space:]]+delete-(db-instance|db-cluster|db-snapshot)' \
  'RDS deletion is unrecoverable without snapshots'
add_pat all \
  'aws[[:space:]]+route53[[:space:]]+(delete-hosted-zone|change-resource-record-sets)' \
  'Route53 deletion / record changes can break DNS'
add_pat all \
  'aws[[:space:]]+kms[[:space:]]+(schedule-key-deletion|disable-key)' \
  'KMS key deletion / disable cascades to anything encrypted with it'

# --- Cloudflare destruction --------------------------------------------
# threat-ops invokes CF API via scripts/appserver.sh, not direct curl —
# so blocking direct destructive calls here doesn't break that path.
add_pat all \
  'cloudflared[[:space:]]+tunnel[[:space:]]+delete' \
  'cloudflared tunnel delete tears down the only ingress path'
add_pat all \
  'cloudflared[[:space:]]+access[[:space:]]+(login|token)[[:space:]]+(revoke|delete)' \
  'cloudflared access revoke locks operators out'
add_pat all \
  'curl[[:space:]]+[^&;|]*-X[[:space:]]+(DELETE|PATCH)[[:space:]]+[^&;|]*api\.cloudflare\.com' \
  'direct CF API DELETE/PATCH bypasses appserver.sh threat-ops'

# --- Appserver-specific destructive ops --------------------------------
add_pat host-only \
  'appserver\.sh[[:space:]]+destroy' \
  'appserver.sh destroy tears down the entire stack'
add_pat host-only \
  'appserver\.sh[[:space:]]+app[[:space:]]+remove' \
  'appserver.sh app remove stops + removes an app'

# --- Process / system --------------------------------------------------
add_pat all \
  '(^|[^a-zA-Z])kill[[:space:]]+-9[[:space:]]+1([[:space:]]|$)' \
  'kill -9 1 takes down PID 1'
add_pat all \
  '(^|[^a-zA-Z])(shutdown|reboot|poweroff|halt)([[:space:]]|$)' \
  'system shutdown/reboot is operator-only'
add_pat all \
  ':\(\)\{[[:space:]]*:\|:&[[:space:]]*\};:' \
  'fork bomb detected'

n=${#PAT_SCOPE[@]}

# === Scan SSM-embedded shell payload FIRST ===============================
# `aws ssm send-command --document AWS-RunShellScript` smuggles a shell
# string into the EC2 instance, bypassing the local hook system on the
# target. We scan it before the top-level pass so:
#   1. The deny reason names "SSM payload" (better signal for the user).
#   2. We extract the unquoted payload, so `rm -rf /"` (slash followed
#      by closing quote inside `commands="..."`) matches the same
#      patterns as a plain `rm -rf /`.
if echo "$cmd" | grep -qE 'aws[[:space:]]+ssm[[:space:]]+send-command'; then
  # Extract the value of commands=... — handles double or single quoting,
  # plus the JSON-list form commands=["..."].
  ssm_payload=$(printf '%s' "$cmd" | grep -oE 'commands=("[^"]*"|'\''[^'\'']*'\''|\[[^]]*\])' | head -1 || true)
  ssm_payload="${ssm_payload#commands=}"
  ssm_payload="${ssm_payload#[}"
  ssm_payload="${ssm_payload%]}"
  ssm_payload="${ssm_payload#[\"\']}"
  ssm_payload="${ssm_payload%[\"\']}"

  if [ -n "$ssm_payload" ]; then
    for ((i = 0; i < n; i++)); do
      [[ "${PAT_SCOPE[i]}" != "all" ]] && continue
      if echo "$ssm_payload" | grep -qE -- "${PAT_REGEX[i]}"; then
        deny "${PAT_REASON[i]} — inside SSM payload (the path to the appserver instance, destructive payloads must be reviewed by a human)"
      fi
    done
  fi
fi

# === Scan top-level command ==============================================
for ((i = 0; i < n; i++)); do
  if echo "$cmd" | grep -qE -- "${PAT_REGEX[i]}"; then
    deny "${PAT_REASON[i]}"
  fi
done

exit 0
