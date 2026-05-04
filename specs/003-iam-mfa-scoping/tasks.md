# Tasks: IAM MFA + Per-Skill Scoping

**Input**: Design documents from `/specs/003-iam-mfa-scoping/`
**Prerequisites**: spec.md, plan.md

**Tests**: Existing — `bash .claude/hooks/test-hooks.sh` (175 cases). New — `tests/auth-flow-test.sh` for the CLI auth helpers added in phase 3.

**Format**: `[ID] [P?] [Phase] Description`
- **[P]**: Can run in parallel (different files, no dependencies)

---

## Phase 1 — Additive: roles + policies + bonus tightening

### Setup
- [ ] **T001** Create branch `003-iam-mfa-scoping` and ensure `pre-commit install` has run (gitleaks + shellcheck pre-commit hooks active)

### Policies (parallel: separate files)
- [ ] **T002** [P] Create `terraform/deployer-policies/readonly.json`. Read-only permissions across EC2 (Describe*), DLM (Get*), SSM (`GetCommandInvocation`, `DescribeInstanceInformation`, `GetParameter` on `/appserver/*`), CloudWatch (Get*/Describe*/List*), CE (`GetCostAndUsage`), Logs (`Get*`), S3 read on `appserver-artifacts-*` and `appserver-tfstate-*`. No SendCommand, no StartSession, no IAM, no Modify*.
- [ ] **T003** [P] Create `terraform/deployer-policies/cookie-ops.json`. Includes everything in readonly.json plus `ssm:SendCommand` on the tagged instance, `ssm:StartSession` on the tagged instance, `ssm:GetParameter` on `/appserver/*`, basic Cloudflare tunnel describe (so `cookie-ops` can read tunnel state if needed). No IAM, no Terraform, no S3 deletion.
- [ ] **T004** [P] Update `terraform/deployer-policies/iam-ssm.json`:
  - Replace the `DenyManagedPolicyEscalation` `ForAnyValue:ArnNotLike` prefix list with an explicit name allowlist: `AppserverDeployerCompute`, `AppserverDeployerIamSsm`, `AppserverDeployerMonitoringStorage`, `AppserverDeployerAssumeRoles`, plus the AWS-managed `AmazonSSMManagedInstanceCore` and `AWSDataLifecycleManagerServiceRole`.
  - Add a new `DenyAttachToInstanceRole` deny statement: deny `iam:AttachRolePolicy` and `iam:DetachRolePolicy` on `arn:aws:iam::*:role/appserver-instance-role`.

### Terraform — IAM roles
- [ ] **T005** Add three IAM roles to `terraform/main.tf` (or a new `terraform/iam-operator-roles.tf` for cleanliness):
  - `aws_iam_role.appserver_readonly` — trust policy allows `sts:AssumeRole` from `arn:aws:iam::ACCOUNT:user/appserver-deployer`, conditioned on MFA. `MaxSessionDuration = 3600`. Permissions boundary set to a new `appserver-operator-readonly-boundary` policy.
  - `aws_iam_role.appserver_cookie_ops` — same pattern, boundary `appserver-operator-cookie-ops-boundary`.
  - `aws_iam_role.appserver_deploy` — same pattern, boundary `appserver-operator-deploy-boundary`.
- [ ] **T006** Add three permissions-boundary policies in `terraform/main.tf`:
  - `aws_iam_policy.operator_readonly_boundary` — caps the readonly role to a deny-by-default; allow only the actions in `readonly.json`.
  - `aws_iam_policy.operator_cookie_ops_boundary` — caps cookie-ops role similarly.
  - `aws_iam_policy.operator_deploy_boundary` — caps deploy role at deployer-equivalent permissions (i.e. matches the union of the existing three deployer policies).
- [ ] **T007** Attach the JSON policies to their roles via `aws_iam_role_policy_attachment` resources:
  - `readonly.json` → `appserver_readonly` role
  - `cookie-ops.json` → `appserver_cookie_ops` role
  - `compute.json`, `iam-ssm.json`, `monitoring-storage.json` → `appserver_deploy` role (managed-policy attachments, since they already exist as managed policies)
- [ ] **T008** Add `aws_iam_user_policy_attachment` for an existing-or-new managed policy `AppserverDeployerAssumeRoles` granting `sts:AssumeRole` on the three role ARNs, MFA-conditioned. Attach to `appserver-deployer` user. (Document: don't attach yet to deployer user in phase 1; that happens in phase 2.) Actually — the policy SHOULD exist in phase 1 (created by terraform) but the attachment to the user happens in phase 2 manually; mark this carefully.
- [ ] **T009** [P] Update `terraform/outputs.tf` to expose the three role ARNs (used later by the CLI).

### Pre-commit checks (run locally)
- [ ] **T010** `terraform -chdir=terraform fmt -check -recursive` — must pass
- [ ] **T011** `cd terraform && terraform init -backend=false && terraform validate` — must pass
- [ ] **T012** `tfsec terraform/` — must pass with no new findings (or documented `tfsec:ignore` comments)
- [ ] **T013** `bash .claude/hooks/test-hooks.sh` — must show `PASS: 175, FAIL: 0` (this phase doesn't change hooks; the test count is a regression check)
- [ ] **T014** `shellcheck scripts/*.sh .claude/hooks/*.sh` — must be clean
- [ ] **T015** `gitleaks protect --staged --config=.gitleaks.toml` — must pass (via pre-commit)

### Manual review and apply
- [ ] **T016** `./scripts/appserver.sh deploy` — interactive `terraform plan` review. Confirm only additions: 2 new policy files, 3 new roles, 3 new boundary policies, several new attachments, plus the modified `iam-ssm.json` policy. Zero deletions of existing resources.
- [ ] **T017** Apply. Verify with `aws iam get-role --role-name appserver-readonly-role` etc.
- [ ] **T018** Verify trust policies have MFA condition: `aws iam get-role --role-name appserver-readonly-role --query 'Role.AssumeRolePolicyDocument'`

### CI gate
- [ ] **T019** Push branch; verify Validate workflow goes green (`Terraform Format`, `Terraform Validate`, `tfsec`, `Validate Claude hooks`, `ShellCheck scripts`, `Gitleaks`).
- [ ] **T020** Merge phase 1 to main.

**Checkpoint**: Phase 1 done. Long-lived deployer key still works exactly as before.

---

## Phase 2 — MFA enrolment + AssumeRole permission for deployer user

### Manual MFA enrolment (operator, not Claude)
- [ ] **T021** Operator: enable a TOTP MFA device on `appserver-deployer` user via AWS console. Save the device ARN: `arn:aws:iam::ACCOUNT:mfa/appserver-deployer`.
- [ ] **T022** Store the MFA device ARN in `terraform/.env` (as `MFA_SERIAL_NUMBER`) — this file is git-crypted/.gitignored so the value is local-only. Verify `block-credential-reads.sh` still denies reads of `terraform/.env`.

### Attach AssumeRoles policy to deployer user
- [ ] **T023** Create the `AppserverDeployerAssumeRoles` policy as a JSON file under `terraform/deployer-policies/assume-roles.json` if not already present (T008). Attach via terraform `aws_iam_user_policy_attachment` to `appserver-deployer`.
- [ ] **T024** Apply: `./scripts/appserver.sh deploy`. Plan should show: one new policy attachment.
- [ ] **T025** Smoke test (operator): `aws sts assume-role --role-arn arn:aws:iam::ACCOUNT:role/appserver-readonly-role --role-session-name smoke --serial-number arn:aws:iam::ACCOUNT:mfa/appserver-deployer --token-code 123456 --duration-seconds 3600` — should return 1-hour creds.
- [ ] **T026** Smoke test denied path: with the readonly creds exported, `aws ec2 terminate-instances --instance-ids i-FAKE` — should fail with `UnauthorizedOperation`.

### Pre-commit checks (re-run all of T010–T015)
- [ ] **T027** All phase 1 checks must still pass.

### CI gate + merge
- [ ] **T028** Push, CI green, merge.

**Checkpoint**: Phase 2 done. AssumeRole works manually via CLI. Old long-lived key still works.

---

## Phase 3 — CLI `auth` subcommand + per-subcommand role mapping

### CLI helpers
- [ ] **T029** Add `assume_role()` helper to `scripts/appserver.sh`:
  - Signature: `assume_role <role_name>` (e.g. `assume_role readonly`)
  - Reads `MFA_SERIAL_NUMBER` from `terraform/.env`
  - Prompts the operator for a 6-digit TOTP code (using `read -s` for terminal input)
  - Calls `aws sts assume-role --role-arn ... --role-session-name <pattern>-$(date +%s) --serial-number $MFA_SERIAL_NUMBER --token-code <code> --duration-seconds 3600`
  - Writes returned creds to `~/.aws/credentials` under profile `appserver-<role>` (using `aws configure set aws_access_key_id`, `aws_secret_access_key`, `aws_session_token`)
  - Exports `AWS_PROFILE=appserver-<role>`
- [ ] **T030** Add `ensure_session_valid_for_role()` helper:
  - Checks if `~/.aws/credentials` has profile `appserver-<role>` AND the session is not expiring within 5 minutes (compare `aws_session_token` expiry from cached credentials cache to current time)
  - If valid: just exports `AWS_PROFILE=appserver-<role>`
  - If invalid: calls `assume_role <role_name>` to refresh
- [ ] **T031** Add `cmd_auth()` subcommand:
  - `appserver.sh auth` — prompts for role choice (default: readonly), then calls `assume_role`
  - `appserver.sh auth --role <name>` — directly assumes the named role
  - `appserver.sh auth status` — shows: which roles have valid sessions, time remaining, currently active profile
- [ ] **T032** Add subcommand-to-role map at the top of `scripts/appserver.sh`:
  ```bash
  declare -A SUBCOMMAND_ROLE=(
    [status]=readonly
    [logs]=readonly
    [spend]=readonly
    [app_list]=readonly
    [threats_analyze]=readonly
    [threats_blocked]=readonly
    [threats_allowed]=readonly
    [threats_list]=readonly
    [threats_report]=readonly
    [setup_unlock]=readonly
    [setup_lock]=readonly
    [app_deploy]=cookie-ops
    [app_init]=cookie-ops
    [app_remove]=cookie-ops
    [app_restart]=cookie-ops
    [app_env]=cookie-ops
    [config_push]=cookie-ops
    [threats_block]=cookie-ops
    [threats_unblock]=cookie-ops
    [threats_allow]=cookie-ops
    [threats_unallow]=cookie-ops
    [init]=deploy
    [deploy]=deploy
    [destroy]=deploy
    [start]=deploy
    [stop]=deploy
    [ssh]=deploy
  )
  ```
- [ ] **T033** Update each `cmd_<name>()` function in `scripts/appserver.sh` to call `ensure_session_valid_for_role "${SUBCOMMAND_ROLE[<name>]}"` at entry, before any AWS API calls.
- [ ] **T034** Add backwards-compat fallback: if the operator has a long-lived `appserver` profile AND the new `appserver-<role>` profile doesn't exist, the CLI falls back to using `appserver` and prints a one-time deprecation warning per session.

### Hook self-test additions
- [ ] **T035** Add allow-case assertions to `.claude/hooks/test-hooks.sh`:
  - `assert_allow "$HOOK" "appserver auth" "$(bash_payload './scripts/appserver.sh auth')"`
  - `assert_allow "$HOOK" "appserver auth status" "$(bash_payload './scripts/appserver.sh auth status')"`
  - `assert_allow "$HOOK" "appserver auth --role readonly" "$(bash_payload './scripts/appserver.sh auth --role readonly')"`
  - Verify the destructive-bash hook does NOT block these.
- [ ] **T036** Add deny-case assertion to ensure `aws sts assume-role` from Claude is allowed (it's a non-destructive read). Currently `block-credential-reads.sh` denies `aws sts get-session-token` and `aws sts assume-role` in its print_patterns. **Decision**: Keep that block — Claude shouldn't assume roles itself; only the operator should via `appserver.sh auth`. The CLI runs from the operator's shell, not Claude's, so the Claude-context hook doesn't fire on `appserver.sh auth`. But verify this with explicit tests.

### New auth-flow test harness
- [ ] **T037** Create `tests/auth-flow-test.sh` (mirrors the assertion harness style of `.claude/hooks/test-hooks.sh`):
  - Mocks `aws sts assume-role` (returns canned JSON)
  - Asserts `assume_role readonly` writes the right profile shape to a temp `~/.aws/credentials`
  - Asserts `ensure_session_valid_for_role` correctly detects expired sessions
  - Asserts `auth status` produces parseable output
  - Asserts the SUBCOMMAND_ROLE map covers every CLI subcommand
- [ ] **T038** Wire `tests/auth-flow-test.sh` into the Validate CI workflow alongside `bash .claude/hooks/test-hooks.sh`.

### Pre-commit + CI checks
- [ ] **T039** All phase 1 checks must still pass.
- [ ] **T040** New: `bash tests/auth-flow-test.sh` must pass.
- [ ] **T041** `bash .claude/hooks/test-hooks.sh` must show `PASS: 178+, FAIL: 0` (added 3+ allow assertions).

### Manual smoke testing
- [ ] **T042** Fresh shell: `unset AWS_PROFILE && ./scripts/appserver.sh status` → should prompt for MFA, assume readonly, show status. Subsequent calls in same shell should reuse cached session.
- [ ] **T043** `./scripts/appserver.sh app deploy cookie` → should prompt for MFA again (cookie-ops role; different role = new MFA prompt). Performs deploy.
- [ ] **T044** `./scripts/appserver.sh deploy` → should prompt for MFA, assume deploy-role, run terraform apply.
- [ ] **T045** `./scripts/appserver.sh auth status` → shows time remaining for all three sessions.
- [ ] **T046** Verify CloudTrail entries show `RoleSessionName` distinguishing readonly/cookie-ops/deploy.

### CI gate + merge
- [ ] **T047** Push, CI green, merge.

**Checkpoint**: Phase 3 done. New flow works alongside the old long-lived key.

---

## Phase 4 — Skill documentation + cutover

### Documentation updates
- [ ] **T048** [P] Update `.claude/skills/appserver-ops/SKILL.md`:
  - Replace `Use AWS_PROFILE=appserver` with `Run ./scripts/appserver.sh auth at the start of a session`
  - Note that diagnostic phases (Phase 1: Triage) use the readonly role automatically
  - Add a "Permissions you'll have" subsection explaining which CLI subcommands escalate to which roles
- [ ] **T049** [P] Update `.claude/skills/cookie-ops/SKILL.md` similarly.
- [ ] **T050** [P] Update `.claude/skills/threat-ops/SKILL.md` similarly. Note Cloudflare token flow is unchanged.
- [ ] **T051** [P] Update `CLAUDE.md` "Developer Setup" section with new MFA enrolment step and `auth` subcommand.
- [ ] **T052** [P] Update `README.md` "Getting Started" to walk through MFA enrolment.
- [ ] **T053** [P] Update `terraform/appserver-admin-policy.json` if it needs new IAM permissions to manage MFA devices (likely already has them via `iam:*` but verify).

### End-to-end skill tests
- [ ] **T054** Run `/appserver-ops "is appserver healthy"` from a fresh shell. Verify it uses readonly throughout.
- [ ] **T055** Run `/cookie-ops "list cookie users"` from a fresh shell. Verify it escalates to cookie-ops only when needed.
- [ ] **T056** Run `/threat-ops` from a fresh shell. Verify readonly + Cloudflare API.
- [ ] **T057** Run a full `./scripts/appserver.sh app deploy cookie` from a fresh shell. Verify cookie-ops role is used.

### Pre-commit + CI checks
- [ ] **T058** All previous checks pass.
- [ ] **T059** Markdown lint clean (if a linter exists in the repo; otherwise `grep -RnE '<[A-Z]+>' .claude/skills/` to catch stray placeholder text).

### Soak period
- [ ] **T060** Use the new flow as default for one week. Note any friction or bugs in a working list. Old key remains active as fallback.

### CI gate + merge
- [ ] **T061** Push, CI green, merge.

**Checkpoint**: Phase 4 done. Skills updated. New flow is default. Old key still active for emergencies.

---

## Phase 5 — Decommission long-lived deployer key

### Detach direct policies from deployer user
- [ ] **T062** Update terraform: remove the three `aws_iam_user_policy_attachment` entries that attach `AppserverDeployerCompute`, `AppserverDeployerIamSsm`, `AppserverDeployerMonitoringStorage` to the deployer USER. They remain attached to the deploy-role.
- [ ] **T063** Apply: `./scripts/appserver.sh deploy`. Plan should show three policy detachments and zero other changes.

### Verify the deployer user is now minimal
- [ ] **T064** `aws iam list-attached-user-policies --user-name appserver-deployer` — should show only `AppserverDeployerAssumeRoles`.

### Deactivate the long-lived access key
- [ ] **T065** Operator: in AWS console, deactivate (do not delete) the long-lived access key on `appserver-deployer`.
- [ ] **T066** Verify: `aws iam list-access-keys --user-name appserver-deployer` shows the key as `Inactive`.

### Remove the CLI fallback
- [ ] **T067** Remove the backwards-compat fallback added in T034. The CLI now requires the new flow.
- [ ] **T068** Remove the deprecation-warning helper.

### Final smoke testing
- [ ] **T069** From a clean shell with no `appserver` profile in `~/.aws/credentials` and no `AWS_PROFILE` set, run every top-level subcommand. Each must prompt for MFA on the first call, work thereafter.
- [ ] **T070** Re-run all hook tests (`bash .claude/hooks/test-hooks.sh` → 178+/178+) and auth-flow tests (`bash tests/auth-flow-test.sh`).
- [ ] **T071** Verify CI workflow stays green.

### Documentation finalisation
- [ ] **T072** Update README to remove any mention of the long-lived key flow.
- [ ] **T073** Add a "Migrating from long-lived deployer key" troubleshooting section to README for anyone forking the repo from an old commit.

### CI gate + merge
- [ ] **T074** Push, CI green, merge.

**Checkpoint**: Phase 5 done. Long-lived key inactive. New flow is the only flow.

### One week later
- [ ] **T075** Operator: delete the deactivated access key from `appserver-deployer`. (Manual AWS console step.)

---

## Quality Gates Summary (run at every phase)

Every commit on this branch MUST pass:

1. `terraform -chdir=terraform fmt -check -recursive`
2. `cd terraform && terraform init -backend=false && terraform validate`
3. `tfsec terraform/`
4. `shellcheck scripts/*.sh .claude/hooks/*.sh`
5. `bash .claude/hooks/test-hooks.sh`
6. `bash tests/auth-flow-test.sh` (from phase 3 onwards)
7. `gitleaks protect --staged` (via pre-commit)
8. The full Validate CI workflow

These are the same gates that already exist in `.github/workflows/validate.yml`. The plan adds `tests/auth-flow-test.sh` to that workflow in phase 3.

## Rollback Cheatsheet

| Phase | If something breaks, do this |
|---|---|
| 1 | `git revert` and `terraform apply`. New resources are removed; existing flow unaffected. |
| 2 | Detach `AppserverDeployerAssumeRoles` from the deployer user. Old direct policies still grant everything needed. |
| 3 | Revert the CLI changes. Operator's old `appserver` profile still has long-lived key with full perms. |
| 4 | Revert the skill doc changes. CLI fallback still works. |
| 5 | Reactivate the deactivated access key. Re-attach the three direct policies via terraform. Re-add the fallback. |
