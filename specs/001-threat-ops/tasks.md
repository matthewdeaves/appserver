# Tasks: Threat Analysis & Response

**Input**: Design documents from `/specs/001-threat-ops/`
**Prerequisites**: plan.md (required), spec.md (required), research.md, data-model.md, contracts/

**Tests**: Not requested — no test tasks included.

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

## Phase 1: Setup

**Purpose**: Enable access logging and create project structure for threat analysis.

- [x] T001 [P] Add accessLog configuration (JSON format, CF-Connecting-IP and User-Agent headers) to config/traefik/traefik.yml
- [x] T002 [P] Add /var/log/traefik volume mount to config/traefik/docker-compose.yml
- [x] T003 [P] Add logrotate config for /var/log/traefik/access.log (daily, 14 rotations, compress, copytruncate) in scripts/bootstrap.sh
- [x] T004 [P] Add reports/threats/ to .gitignore
- [x] T005 [P] Create .claude/skills/threat-ops/ directory structure with empty SKILL.md and references/ subdirectory

**Checkpoint**: Traefik access logging infrastructure ready. Run `config push` + `app deploy` to activate on instance.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core CLI functions that all user stories depend on — Cloudflare API helpers and the `threats` subcommand skeleton.

**CRITICAL**: No user story work can begin until this phase is complete.

- [x] T006 Add `cf_api()` helper function to scripts/appserver.sh that reads CLOUDFLARE_API_TOKEN from env and cloudflare_zone_id from terraform/terraform.tfvars, makes authenticated Cloudflare API v4 requests via curl, and returns JSON response
- [x] T007 Add `cmd_threats()` dispatcher function to scripts/appserver.sh with subcommand routing for: (no args → analyze), report, list, block, unblock, blocked — following the existing `cmd_app()` case-statement pattern
- [x] T008 Register `threats` in the main case statement of scripts/appserver.sh (alongside existing commands like status, logs, app, config) and add threats to the usage/help text

**Checkpoint**: `appserver.sh threats` responds with usage info. CF API helper is callable.

---

## Phase 3: User Story 1 — Run Threat Analysis On Demand (Priority: P1) MVP

**Goal**: Operator runs `appserver.sh threats` and gets a structured threat report from access logs.

**Independent Test**: Run `appserver.sh threats --since 1h` against a server with access logs enabled. Verify report.json and SUMMARY.md are created in reports/threats/<timestamp>/ with findings for any suspicious IPs.

### Implementation for User Story 1

- [x] T009 [US1] Add `cmd_threats_analyze()` function to scripts/appserver.sh that: accepts `--since <duration>` flag (default 24h), constructs an on-instance analysis script, sends it via `ssm_run`, parses the JSON output, writes report.json and SUMMARY.md to reports/threats/<timestamp>/, and prints the summary to stdout
- [x] T010 [US1] Write the on-instance analysis logic (embedded in the SSM command string) that: reads /var/log/traefik/access.log with jq, filters by time window, groups by client IP (from CF-Connecting-IP header or ClientHost), counts requests per IP, identifies status code distributions, extracts paths and user agents — outputs a JSON summary of per-IP statistics
- [x] T011 [US1] Add threat pattern detection to the analysis: match request paths against known scanner paths (wp-admin, .env, phpmyadmin, .git, xmlrpc, etc.), match user agents against known scanner signatures (sqlmap, nikto, zgrab, nuclei, dirbuster, etc.), detect directory traversal patterns (../ in paths), flag IPs with >100 requests or >90% error responses
- [x] T012 [US1] Add finding generation: for each IP matching threat patterns, create a Finding object (id, category, severity, ip, count, sample_paths, sample_ua, first_seen, last_seen, status_codes) per the data model schema, assign severity based on volume and category
- [x] T013 [US1] Add recommendation generation: for each high-severity finding, generate a Recommendation (id, action, target, rationale, confidence, finding_ids) — block_ip for clear scanners with high confidence, monitor for ambiguous patterns with low confidence
- [x] T014 [US1] Add report output: write report.json (full ThreatReport JSON per contracts/report-json-schema.md), generate SUMMARY.md (human-readable markdown with findings table, recommendations table), create reports/threats/<timestamp>/ directory, print summary to stdout with finding and recommendation counts

**Checkpoint**: `appserver.sh threats` produces a complete threat report. This is the MVP — operator can see what's attacking the server.

---

## Phase 4: User Story 2 — Enact Blocking Recommendations (Priority: P2)

**Goal**: Operator can block IPs and manage blocks via CLI, closing the detection-to-defense loop.

**Independent Test**: Run `appserver.sh threats block 1.2.3.4 --note "test"`, verify IP appears in Cloudflare WAF rules via `appserver.sh threats blocked`, then unblock with `appserver.sh threats unblock 1.2.3.4`.

### Implementation for User Story 2

- [x] T015 [P] [US2] Add `cmd_threats_block()` function to scripts/appserver.sh that: validates IP format (IPv4/IPv6), calls cf_api POST to /zones/{zone_id}/firewall/access_rules/rules with mode=block, accepts --note flag, prints confirmation with CF rule ID, exits 2 if already blocked
- [x] T016 [P] [US2] Add `cmd_threats_unblock()` function to scripts/appserver.sh that: takes an IP argument, calls cf_api GET to list rules filtering by IP, extracts the rule ID, calls cf_api DELETE on that rule, prints confirmation
- [x] T017 [P] [US2] Add `cmd_threats_blocked()` function to scripts/appserver.sh that: calls cf_api GET to list all block-mode IP access rules, formats output as a table (IP, note, created date, rule ID) using printf/column
- [x] T018 [US2] Add actions.json tracking: when a block/unblock action succeeds, append an Action record to reports/threats/actions.json (or the latest report's actions.json if a report exists) per the data model schema

**Checkpoint**: Full block/unblock/list lifecycle works via CLI. Operator can go from threat report → blocked IP in one command.

---

## Phase 5: User Story 3 — Review Historical Reports (Priority: P3)

**Goal**: Operator can browse past threat reports and track trends.

**Independent Test**: Run `appserver.sh threats list` after multiple analyses and verify all reports appear. Run `appserver.sh threats report <timestamp>` and verify the full report displays.

### Implementation for User Story 3

- [x] T019 [P] [US3] Add `cmd_threats_list()` function to scripts/appserver.sh that: scans reports/threats/ for timestamp directories, reads each report.json for status/finding count/recommendation count, outputs a formatted table sorted by date
- [x] T020 [P] [US3] Add `cmd_threats_report()` function to scripts/appserver.sh that: accepts optional timestamp argument (default: latest), reads SUMMARY.md from the report directory, prints it to stdout, also shows any actions taken from actions.json

**Checkpoint**: Operator can review all past reports and see full details of any specific report.

---

## Phase 6: User Story 4 — Cloudflare Edge Data (Priority: P3)

**Goal**: Optionally enrich reports with Cloudflare edge-side data (WAF blocks, bot scores).

**Independent Test**: Run `appserver.sh threats` with a CF token that has Analytics:Read. Verify the report includes a cf_edge section. Run without the permission and verify it's gracefully skipped.

### Implementation for User Story 4

- [x] T021 [US4] Add CF edge data retrieval to cmd_threats_analyze(): after server-side analysis, attempt a GraphQL query to Cloudflare Analytics API for WAF events and rate limit triggers in the same time window. If 403 (permission denied), set cf_edge to null and add a note in the report. If successful, populate the CFEdgeData fields (waf_blocks, rate_limit_triggers, top_blocked_ips).
- [x] T022 [US4] Update SUMMARY.md generation to include a "Cloudflare Edge" section when cf_edge data is available, showing WAF blocks, rate limit triggers, and top blocked IPs with a note about what was stopped before reaching the server

**Checkpoint**: Reports show the full picture — server-side findings plus edge-side blocks.

---

## Phase 7: Skill & Polish

**Purpose**: Create the Claude Code skill and finalize documentation.

- [x] T023 [P] Create .claude/skills/threat-ops/SKILL.md with: metadata (name, description, argument-hint, allowed-tools), purpose section, workflow for analyze/review/block/status modes, report format template, conventions, gotchas (SSM async, CF API rate limits, access log availability), rules — following the appserver-ops skill pattern
- [x] T024 [P] Create .claude/skills/threat-ops/references/threat-patterns.md documenting: known scanner paths (with categories), scanner user agent signatures, severity assignment rules, detection thresholds — this is the reference the skill consults when reviewing findings
- [x] T025 [P] Create .claude/skills/threat-ops/references/cloudflare-actions.md documenting: CF API endpoints for IP access rules (create, list, delete), rate limiting rule creation, required permissions, example curl commands, error handling patterns
- [x] T026 [P] Create .claude/skills/threat-ops/references/report-format.md documenting: report.json schema, SUMMARY.md structure, actions.json schema, report directory layout, how to interpret findings and recommendations
- [x] T027 Update CLAUDE.md with threat-ops section documenting: the threats subcommand, report directory structure, CF API token requirements, access log configuration, the threat-ops skill
- [x] T028 Run shellcheck on scripts/appserver.sh and fix any issues introduced by threat-ops code
- [x] T029 Run quickstart.md validation: verify all commands documented in quickstart.md work end-to-end

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — can start immediately. All tasks are parallel.
- **Foundational (Phase 2)**: Depends on Phase 1 for appserver.sh structure. BLOCKS all user stories.
- **US1 (Phase 3)**: Depends on Phase 2. Core MVP — must complete first.
- **US2 (Phase 4)**: Depends on Phase 2. Can run in parallel with US1 (different functions, no shared state) but logically follows US1.
- **US3 (Phase 5)**: Depends on US1 (needs reports to exist to list/review them).
- **US4 (Phase 6)**: Depends on US1 (extends the analyze function).
- **Polish (Phase 7)**: Depends on all user stories being complete.

### User Story Dependencies

- **US1 (P1)**: Depends on Foundational only — independently testable
- **US2 (P2)**: Depends on Foundational only — independently testable (can block IPs without running analysis)
- **US3 (P3)**: Depends on US1 (needs report files to exist)
- **US4 (P3)**: Depends on US1 (extends the analysis function)

### Parallel Opportunities

**Phase 1**: All 5 tasks (T001–T005) can run in parallel — different files.

**Phase 2**: T006, T007, T008 are sequential (T007 depends on T006 helper, T008 registers T007's dispatcher).

**Phase 3 (US1)**: T009–T014 are sequential — each builds on the previous (analysis → detection → findings → recommendations → output).

**Phase 4 (US2)**: T015, T016, T017 can run in parallel (different functions, same file but independent sections). T018 depends on T015/T016.

**Phase 5 (US3)**: T019, T020 can run in parallel.

**Phase 7**: T023, T024, T025, T026 can all run in parallel (different files). T027, T028, T029 are sequential finalization.

---

## Parallel Example: Phase 1 Setup

```
Task: "Add accessLog to config/traefik/traefik.yml"
Task: "Add volume mount to config/traefik/docker-compose.yml"
Task: "Add logrotate to scripts/bootstrap.sh"
Task: "Add reports/threats/ to .gitignore"
Task: "Create .claude/skills/threat-ops/ structure"
```

## Parallel Example: Phase 4 (US2)

```
Task: "Add cmd_threats_block() to scripts/appserver.sh"
Task: "Add cmd_threats_unblock() to scripts/appserver.sh"
Task: "Add cmd_threats_blocked() to scripts/appserver.sh"
```

## Parallel Example: Phase 7 Skill Files

```
Task: "Create .claude/skills/threat-ops/SKILL.md"
Task: "Create .claude/skills/threat-ops/references/threat-patterns.md"
Task: "Create .claude/skills/threat-ops/references/cloudflare-actions.md"
Task: "Create .claude/skills/threat-ops/references/report-format.md"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup (enable access logs)
2. Complete Phase 2: Foundational (CF API helper, threats command skeleton)
3. Complete Phase 3: User Story 1 (threat analysis + reports)
4. **STOP and VALIDATE**: Run `appserver.sh threats` against live server, verify report quality
5. Deploy if ready — operator can now see attacks

### Incremental Delivery

1. Setup + Foundational → Access logs flowing, CLI skeleton ready
2. Add US1 → Threat analysis works → Deploy (MVP!)
3. Add US2 → Block/unblock IPs → Deploy (defense capability)
4. Add US3 → Historical reports → Deploy (trend awareness)
5. Add US4 → CF edge data → Deploy (full visibility)
6. Polish → Skill + docs → Complete feature

---

## Notes

- [P] tasks = different files, no dependencies
- [Story] label maps task to specific user story for traceability
- All shell code must pass shellcheck
- CF API calls use the existing CLOUDFLARE_API_TOKEN env var and zone_id from terraform.tfvars
- On-instance analysis uses jq/awk — no additional tools to install
- Reports directory follows pentest convention: reports/threats/<timestamp>/
- The threat-ops skill is separate from appserver-ops (different operational domain)
