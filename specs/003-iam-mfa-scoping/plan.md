# Implementation Plan: IAM MFA + Per-Skill Scoping

**Branch**: `003-iam-mfa-scoping` | **Date**: 2026-05-03 | **Spec**: [spec.md](spec.md)

## Summary

Replace the current single-deployer-with-long-lived-key model with three IAM roles (readonly, cookie-ops, deploy) assumable from the deployer user with MFA + 1-hour STS sessions. Default Claude operations to readonly; escalate explicitly when mutations are needed. Tighten `DenyManagedPolicyEscalation` to a name allowlist. Roll out in five phases — each phase is independently safe to merge and revert.

## Technical Context

**Languages**: Terraform (HCL), Bash (CLI + hooks), JSON (IAM policy docs)
**Primary AWS APIs**: IAM (CreateRole, AttachRolePolicy, PutRolePermissionsBoundary), STS (AssumeRole, GetSessionToken)
**Storage**: `~/.aws/credentials` for STS sessions; `~/.aws/cli/cache/` for AWS CLI's session cache
**Testing**: Existing — `terraform fmt -check`, `terraform validate`, `tfsec`, `shellcheck`, `bash .claude/hooks/test-hooks.sh` (175 cases). New — assume-role smoke tests, CLI auth subcommand unit tests via the hook test harness pattern.
**Target platform**: Operator's laptop (current setup); CI on GitHub Actions
**Constraints**: Cannot lock the operator out mid-rollout. Old access key must keep working until phase 5. Hook self-test must keep passing throughout. CI must stay green on every commit.

## Design Decisions

### D1: Three roles, not one role with conditions

A single role with conditional policies (e.g. "if session-name starts with `readonly-`, deny mutations") would be cleaner in CloudTrail but harder to reason about and harder to audit. Three roles keeps each policy document focused and means the IAM evaluation engine, not regex on session names, enforces the boundary.

### D2: AssumeRole, not GetSessionToken

`sts:GetSessionToken` returns credentials with the same permissions as the calling user — useful for MFA-gating but doesn't change the permission scope. `sts:AssumeRole` returns credentials for a *different* principal, which is what we need for per-skill scoping. The deployer user keeps `sts:AssumeRole` only; all real permissions live on the assumed roles.

### D3: 1-hour MaxSessionDuration

AWS minimum is 1 hour. We could go up to 12. 1 hour is the right floor for a hobby setup — frequent re-auth is a small daily friction in exchange for blast radius reduction. If the daily friction proves painful in real use, 4 hours is a reasonable bump for the readonly role only (deploy and cookie-ops should stay short).

### D4: Default profile points to readonly; explicit profile flip for mutations

Two options for how the CLI selects roles:
- (a) Each subcommand maps internally to a role and assumes it on demand
- (b) The user runs `appserver.sh auth` with a role argument and that profile is active for the session

Going with (a) for the everyday flow, with (b) available as `appserver.sh auth --role deploy` for sessions that need elevated permissions throughout. Option (a) means routine `status` calls don't prompt for MFA every time (the cached readonly session covers them).

### D5: The AssumeRole policy on the deployer user is itself MFA-conditioned

Even though the role's trust policy can require MFA, applying the condition at the user level too is belt-and-braces and provides clearer error messages.

```json
{
  "Effect": "Allow",
  "Action": "sts:AssumeRole",
  "Resource": [
    "arn:aws:iam::*:role/appserver-readonly-role",
    "arn:aws:iam::*:role/appserver-cookie-ops-role",
    "arn:aws:iam::*:role/appserver-deploy-role"
  ],
  "Condition": {
    "Bool": {"aws:MultiFactorAuthPresent": "true"},
    "NumericLessThan": {"aws:MultiFactorAuthAge": "3600"}
  }
}
```

### D6: Bonus DenyManagedPolicyEscalation fix

Replace the current prefix allowlist (`appserver-*`) with an explicit name allowlist (`AppserverDeployerCompute`, `AppserverDeployerIamSsm`, `AppserverDeployerMonitoringStorage`, `AmazonSSMManagedInstanceCore`, `AWSDataLifecycleManagerServiceRole`, plus the new role-attached policies). Closes the "create `appserver-bypass`, attach it" path.

### D7: Add explicit deny on `iam:AttachRolePolicy` against `appserver-instance-role`

Belt-and-braces alongside the boundary. Even if a policy passed the allowlist check, attaching anything to the instance role is denied at runtime.

## Phased Rollout

Each phase is a separate commit (or PR) and ships independently. No phase breaks the previous phase's behaviour; each can be reverted without forensic work.

### Phase 1 — Additive: new policies and roles, deployer keeps current access (LOW RISK)

**What:**
- Add `terraform/deployer-policies/readonly.json` (read-only permissions across EC2, SSM, CloudWatch, CE, Logs, S3 read on artifacts/state).
- Add `terraform/deployer-policies/cookie-ops.json` (readonly + `ssm:SendCommand` on tagged instance + `ssm:GetParameter` on `/appserver/*`).
- Add three new IAM roles in `terraform/main.tf`: `appserver-readonly-role`, `appserver-cookie-ops-role`, `appserver-deploy-role`. Each has a permissions boundary that caps it at the role's intended ceiling.
- Each role's trust policy allows `sts:AssumeRole` from `arn:aws:iam::ACCOUNT:user/appserver-deployer`, conditioned on `aws:MultiFactorAuthPresent=true` and `aws:MultiFactorAuthAge < 3600`.
- `MaxSessionDuration = 3600` on all three roles.
- The bonus tightening: replace `DenyManagedPolicyEscalation` regex with an explicit name allowlist; add `DenyAttachToInstanceRole` deny statement.

**What does NOT change:**
- The deployer user keeps its three current managed policies attached directly. Old access key keeps working.
- No CLI changes. No skill changes.

**Checks (must all pass before merge):**
- `terraform fmt -check -recursive`
- `cd terraform && terraform init -backend=false && terraform validate`
- `tfsec terraform/` (locally; CI runs it too)
- Manual `terraform plan` review — should show only additions, no deletions
- `bash .claude/hooks/test-hooks.sh` (175 cases)
- `shellcheck` clean on any modified shell
- `gitleaks protect --staged` (via pre-commit)
- Validate CI workflow green

**Apply:**
- `./scripts/appserver.sh deploy` (terraform apply with operator review of the plan)

**Smoke test after apply:**
- Verify roles exist: `aws iam get-role --role-name appserver-readonly-role`
- Verify trust policy has MFA condition

**Rollback:**
- `git revert` and `terraform apply` — purely additive, removing the new resources won't affect the still-running deployer flow.

### Phase 2 — MFA enrolment + AssumeRole policy on deployer user (LOW RISK)

**What:**
- Operator manually enrols a TOTP MFA device on the `appserver-deployer` user (AWS console or `aws iam enable-mfa-device`). Manual step — not in code.
- Add a new managed policy `AppserverDeployerAssumeRoles` granting `sts:AssumeRole` on the three roles, MFA-conditioned. Attach to the deployer user.
- Verify by hand: `aws sts assume-role --role-arn ... --serial-number ... --token-code ... --role-session-name test` returns 1-hour creds, and using those creds, `aws ec2 describe-instances` works (for readonly), `aws ec2 terminate-instances ...` is denied (for readonly).

**What does NOT change:**
- The deployer user STILL has the three direct managed policies. The new assume-role policy is additive. Operator can still use the old long-lived key for any work.
- CLI unchanged.

**Checks:**
- Same as phase 1, plus:
- Manual smoke: assume-role + describe + denied-mutation test for each of the three roles
- Confirm MFA-without-token fails as expected

**Rollback:**
- Detach the new policy from the deployer user. Old key flow continues.

### Phase 3 — CLI `auth` subcommand + per-subcommand role mapping (MEDIUM RISK)

**What:**
- Add `cmd_auth()` to `scripts/appserver.sh`. Accepts an optional `--role <name>` argument (default: prompt for which role per session, or default to `readonly` if `auth` is called without `--role`).
- New helper `assume_role()` in `scripts/appserver.sh`: prompts for TOTP code, calls `aws sts assume-role` with the deployer creds, writes the returned creds to `~/.aws/credentials` under profile `appserver-<role>`, and exports `AWS_PROFILE=appserver-<role>` for the rest of the shell.
- New helper `ensure_session_valid()`: checks STS expiry on the active profile; if within 5 minutes of expiry, prompts re-auth.
- Subcommand-to-role map (in `scripts/appserver.sh`):
  - `status`, `logs`, `spend`, `app list`, `threats analyze`, `threats blocked`, `threats allowed`, `threats list`, `threats report`, `setup unlock`, `setup lock` → `appserver-readonly-role`
  - `app deploy`, `app init`, `app remove`, `app restart`, `app env`, `config push`, `threats block`, `threats unblock`, `threats allow`, `threats unallow` → `appserver-cookie-ops-role`
  - `init`, `deploy`, `destroy`, `start`, `stop`, `ssh` → `appserver-deploy-role`
- Each subcommand calls `ensure_session_valid_for_role <role>` at entry; that helper either uses an existing valid session for that role or assumes the role afresh.
- `auth status` subcommand shows: which roles have active sessions, time remaining for each, which is currently selected via `AWS_PROFILE`.
- Backwards-compat: if `AWS_PROFILE=appserver` is set (the old long-lived profile) and works, the CLI falls back to the old flow with a deprecation warning. Removed in phase 5.

**What does NOT change:**
- AWS-side: nothing changes from phase 2.
- Skills: still document `AWS_PROFILE=appserver`, but the CLI handles the new flow under the hood for now.

**Checks:**
- All phase 1 checks
- Add new test cases to `.claude/hooks/test-hooks.sh`: assert that `appserver.sh auth` is allowed by the destructive-bash hook (it isn't destructive — calls sts:AssumeRole and writes to ~/.aws/credentials, which IS denied by `block-credential-reads.sh` for direct Edits but the CLI is using `aws configure set` which goes via API — verify the hook lets the command through). Also add an explicit allow assertion for `./scripts/appserver.sh auth`.
- New shell-level tests: write a small `tests/auth-flow-test.sh` that mocks `aws sts assume-role` and verifies the helper writes the right profile shape, handles expiry, etc.
- Add `tests/auth-flow-test.sh` to the Validate CI workflow.

**Smoke test:**
- Fresh shell: `unset AWS_PROFILE && ./scripts/appserver.sh status` → should prompt for MFA, assume readonly, show status.
- Same shell again: `./scripts/appserver.sh logs cookie` → should reuse cached readonly session.
- `./scripts/appserver.sh app deploy cookie` → should prompt for MFA again (cookie-ops role), do the deploy.
- `./scripts/appserver.sh deploy` → should prompt for MFA, assume deploy-role, terraform apply.

**Rollback:**
- Revert the CLI changes; old profile flow works unchanged.

### Phase 4 — Skill documentation + cutover (HIGHER RISK)

**What:**
- Update `.claude/skills/appserver-ops/SKILL.md`, `.claude/skills/cookie-ops/SKILL.md`, `.claude/skills/threat-ops/SKILL.md` to remove `AWS_PROFILE=appserver` references and replace with "the CLI handles role selection per subcommand; just run `./scripts/appserver.sh auth` first".
- Update `CLAUDE.md` and `README.md` to describe the new auth flow.
- Update `terraform/appserver-admin-policy.json` and the bootstrap docs to mention MFA setup.
- Run a full end-to-end test on each skill:
  - `/appserver-ops status` — should run via readonly
  - `/cookie-ops "list users"` — should escalate to cookie-ops role
  - `/threat-ops analyze` — should run via readonly + Cloudflare token (Cloudflare flow unchanged)
  - Full `/appserver-ops deploy` — should escalate to deploy-role

**Checks:**
- All previous checks
- Lint markdown changes
- Manually verify CloudTrail shows distinct role-session-names for each operation type
- Soak for a week (or whatever feels right): use the new flow as the default, keep the old key around for emergency fallback

**Rollback:**
- Revert the skill doc changes; CLI fallback to old key still works.

### Phase 5 — Decommission the long-lived deployer key (FINAL CUTOVER)

**What:**
- Detach `AppserverDeployerCompute`, `AppserverDeployerIamSsm`, `AppserverDeployerMonitoringStorage` from the deployer USER. They remain attached to the deploy-role. Deployer user now has only `AppserverDeployerAssumeRoles`.
- Deactivate (not delete) the long-lived access key. Keep it in case of emergency for one more week.
- Remove the backwards-compat fallback from `scripts/appserver.sh`.
- Final docs update: README "Getting Started" walks through MFA enrolment.

**Checks:**
- All previous checks
- Final smoke: every CLI subcommand from a clean shell with no `appserver` profile in `~/.aws/credentials`. Each must prompt for MFA on the first call, work correctly thereafter.
- Verify the CI workflow is still green.
- Verify `bash .claude/hooks/test-hooks.sh` still 175/175.

**One week later:**
- Delete the deactivated access key.

**Rollback:**
- Reactivate the access key. Re-attach the three policies. Re-enable the CLI fallback. (This is the last-resort path; a clean rollback at this point implies something serious went wrong.)

## Risks and Mitigations

| Risk | Mitigation |
|---|---|
| Operator loses MFA device mid-rollout | `AppserverAdmin` policy on calling admin user is the recovery lever; can re-enrol MFA via console |
| Phase 3 CLI bug breaks all CLI calls | Old long-lived key remains active through phase 4; operator can `unset AWS_PROFILE && export AWS_ACCESS_KEY_ID=...` as fallback |
| MFA-conditioned trust policy applied before MFA enabled — operator locked out | Phase 2 enrols MFA before phase 1's role trust policies become load-bearing (deployer user still has direct policies through phase 4) |
| `tfsec` flags new IAM resources | Address each finding before merge; add `tfsec:ignore` only with documented justification (consistent with existing tfsec:ignore comments in the codebase) |
| Hook self-test breaks because `appserver.sh auth` matches some pattern | Add explicit allow-test for `appserver.sh auth ...` in `test-hooks.sh` early in phase 3 |
| CloudTrail logs grow in volume | Acceptable — each Claude session generates a handful of API calls; this won't move the needle |
| `aws sts assume-role` rate limits during heavy testing | AWS limit is 100 requests per 5 minutes per account — well above interactive use |

## Open Questions

- **Q1**: Should the readonly role have `MaxSessionDuration` of 4 hours instead of 1, given how often diagnostic work is interrupted? **Provisional**: Start at 1 hour for all three; bump readonly to 4 hours after a week of real use if the friction is annoying.
- **Q2**: Should the operator's IAM admin user (the one with `AppserverAdmin` for bootstrap) also lose its directly-attached deployer policies during phase 5? **Provisional**: Yes — at the end of phase 5, the admin user keeps `AppserverAdmin` only. Anyone needing deployer-tier access goes through the role flow like everyone else.
- **Q3**: Should hardware MFA (FIDO2) be supported in v1? **Decision**: No — TOTP only for v1 (FR-001). Hardware key support is a future spec.
- **Q4**: Should the post be updated to mention this work as "in progress"? **Decision**: No — the post describes what currently exists. When this lands, write a follow-up post or update the existing one.
