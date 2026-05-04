# Per-skill operator roles assumed by the operator/Claude via MFA-gated
# sts:AssumeRole. The deployer IAM user (created by `appserver.sh init`,
# not by terraform) holds only `AppserverDeployerAssumeRoles` after the
# phase-5 cutover; all real permissions live on these three roles.
#
# Spec: specs/003-iam-mfa-scoping/spec.md
# Plan: specs/003-iam-mfa-scoping/plan.md
#
# - readonly: pure AWS reads. No SSM SendCommand.
# - cookie-ops: instance shell + app-layer mutations.
# - deploy: terraform apply, full infra changes.
#
# Trust policies require MFA-present and MFA-age < 3600s, enforced at
# both the role level (this file) and the deployer-user level
# (assume-roles.json). Belt-and-braces. MaxSessionDuration = 3600 means
# a stolen STS triple is dead in at most 1 hour.

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
# Data sources for init-managed deployer policies. These three are created
# by `scripts/appserver.sh init` (not terraform), so we look them up.
#
# Using `arn` (not `name`) deliberately: `name` lookup calls
# iam:ListPolicies which rockport-admin does NOT have, while `arn`
# lookup calls iam:GetPolicy which is in AppserverAdmin scoped to
# arn:aws:iam::*:policy/Appserver*. Looking them up via `data` instead
# of hardcoding strings means `terraform plan` fails fast if init
# hasn't been run, instead of failing later at apply time.
# ---------------------------------------------------------------------------

locals {
  account_id           = data.aws_caller_identity.current.account_id
  appserver_policy_arn = "arn:aws:iam::${local.account_id}:policy"
}

data "aws_iam_policy" "deployer_compute" {
  arn = "${local.appserver_policy_arn}/AppserverDeployerCompute"
}

data "aws_iam_policy" "deployer_iam_ssm" {
  arn = "${local.appserver_policy_arn}/AppserverDeployerIamSsm"
}

data "aws_iam_policy" "deployer_monitoring_storage" {
  arn = "${local.appserver_policy_arn}/AppserverDeployerMonitoringStorage"
}

# ---------------------------------------------------------------------------
# Permissions boundaries — each role's ceiling. Even if extra policies were
# attached later, the role can never exceed the boundary's ALLOW set.
# ---------------------------------------------------------------------------
#
# The boundary policy file content goes through jsondecode + jsonencode so
# any malformed JSON fails at `terraform plan` time rather than during
# apply (AWS-side rejection is harder to debug).

resource "aws_iam_policy" "operator_readonly_boundary" {
  name        = "appserver-operator-readonly-boundary"
  description = "Permissions boundary for appserver-readonly-role — caps role at read-only AWS API surface"
  policy      = jsonencode(jsondecode(file("${path.module}/deployer-policies/readonly.json")))
  tags        = local.common_tags
}

resource "aws_iam_policy" "operator_cookie_ops_boundary" {
  name        = "appserver-operator-cookie-ops-boundary"
  description = "Permissions boundary for appserver-cookie-ops-role — caps role at cookie-app management surface"
  policy      = jsonencode(jsondecode(file("${path.module}/deployer-policies/cookie-ops.json")))
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
    Statement = [
      {
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
      },
      # Without this, a deploy-role STS holder (1h MFA-gated) could rewrite
      # the very policies that bound them via iam:CreatePolicyVersion +
      # SetDefaultPolicyVersion, persisting privilege escalation past the
      # MFA-age window. The 7 ARNs below cover: 4 init-managed deployer
      # policies + 3 operator-role boundaries. Mutation of these
      # requires the admin user (rockport-admin / AppserverAdmin), not
      # the deploy role. See spec security review Finding 2.
      {
        Sid    = "DenyOperatorPolicyMutation"
        Effect = "Deny"
        Action = [
          "iam:CreatePolicyVersion",
          "iam:DeletePolicyVersion",
          "iam:SetDefaultPolicyVersion",
          "iam:DeletePolicy"
        ]
        Resource = [
          "arn:aws:iam::*:policy/AppserverDeployerCompute",
          "arn:aws:iam::*:policy/AppserverDeployerIamSsm",
          "arn:aws:iam::*:policy/AppserverDeployerMonitoringStorage",
          "arn:aws:iam::*:policy/AppserverDeployerAssumeRoles",
          "arn:aws:iam::*:policy/appserver-operator-readonly-boundary",
          "arn:aws:iam::*:policy/appserver-operator-cookie-ops-boundary",
          "arn:aws:iam::*:policy/appserver-operator-deploy-boundary"
        ]
      }
    ]
  })
  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# Roles — trust policy + boundary. MaxSessionDuration = 3600 (FR-003).
# ---------------------------------------------------------------------------

resource "aws_iam_role" "appserver_readonly" {
  name                 = "appserver-readonly-role"
  description          = "Read-only AWS surface for diagnostic Claude operations (MFA-gated)"
  max_session_duration = 3600
  permissions_boundary = aws_iam_policy.operator_readonly_boundary.arn
  assume_role_policy   = local.operator_assume_role_policy
  tags                 = local.common_tags
}

resource "aws_iam_role" "appserver_cookie_ops" {
  name                 = "appserver-cookie-ops-role"
  description          = "Instance shell (SSM) + cookie-app management role (MFA-gated)"
  max_session_duration = 3600
  permissions_boundary = aws_iam_policy.operator_cookie_ops_boundary.arn
  assume_role_policy   = local.operator_assume_role_policy
  tags                 = local.common_tags
}

resource "aws_iam_role" "appserver_deploy" {
  name                 = "appserver-deploy-role"
  description          = "Full deploy role (terraform apply, infra changes) - MFA-gated"
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
  policy      = jsonencode(jsondecode(file("${path.module}/deployer-policies/readonly.json")))
  tags        = local.common_tags
}

resource "aws_iam_role_policy_attachment" "readonly_attach" {
  role       = aws_iam_role.appserver_readonly.name
  policy_arn = aws_iam_policy.operator_readonly.arn
}

resource "aws_iam_policy" "operator_cookie_ops" {
  name        = "AppserverOperatorCookieOps"
  description = "Cookie-ops permissions (SSM SendCommand on tagged instance, parameter RW)"
  policy      = jsonencode(jsondecode(file("${path.module}/deployer-policies/cookie-ops.json")))
  tags        = local.common_tags
}

resource "aws_iam_role_policy_attachment" "cookie_ops_attach" {
  role       = aws_iam_role.appserver_cookie_ops.name
  policy_arn = aws_iam_policy.operator_cookie_ops.arn
}

# Deploy role inherits the three init-managed deployer policies.
resource "aws_iam_role_policy_attachment" "deploy_attach_compute" {
  role       = aws_iam_role.appserver_deploy.name
  policy_arn = data.aws_iam_policy.deployer_compute.arn
}

resource "aws_iam_role_policy_attachment" "deploy_attach_iam_ssm" {
  role       = aws_iam_role.appserver_deploy.name
  policy_arn = data.aws_iam_policy.deployer_iam_ssm.arn
}

resource "aws_iam_role_policy_attachment" "deploy_attach_monitoring_storage" {
  role       = aws_iam_role.appserver_deploy.name
  policy_arn = data.aws_iam_policy.deployer_monitoring_storage.arn
}

# Note: AppserverDeployerAssumeRoles is NOT managed by terraform. It is
# created and attached to the appserver-deployer user by
# `scripts/appserver.sh init` (alongside the three existing deployer
# policies) — see ensure_deployer_access. The operator-role trust
# policies above grant the MFA condition; the deployer-user policy
# (managed in init) grants sts:AssumeRole permission to call them.
