# Input validation tests — exercise every validation rule in variables.tf.
#
# These run in plan mode, and each rejected run fails validation before any
# provider or data source is touched, so no AWS/Cloudflare credentials are
# required. Run with: terraform -chdir=terraform test
#
# New variables with validation rules should get a corresponding run block here.

variables {
  # Baseline — supplies the required inputs that tests don't override.
  domain                = "example.com"
  cloudflare_zone_id    = "0123456789abcdef0123456789abcdef"
  cloudflare_account_id = "fedcba9876543210fedcba9876543210"
  admin_email           = "ops@example.com"
}

run "region_rejects_invalid_format" {
  command = plan

  variables {
    region = "not-a-region"
  }

  expect_failures = [var.region]
}

run "domain_rejects_missing_tld" {
  command = plan

  variables {
    domain = "localhost"
  }

  expect_failures = [var.domain]
}

run "domain_rejects_empty" {
  command = plan

  variables {
    domain = ""
  }

  expect_failures = [var.domain]
}

run "cloudflare_zone_id_rejects_short_hex" {
  command = plan

  variables {
    cloudflare_zone_id = "deadbeef"
  }

  expect_failures = [var.cloudflare_zone_id]
}

run "cloudflare_zone_id_rejects_non_hex" {
  command = plan

  variables {
    cloudflare_zone_id = "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"
  }

  expect_failures = [var.cloudflare_zone_id]
}

run "cloudflare_account_id_rejects_short_hex" {
  command = plan

  variables {
    cloudflare_account_id = "cafe"
  }

  expect_failures = [var.cloudflare_account_id]
}

run "instance_type_rejects_missing_family" {
  command = plan

  variables {
    instance_type = "small"
  }

  expect_failures = [var.instance_type]
}

run "instance_type_rejects_uppercase" {
  command = plan

  variables {
    instance_type = "T4g.Small"
  }

  expect_failures = [var.instance_type]
}

run "app_subdomains_rejects_empty_list" {
  command = plan

  variables {
    app_subdomains = []
  }

  expect_failures = [var.app_subdomains]
}

run "app_subdomains_rejects_uppercase" {
  command = plan

  variables {
    app_subdomains = ["Cookie"]
  }

  expect_failures = [var.app_subdomains]
}

run "app_subdomains_rejects_underscore" {
  command = plan

  variables {
    app_subdomains = ["my_app"]
  }

  expect_failures = [var.app_subdomains]
}

run "admin_email_rejects_malformed" {
  command = plan

  variables {
    admin_email = "not-an-email"
  }

  expect_failures = [var.admin_email]
}

run "admin_email_rejects_empty" {
  command = plan

  variables {
    admin_email = ""
  }

  expect_failures = [var.admin_email]
}

run "home_ip_rejects_hostname" {
  command = plan

  variables {
    home_ip = "localhost"
  }

  expect_failures = [var.home_ip]
}

run "home_ip_rejects_cidr" {
  command = plan

  variables {
    home_ip = "1.2.3.4/32"
  }

  expect_failures = [var.home_ip]
}

run "monthly_budget_rejects_zero" {
  command = plan

  variables {
    monthly_budget = 0
  }

  expect_failures = [var.monthly_budget]
}

run "monthly_budget_rejects_negative" {
  command = plan

  variables {
    monthly_budget = -5
  }

  expect_failures = [var.monthly_budget]
}
