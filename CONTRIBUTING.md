# Contributing

This is a personal infrastructure repo. It runs the author's live setup, so the bar for accepting changes is "does this make my own deployment better."

## What's likely to land
- Bug fixes that affect the published code paths
- Security improvements (additional hooks, blast-radius reductions, IaC tightening)
- Cleaner abstractions where the existing code is genuinely confused

## What's unlikely to land
- Features the author doesn't use
- Renames / restyling for taste
- New abstractions that exist only to "support more deployments"

If you want to host your own copy, the friendlier path is to fork. The repo is MIT-licensed (see `LICENSE`) and designed to be forkable — `terraform/terraform.tfvars.example` documents what to fill in, and `./scripts/appserver.sh setup local` walks through the per-machine setup.

## Issues / disclosures
- General bugs / questions: GitHub Issues
- Security disclosures: see `SECURITY.md` for the disclosure path

## Development conventions
- Terraform: `terraform fmt` + `terraform validate` must pass; `tfsec` runs in CI
- Shell: `shellcheck scripts/*.sh` must pass
- Commits: keep them small, write a message that explains the *why*

CI runs all three on every push. Anything that doesn't pass CI doesn't land.
