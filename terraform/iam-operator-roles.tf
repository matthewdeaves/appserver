# Per-skill operator roles assumed by the operator/Claude via MFA-gated
# sts:AssumeRole. The deployer IAM user (created by `appserver.sh init`,
# not by terraform) holds only `AppserverDeployerAssumeRoles` after the
# phase-5 cutover; all real permissions live on these three roles.
#
# Spec: specs/003-iam-mfa-scoping/spec.md
# Plan: specs/003-iam-mfa-scoping/plan.md
#
# - readonly: diagnostic / triage. No mutations.
# - cookie-ops: app-layer mutations (deploys, env, user admin via SSM).
# - deploy: terraform apply, full infra changes — equivalent to today's
#   deployer.
#
# All three trust policies require MFA-present and MFA-age < 3600s,
# enforced at the role level. Maximum session is 1 hour
# (FR-003) — re-auth often, lose less when keys leak.

locals {
  deployer_principal = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:user/appserver-deployer"

  operator_assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = local.deployer_principal }
      Action    = "sts:AssumeRole"
      Condition = {
        Bool            = { "aws:MultiFactorAuthPresent" = "true" }
        NumericLessThan = { "aws:MultiFactorAuthAge" = "3600" }
      }
    }]
  })
}

# ---------------------------------------------------------------------------
# Permissions boundaries — each role's ceiling. Even if extra policies were
# attached later, the role can never exceed the boundary's ALLOW set.
# ---------------------------------------------------------------------------

resource "aws_iam_policy" "operator_readonly_boundary" {
  name        = "appserver-operator-readonly-boundary"
  description = "Permissions boundary for appserver-readonly-role — caps role at read-only AWS API surface"
  policy      = file("${path.module}/deployer-policies/readonly.json")
  tags        = local.common_tags
}

resource "aws_iam_policy" "operator_cookie_ops_boundary" {
  name        = "appserver-operator-cookie-ops-boundary"
  description = "Permissions boundary for appserver-cookie-ops-role — caps role at cookie-app management surface"
  policy      = file("${path.module}/deployer-policies/cookie-ops.json")
  tags        = local.common_tags
}

# Deploy boundary is intentionally a coarse allow-list of "deployer-class"
# AWS services rather than a byte-for-byte mirror of the three deployer
# policies. Reasons:
#   1. Combined deployer JSONs exceed the 6144-char managed-policy limit.
#   2. The actual permissions for the deploy role come from attaching the
#      same three managed policies the deployer USER currently has
#      (compute / iam-ssm / monitoring-storage). The boundary's role is
#      to cap *anything else* that might get attached later — a coarse
#      allow-list serves that purpose without duplicating the policies.
#
# trivy:ignore:AVD-AWS-0057
# tfsec:ignore:aws-iam-no-policy-wildcards
resource "aws_iam_policy" "operator_deploy_boundary" {
  name        = "appserver-operator-deploy-boundary"
  description = "Permissions boundary for appserver-deploy-role — caps at deployer-class AWS API surface"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "DeployerClassServices"
      Effect = "Allow"
      Action = [
        "ec2:*",
        "iam:*",
        "ssm:*",
        "ssmmessages:*",
        "ec2messages:*",
        "s3:*",
        "dlm:*",
        "cloudwatch:*",
        "budgets:*",
        "ce:*",
        "logs:*",
        "sts:GetCallerIdentity",
        "sts:DecodeAuthorizationMessage",
        "tag:GetResources",
        "tag:GetTagKeys",
        "tag:GetTagValues"
      ]
      Resource = "*"
    }]
  })
  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# Roles — trust policy + boundary. MaxSessionDuration = 3600 (FR-003).
# ---------------------------------------------------------------------------

resource "aws_iam_role" "appserver_readonly" {
  name                 = "appserver-readonly-role"
  description          = "Diagnostic / read-only role assumed by the operator with MFA"
  max_session_duration = 3600
  permissions_boundary = aws_iam_policy.operator_readonly_boundary.arn
  assume_role_policy   = local.operator_assume_role_policy
  tags                 = local.common_tags
}

resource "aws_iam_role" "appserver_cookie_ops" {
  name                 = "appserver-cookie-ops-role"
  description          = "Cookie app-layer ops role assumed by the operator with MFA"
  max_session_duration = 3600
  permissions_boundary = aws_iam_policy.operator_cookie_ops_boundary.arn
  assume_role_policy   = local.operator_assume_role_policy
  tags                 = local.common_tags
}

resource "aws_iam_role" "appserver_deploy" {
  name                 = "appserver-deploy-role"
  description          = "Full deploy role (terraform apply, infra changes) assumed by the operator with MFA"
  max_session_duration = 3600
  permissions_boundary = aws_iam_policy.operator_deploy_boundary.arn
  assume_role_policy   = local.operator_assume_role_policy
  tags                 = local.common_tags
}

# ---------------------------------------------------------------------------
# Role-attached managed policies. The actual grants. Boundaries above cap
# them, so the effective permission is (attached ∩ boundary).
# ---------------------------------------------------------------------------

resource "aws_iam_policy" "operator_readonly" {
  name        = "AppserverOperatorReadonly"
  description = "Read-only AWS API surface for diagnostic Claude operations"
  policy      = file("${path.module}/deployer-policies/readonly.json")
  tags        = local.common_tags
}

resource "aws_iam_role_policy_attachment" "readonly_attach" {
  role       = aws_iam_role.appserver_readonly.name
  policy_arn = aws_iam_policy.operator_readonly.arn
}

resource "aws_iam_policy" "operator_cookie_ops" {
  name        = "AppserverOperatorCookieOps"
  description = "Cookie app-layer ops permissions (SSM SendCommand on tagged instance, parameter RW)"
  policy      = file("${path.module}/deployer-policies/cookie-ops.json")
  tags        = local.common_tags
}

resource "aws_iam_role_policy_attachment" "cookie_ops_attach" {
  role       = aws_iam_role.appserver_cookie_ops.name
  policy_arn = aws_iam_policy.operator_cookie_ops.arn
}

# Deploy role inherits the three existing deployer managed policies. Those
# policies are created/managed by `appserver.sh init` (not terraform), so
# they exist as managed-policy ARNs we can reference.
locals {
  deployer_account_policy_prefix = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy"
}

resource "aws_iam_role_policy_attachment" "deploy_attach_compute" {
  role       = aws_iam_role.appserver_deploy.name
  policy_arn = "${local.deployer_account_policy_prefix}/AppserverDeployerCompute"
}

resource "aws_iam_role_policy_attachment" "deploy_attach_iam_ssm" {
  role       = aws_iam_role.appserver_deploy.name
  policy_arn = "${local.deployer_account_policy_prefix}/AppserverDeployerIamSsm"
}

resource "aws_iam_role_policy_attachment" "deploy_attach_monitoring_storage" {
  role       = aws_iam_role.appserver_deploy.name
  policy_arn = "${local.deployer_account_policy_prefix}/AppserverDeployerMonitoringStorage"
}

# Note: AppserverDeployerAssumeRoles is NOT managed by terraform. It is
# created and attached to the appserver-deployer user by
# `scripts/appserver.sh init` (alongside the three existing deployer
# policies) — see ensure_deployer_access. The operator-role trust
# policies above grant the MFA condition; the deployer-user policy
# (managed in init) grants sts:AssumeRole permission to call them.
