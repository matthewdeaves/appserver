# Feature Specification: MFA + Per-Skill IAM Scoping for Claude Code Operations

**Feature Branch**: `003-iam-mfa-scoping`
**Created**: 2026-05-03
**Status**: Draft
**Input**: User description: "Reduce blast radius of laptop compromise. Move from a single long-lived deployer access key to MFA-gated short-lived STS sessions. Split the deployer into per-skill scoped roles so each Claude skill operates with the minimum permissions it needs."

## Background

The current setup uses a single IAM user (`appserver-deployer`) with a long-lived access key on the operator's laptop. Three managed policies (`AppserverDeployerCompute`, `AppserverDeployerIamSsm`, `AppserverDeployerMonitoringStorage`) attach directly to the user. Every Claude Code session — diagnostic, app-management, or full deploy — runs with the same broad permissions.

The blog post at `2026-05-03-claude-code-as-my-devops-engineer` is honest about this: "The deployer IAM key on my laptop has a wide blast radius (full infra control plus Cookie admin via SSM), so a compromised laptop is bad regardless of how clever the hooks are." This spec narrows that blast radius.

There is also a known escalation path in `DenyManagedPolicyEscalation` (the prefix-based allowlist on `AttachRolePolicy` permits any policy named `appserver-*`, and the deployer can create such policies). This spec fixes that as a bonus.

## User Scenarios

### US1 — Operator authenticates with MFA before any AWS work (P1)

The operator runs `./scripts/appserver.sh auth` once at the start of a session. The CLI prompts for a TOTP code from their MFA device, exchanges credentials via `sts:AssumeRole`, and writes a 1-hour session to a `~/.aws/credentials` profile. Subsequent CLI calls in the same session use those temporary credentials. After expiry, the next call prompts re-authentication.

**Why P1**: Without this, the rest of the work doesn't reduce the blast radius — long-lived credentials on disk remain the dominant risk.

### US2 — Diagnostic Claude work uses a read-only role by default (P1)

When Claude runs `/appserver-ops` or `/threat-ops` for triage (no mutations expected), the CLI assumes `appserver-readonly-role` instead of the deploy role. CloudTrail shows the role-session-name was `readonly-<task>` for every diagnostic call. If the work needs to mutate something, Claude has to escalate explicitly.

**Why P1**: The majority of Claude's day-to-day work is diagnostic. Defaulting to read-only means most sessions can't issue any destructive AWS call even if the bash hook somehow let one through.

### US3 — Cookie app management uses a scoped role (P2)

`/cookie-ops` mutations (deploys, env changes, user admin) assume `appserver-cookie-ops-role` rather than the full deployer. The role grants only `ssm:SendCommand` on the tagged instance, `ssm:GetParameter` on `/appserver/*`, and basic reads. No IAM, no Terraform, no S3 deletions.

**Why P2**: Reduces blast radius further but is structurally similar to US2 — implementing US2 first makes US3 mechanical.

### US4 — Full deploys remain available but require explicit role assumption (P2)

`/appserver-ops` mutations (terraform apply, full deploys) assume `appserver-deploy-role`, which holds the current deployer's three policies. The CLI auth flow makes this an explicit choice rather than the default. The role assumption logs to CloudTrail with role-session-name `deploy-<task>`.

**Why P2**: Preserves existing capability while making "I'm about to do something destructive" a deliberate step.

### US5 — Bonus: tighten the AttachRolePolicy escalation path (P1)

The deny on `iam:AttachRolePolicy` for the instance role is widened from "policy ARN must not match `appserver-*` prefix" to "policy ARN must be in an explicit name allowlist". This closes the loophole where the deployer could create a privileged `appserver-bypass` policy and attach it to `appserver-instance-role`.

**Why P1**: Cheap to add alongside the boundary work, closes a real escalation path.

## Functional Requirements

- **FR-001**: The system MUST support TOTP-based MFA authentication on the `appserver-deployer` IAM user.
- **FR-002**: All deployer-tier AWS operations MUST go through `sts:AssumeRole` calls conditioned on `aws:MultiFactorAuthPresent=true`.
- **FR-003**: STS sessions MUST be limited to 1 hour by role configuration (`MaxSessionDuration`).
- **FR-004**: There MUST be three distinct IAM roles for operational use: read-only, cookie-ops, deploy. Each role's permissions MUST be the minimum needed for its scope.
- **FR-005**: The CLI MUST be able to assume a specific role per subcommand (e.g. `status` → readonly, `app deploy` → cookie-ops, `deploy` → deploy-role).
- **FR-006**: The CLI MUST surface session expiry — `auth status` shows time remaining and which role is active.
- **FR-007**: CloudTrail MUST be able to distinguish "which mode of work was active" from the role-session-name.
- **FR-008**: The bonus DenyManagedPolicyEscalation tightening MUST replace the prefix allowlist with an explicit policy-name allowlist.
- **FR-009**: All existing CLI subcommands MUST continue to work without behavioural change visible to the operator (other than the auth prompt).
- **FR-010**: The hook self-test (`bash .claude/hooks/test-hooks.sh`) MUST continue to pass with no changes — this work doesn't touch the destructive-bash hook.
- **FR-011**: The Validate CI workflow MUST continue to pass on every push.

## Non-Functional Requirements

- **NFR-001 — Recoverability**: If the operator loses their MFA device, the recovery path MUST be a documented IAM-admin manual step, not a code change. Recovery uses the existing `AppserverAdmin` policy attached to the calling admin user.
- **NFR-002 — Backwards compatibility**: During phases 1–3, the existing long-lived access key MUST keep working so the operator is never locked out mid-rollout.
- **NFR-003 — Auditability**: CloudTrail entries for each session MUST identify the role-session-name, which encodes the operational mode.

## Out of Scope

- Hardware MFA keys (TOTP only for v1). Hardware keys are a future addition.
- Cross-account role assumption.
- AWS SSO / IAM Identity Center integration.
- Slack/email notifications on destructive API calls (that's a separate spec).
- Outbound EC2 egress whitelist (separate spec).
- Per-engineer IAM identities (single-operator infra).

## Success Criteria

- **SC-001**: After cutover, the operator can complete a full Cookie deploy using only MFA-derived STS credentials. No long-lived access keys remain active in `~/.aws/credentials`.
- **SC-002**: A laptop compromise scenario (attacker exfiltrates `~/.aws/credentials`) cannot escalate beyond the active 1-hour session, and cannot use any IAM action without MFA.
- **SC-003**: CloudTrail shows distinct role-session-names for diagnostic vs. mutating operations.
- **SC-004**: All 175 existing hook self-tests pass.
- **SC-005**: `terraform fmt -check`, `terraform validate`, `tfsec`, `shellcheck`, and `gitleaks` all pass on every commit during and after the rollout.
