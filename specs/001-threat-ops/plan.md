# Implementation Plan: Threat Analysis & Response

**Branch**: `001-threat-ops` | **Date**: 2026-04-06 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `/specs/001-threat-ops/spec.md`

## Summary

Add threat detection and response to appserver by enabling Traefik access logs, adding a `threats` subcommand to the CLI that analyzes logs for attack patterns, producing machine-parseable threat reports with actionable recommendations, and creating a `threat-ops` Claude Code skill that can review reports and enact defensive actions (IP blocks, rate limits) via Cloudflare WAF API.

## Technical Context

**Language/Version**: Bash (POSIX-compatible, shellcheck-passing)
**Primary Dependencies**: jq, awk, sort, curl (all available on Amazon Linux 2023); Cloudflare API v4; AWS SSM
**Storage**: Local filesystem (threat reports in `reports/threats/`), Traefik access logs on instance at `/var/log/traefik/`
**Testing**: Manual validation against live traffic + shellcheck for scripts
**Target Platform**: Amazon Linux 2023 on EC2 t4g.small (ARM/aarch64), 2GB RAM, 20GB gp3 EBS
**Project Type**: CLI tool + Claude Code skill (infrastructure operations)
**Performance Goals**: End-to-end analysis in under 2 minutes; streaming log processing to stay under 256MB memory
**Constraints**: Must process logs via SSM (no SSH); all blocking via Cloudflare WAF (no iptables); disk budget ~500MB for access logs
**Scale/Scope**: Single server, low-traffic personal hosting (~100s of requests/day typical, possibly 10K+ during scans)

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

No project constitution has been defined. Proceeding with standard conventions from the existing codebase.

## Project Structure

### Documentation (this feature)

```text
specs/001-threat-ops/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/           # Phase 1 output
└── tasks.md             # Phase 2 output (from /speckit-tasks)
```

### Source Code (repository root)

```text
scripts/appserver.sh                          # Add `threats` subcommand family
config/traefik/traefik.yml                    # Add accessLog configuration
config/traefik/docker-compose.yml             # Add log volume mount
scripts/bootstrap.sh                          # Add logrotate for access logs
.claude/skills/threat-ops/SKILL.md            # New Claude Code skill
.claude/skills/threat-ops/references/
├── threat-patterns.md                        # Known attack signatures & scanner paths
├── cloudflare-actions.md                     # CF API recipes for blocking/rate-limiting
└── report-format.md                          # Threat report JSON schema & conventions
reports/threats/                              # Gitignored — local threat reports
```

**Structure Decision**: Extends existing CLI + skill pattern. No new top-level directories except `reports/threats/` (gitignored, like `pentest/reports/`). The threat analysis logic lives in `appserver.sh` as shell functions following the existing subcommand convention. The skill orchestrates analysis and enacts recommendations.

## Complexity Tracking

No constitution violations to justify.

## Design Decisions

### D1: Analysis Location — On-Instance vs Local

**Decision**: Analyze on-instance via SSM, return summary JSON to local machine.

**Rationale**: Access logs live on the instance. Downloading multi-MB log files over SSM (which has output size limits) is impractical. Running jq/awk on the instance is fast and avoids transfer. The SSM command returns a structured JSON report that the skill can parse locally.

**Alternative rejected**: Download logs to local → too slow, SSM output size limits (~24KB for inline output, would need S3 intermediate).

### D2: Report Storage — Local Only

**Decision**: Store threat reports locally in `reports/threats/<timestamp>/` (gitignored).

**Rationale**: Follows the pentest report pattern. Reports contain IP addresses and security findings that shouldn't be committed. The skill reads local reports for review and action.

### D3: Blocking Mechanism — Cloudflare API Direct (Not Terraform)

**Decision**: IP blocks are applied via Cloudflare API calls (curl), not Terraform resources.

**Rationale**: IP blocks are operational, ephemeral responses to live threats — they shouldn't be in IaC. Terraform is for durable infrastructure rules (like the auth rate limit). The `threats` command uses `curl` against the Cloudflare API to create/list/delete IP access rules. The skill can also call the API directly.

**Alternative rejected**: Terraform cloudflare_ruleset → requires plan/apply cycle, state management, inappropriate for dynamic IP blocking.

### D4: Threat Detection — Pattern Matching (Not ML)

**Decision**: Use static pattern matching (known scanner paths, user agent signatures, 4xx rate thresholds).

**Rationale**: Simple, auditable, zero dependencies. A curated list of known probe paths (/wp-admin, /.env, /phpmyadmin, etc.) and scanner user agents (sqlmap, nikto, python-requests, etc.) catches the vast majority of unsophisticated attacks hitting personal infrastructure. False positive risk is low because legitimate traffic patterns are well-known for a single-app server.

### D5: Skill Separation — Dedicated threat-ops Skill

**Decision**: Create a new `threat-ops` skill separate from `appserver-ops`.

**Rationale**: Threat analysis and response is a distinct operational domain from infrastructure diagnosis. Different workflow (analyze → review → act vs. triage → diagnose → fix), different tools (CF WAF API vs. SSM/Terraform), different output (threat report vs. ops report). Keeps both skills focused.
