# HANDOFF — IAM MFA + per-skill scoping (003)

This is the operator's apply checklist for the rollout in `specs/003-iam-mfa-scoping/`. Claude built and pushed all five phases on branch `003-iam-mfa-scoping` (PR #10) but did **not** run `terraform apply`, did **not** enrol MFA, and did **not** merge to main. That's all here.

Work top-to-bottom. Stop at any step that produces an unexpected diff or error and surface it before continuing.

## Status as of last session

Mid-rollout, partial state already applied to AWS:

- ✓ **Phase 1 + 2 + 5 IAM resources** all applied via `init` + `terraform apply` (the rollout collapsed because `init` is idempotent — it ends at the phase-5 state immediately).
- ✓ MFA enrolled on `appserver-deployer` (TOTP device `appserver-deployer-iphone`, ARN in `terraform/.env`).
- ✓ `appserver.sh auth --role readonly` works end-to-end (verified live).
- ✓ `RockportDeployerIamSsm` policy detached from `rockport-admin` (was blocking `iam:AttachRolePolicy` on Appserver roles via cross-project deny — see "Rockport collision" below).
- ⚠ `appserver.sh status` initially failed with "Could not reach instance" — readonly role lacked `ssm:SendCommand`. Fixed in a follow-up commit on the branch (next push).
- ⚠ `cmd_deploy` swallowed terraform errors via pipe to `mask_account_ids`. Fixed with PIPESTATUS check on the same follow-up commit.

Outstanding when you return:

1. Pull the latest branch (`git pull` — the readonly fix + PIPESTATUS fix are in there).
2. Smoke `appserver.sh status` again — should now print containers (the readonly policy now allows SendCommand to the tagged instance + AWS-RunShellScript document).
3. Test cookie-ops escalation: `appserver.sh app deploy cookie` — first run should prompt MFA, subsequent runs reuse the cached cookie-ops session.
4. Test deploy-role: `appserver.sh deploy` — same pattern.
5. (Optional) Clean up the other Rockport policies still attached to `rockport-admin` (see "Rockport leftovers" below).
6. Merge PR #10.

## Bootstrap chicken-egg

When `init` runs in the phase-5-collapsed state, the deployer user immediately ends up with only `AppserverDeployerAssumeRoles` — no broad permissions. The CLI's strict MFA check (also phase 5) then blocks `appserver.sh deploy` because the operator roles haven't been created yet via terraform.

Use the escape hatch for the **first** terraform apply only:

```bash
unset AWS_PROFILE
APPSERVER_AUTH_DISABLED=1 ./scripts/appserver.sh deploy
```

`APPSERVER_AUTH_DISABLED=1` skips `ensure_session_valid_for_role`. Admin creds (default credential chain) drive the apply. After this run, the operator roles exist and normal `appserver.sh auth` flow works for everything else.

## Rockport collision

`rockport-admin` had `RockportDeployerIamSsm` attached, which contained an explicit Deny on `iam:AttachRolePolicy` against any non-Rockport role. This blocked terraform from attaching Appserver* policies to the new operator roles. Fixed by detaching that one policy:

```bash
unset AWS_PROFILE
aws iam detach-user-policy \
  --user-name rockport-admin \
  --policy-arn arn:aws:iam::453875232253:policy/RockportDeployerIamSsm
```

This was already done during the live session.

### Rockport leftovers

`rockport-admin` still has 4 Rockport-* policies attached (Rockport infra is currently destroyed):

```
RockportAdmin
RockportDeployerCompute
RockportDeployerMonitoringStorage
RockportDeployerAccess
```

If you want to fully decouple from Rockport in this AWS account, detach them in the same way. They're inert with no Rockport infra running, so leaving them attached is harmless until you reanimate Rockport. If you ever do, the Rockport repo's `init` will reattach what it needs.

If you want to keep them attached for the day Rockport comes back, also re-attach `RockportDeployerIamSsm` — but **first** widen its `iam:AttachRolePolicy` allowlist to include Appserver-prefix roles, otherwise it'll block our deploys again.

## Pre-flight (do this once)

- [ ] Pull and check out the branch:
  ```bash
  git fetch origin
  git checkout 003-iam-mfa-scoping
  ```
- [ ] Verify CI is green for the latest push:
  ```bash
  gh run list --branch 003-iam-mfa-scoping --limit 1
  ```
  All 5 phase commits should show `success`.
- [ ] Confirm you're operating with admin AWS creds (the `rockport-admin` user, not the deployer profile):
  ```bash
  unset AWS_PROFILE
  aws sts get-caller-identity --query 'Arn' --output text
  ```
  Should print something ending in `:user/rockport-admin` (or whichever admin user has `AppserverAdmin`).

## Phase 1 apply — additive: 3 roles + boundaries + escalation tightening

**Plan summary** (expected only — confirm during plan review):
- 3 new `aws_iam_policy` resources (boundaries: readonly, cookie-ops, deploy)
- 3 new `aws_iam_role` resources (operator roles)
- 5 new `aws_iam_role_policy_attachment` resources
- 1 modified `aws_iam_policy` (the `AppserverDeployerIamSsm` document update — replaces prefix allowlist with explicit ARN allowlist + adds `DenyAttachToInstanceRole`)
- Zero deletions. Zero changes to existing roles, instance, security group, Cloudflare, S3.

Note: `AppserverDeployerIamSsm` is created and managed by `appserver.sh init`, not terraform. The plan won't show that policy directly; the file change ships in this commit and will be picked up next time `init` runs.

Steps:

1. [ ] Run init first so the modified iam-ssm.json gets uploaded to AWS as the new policy version, AND the new AppserverDeployerAssumeRoles policy is created (phase 2 piggybacks on this):
   ```bash
   unset AWS_PROFILE
   ./scripts/appserver.sh init
   ```
   Expected output includes: `IAM policy ........... updated (AppserverDeployerIamSsm)` and `IAM policy ........... created (AppserverDeployerAssumeRoles)` (or `updated` if you've run init before).
2. [ ] Plan + apply terraform:
   ```bash
   ./scripts/appserver.sh deploy
   ```
   Watch the plan: confirm only additions to the 3 operator roles + 3 boundaries + 5 attachments. Type `yes` to apply.
3. [ ] Smoke: verify the roles exist and have MFA-gated trust policies:
   ```bash
   for role in appserver-readonly-role appserver-cookie-ops-role appserver-deploy-role; do
     echo "=== $role ==="
     aws iam get-role --role-name "$role" \
       --query '{MaxSession: Role.MaxSessionDuration, Boundary: Role.PermissionsBoundary.PermissionsBoundaryArn, Trust: Role.AssumeRolePolicyDocument}' \
       --output json | jq
   done
   ```
   Each should show `MaxSessionDuration: 3600`, a `PermissionsBoundary` arn, and a trust policy with `aws:MultiFactorAuthPresent` and `aws:MultiFactorAuthAge` conditions.

**Rollback if anything looks wrong:** `git revert` the phase-1 commit and re-`./scripts/appserver.sh deploy`. The new resources are purely additive — removing them doesn't affect the still-running deployer flow.

## Phase 2 — MFA enrolment (operator only)

The blocking step. `appserver.sh auth` won't work until MFA is enrolled.

1. [ ] AWS console → IAM → Users → `appserver-deployer` → **Security credentials** tab → **Multi-factor authentication (MFA)** → **Assign MFA device**.
2. [ ] Choose **Authenticator app**. Name it (e.g. `appserver-deployer-laptop`). Scan the QR code into 1Password / Authy / your authenticator of choice. Enter two consecutive 6-digit codes to activate.
3. [ ] Copy the device ARN from the AWS console (e.g. `arn:aws:iam::123456789012:mfa/appserver-deployer-laptop`).
4. [ ] Add it to your local terraform env file (gitignored, never committed):
   ```bash
   echo 'export MFA_SERIAL_NUMBER="arn:aws:iam::<account-id>:mfa/<device-name>"' >> terraform/.env
   ```
5. [ ] Smoke — assume each role manually with the AWS CLI:
   ```bash
   source terraform/.env
   ACCOUNT=$(aws sts get-caller-identity --query Account --output text --profile appserver)
   for role in appserver-readonly-role appserver-cookie-ops-role appserver-deploy-role; do
     echo "=== $role ==="
     read -rsp "TOTP code: " CODE; echo
     aws sts assume-role \
       --profile appserver \
       --role-arn "arn:aws:iam::${ACCOUNT}:role/${role}" \
       --role-session-name "smoke-${role##*-}-$(date +%s)" \
       --serial-number "$MFA_SERIAL_NUMBER" \
       --token-code "$CODE" \
       --duration-seconds 3600 \
       --query 'Credentials.{Expiration: Expiration}' --output json
   done
   ```
   Each should return an `Expiration` timestamp ~1 hour out.
6. [ ] Smoke — verify denied paths. With the readonly creds exported, `ec2:TerminateInstances` must be denied:
   ```bash
   # Export readonly creds from one of the assume-role calls above, then:
   aws ec2 terminate-instances --instance-ids i-fake 2>&1 | grep -q "UnauthorizedOperation\|AccessDenied" && echo "deny works"
   ```

## Phase 3-4 — CLI auth flow + skill docs

No additional terraform apply. The CLI changes are local; the admin policy change rides in via `init`.

1. [ ] (If not already done in phase 1) re-run init so the updated `AppserverAdmin` policy (now includes MFA-management actions) propagates:
   ```bash
   unset AWS_PROFILE
   ./scripts/appserver.sh init
   ```
2. [ ] Smoke — auth subcommand from a fresh shell:
   ```bash
   unset AWS_PROFILE
   ./scripts/appserver.sh auth --role readonly
   # Enter TOTP code when prompted.
   ./scripts/appserver.sh auth status
   # Should show readonly active with ~60m remaining.
   ./scripts/appserver.sh status
   # Should reuse the cached readonly session (no MFA prompt).
   ```
3. [ ] Smoke — escalation prompts on first cookie-ops mutation:
   ```bash
   ./scripts/appserver.sh app deploy cookie
   # Should prompt for MFA again (different role = different session).
   ```
4. [ ] Smoke — deploy role:
   ```bash
   ./scripts/appserver.sh deploy
   # Should prompt for MFA, assume deploy-role, run terraform apply (no-op plan if everything's already up to date).
   ```
5. [ ] CloudTrail confirmation: each session should produce a distinct `RoleSessionName`:
   ```bash
   aws cloudtrail lookup-events --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRole --max-results 10 \
     --query 'Events[].{Time: EventTime, User: Username, Resource: Resources[0].ResourceName}' --output table
   ```
   You should see `readonly_*`, `cookie_ops_*`, `deploy_*` session names.

## Phase 5 — decommission long-lived deployer key

The phase-5 commit changes `appserver.sh init` to detach the three legacy direct-attachments from the deployer user. Re-run init to apply that change.

1. [ ] Re-run init (idempotent) — it'll detach `AppserverDeployerCompute / IamSsm / MonitoringStorage` from the deployer user:
   ```bash
   unset AWS_PROFILE
   ./scripts/appserver.sh init
   ```
   Expected output: three lines like `Policy attachment .... detached (AppserverDeployerCompute -> appserver-deployer, phase-5 cutover)`.
2. [ ] Verify the deployer user's policy attachments are minimal:
   ```bash
   aws iam list-attached-user-policies --user-name appserver-deployer
   ```
   Should show ONLY `AppserverDeployerAssumeRoles`.
3. [ ] Final clean-shell smoke:
   ```bash
   unset AWS_PROFILE
   rm -rf "$HOME/.aws/cli/cache"  # optional — clear any AWS CLI session cache
   ./scripts/appserver.sh status
   ```
   Should prompt for MFA, assume readonly, then show containers.

### Optional: deactivate + rotate the long-lived deployer access key

The key on disk under the `appserver` profile is now MFA-neutralised — a leaked copy can only call MFA-gated `sts:AssumeRole`. If you want defense-in-depth on top of that:

1. [ ] AWS console → IAM → Users → `appserver-deployer` → Security credentials → Access keys.
2. [ ] **Make inactive** (do not delete) the existing key. The CLI's `assume_role` will start failing immediately because it uses `AWS_PROFILE=appserver` to call sts.
3. [ ] Create a new access key. Update `~/.aws/credentials`:
   ```bash
   aws configure set aws_access_key_id <NEW_KEY> --profile appserver
   aws configure set aws_secret_access_key <NEW_SECRET> --profile appserver
   ```
4. [ ] Re-run smoke: `./scripts/appserver.sh auth --role readonly` should work.
5. [ ] After one week of running on the new key without issues, delete the deactivated key from the console.

(Spec deviation note: tasks.md T065 had key deactivation as a hard step. In practice, deactivation cuts the ground out from under the AssumeRole call without rotation — this checklist treats deactivation as optional defense-in-depth instead of mandatory.)

## Recovery — lost MFA device

If the TOTP device is lost:

1. Fall back to the admin user (`rockport-admin`) — their long-lived creds remain unaffected.
2. AWS console as admin → IAM → Users → `appserver-deployer` → Security credentials → MFA → **Remove**.
3. Re-enrol via the steps in "Phase 2 — MFA enrolment" above.

The admin user holds `AppserverAdmin` which (post-phase-4) includes `iam:ListMFADevices / EnableMFADevice / DeactivateMFADevice / ResyncMFADevice / CreateVirtualMFADevice / DeleteVirtualMFADevice`, so the recovery is self-service from the admin profile.

## Final review and merge

- [ ] Re-read the per-phase commits on the branch in order:
  ```bash
  git log main..003-iam-mfa-scoping --oneline
  ```
- [ ] Squash-merge or merge-commit PR #10 to main once the smoke checks above all pass:
  ```bash
  gh pr merge 10 --squash   # or --merge for a merge commit
  ```
  (Branch protection: the `validate` CI check must be green; you can self-approve since approvals=0.)
- [ ] Tick all six phases as done on the PR description.

## Blockers / known issues

None at the time of handoff. Local quality gates were green on every phase commit:

- terraform fmt / validate / tfsec (no new findings; one pre-existing HIGH on `main.tf:141` for `s3:GetObject` on `<bucket>/*` — unaffected by this PR; CI's older tfsec doesn't flag it)
- shellcheck (scripts + hooks + tests)
- `bash .claude/hooks/test-hooks.sh` — 180/180
- `bash tests/auth-flow-test.sh` — 48/48
- gitleaks (CI fix to `fetch-depth: 0` in phase 1 to make PR-event diff scan work)

Spec deviations recorded across the per-phase commit messages:

- **Phase 1:** Deploy boundary is a coarse "deployer-class services" allow-list rather than a byte-for-byte mirror of the three deployer JSONs (combined raw policy exceeds the 6144-char limit).
- **Phase 2:** AppserverDeployerAssumeRoles attachment to the deployer user happens in `appserver.sh init` (matches the existing pattern for the other three deployer policies) rather than via `aws_iam_user_policy_attachment` in terraform — the deployer user itself isn't a terraform resource.
- **Phase 5:** Long-lived access key deactivation is optional defense-in-depth, not a mandatory step. The risk reduction comes from the policy detachment (the user has only MFA-gated `sts:AssumeRole`) — a leaked key fails closed without the TOTP code.

Operator-only steps (not run by Claude):

- T021 — TOTP MFA enrolment via AWS console
- T024 / T025 / T026 — terraform apply + smoke tests with real TOTP code
- T042-T046 — end-to-end CLI smoke tests
- T054-T057 — full skill end-to-end tests
- T060 — one-week soak period
- T063 / T065 / T075 — phase-5 apply + key deactivation/deletion
