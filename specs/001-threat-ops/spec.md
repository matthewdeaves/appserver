# Feature Specification: Threat Analysis & Response

**Feature Branch**: `001-threat-ops`  
**Created**: 2026-04-06  
**Status**: Draft  
**Input**: User description: "Add threat analysis and response capability to appserver — analyze server logs to identify attack patterns, produce actionable recommendations, and enact defensive actions on live infrastructure via Cloudflare WAF."

## Clarifications

### Session 2026-04-06

- No critical ambiguities detected. Coverage scan found all taxonomy categories Clear or Partial-deferred-to-planning. Proceeding to plan phase.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Run Threat Analysis On Demand (Priority: P1)

The server operator runs a single command to analyze recent traffic logs and receive a structured report of suspicious activity — scanning IPs, brute force attempts, path probing, and other attack patterns — with clear recommendations for defensive action.

**Why this priority**: Without analysis, the operator is blind to attacks hitting the server. This is the foundational capability that everything else builds on.

**Independent Test**: Can be fully tested by running the CLI command against live Traefik access logs and verifying the report identifies known suspicious patterns (e.g., repeated 404s to /wp-admin from a single IP).

**Acceptance Scenarios**:

1. **Given** the server has Traefik access logs enabled, **When** the operator runs the threat analysis command, **Then** a structured report is produced showing top scanning IPs, attack categories, and recommended actions.
2. **Given** no suspicious activity exists in the log window, **When** the operator runs the analysis, **Then** the report shows a clean status with no recommendations.
3. **Given** the operator specifies a time window (e.g., last 24 hours), **When** the analysis runs, **Then** only log entries within that window are analyzed.

---

### User Story 2 - Enact Blocking Recommendations (Priority: P2)

After reviewing a threat report, the operator uses a skill to enact specific recommendations — such as blocking an IP address via Cloudflare WAF — without manually navigating the Cloudflare dashboard or constructing API calls.

**Why this priority**: Analysis without action is incomplete. The operator needs to close the loop from detection to defense quickly.

**Independent Test**: Can be tested by taking a recommendation from a threat report and executing the block action, then verifying the IP is blocked in Cloudflare WAF rules.

**Acceptance Scenarios**:

1. **Given** a threat report with a "block IP" recommendation, **When** the operator enacts that recommendation, **Then** a Cloudflare WAF IP block rule is created for that IP.
2. **Given** a threat report with a "rate limit endpoint" recommendation, **When** the operator enacts it, **Then** a Cloudflare rate limiting rule is created for the specified endpoint pattern.
3. **Given** the operator attempts to enact a recommendation, **When** the Cloudflare API call fails (e.g., invalid token permissions), **Then** a clear error is shown with guidance on what permission is missing.

---

### User Story 3 - Review Historical Threat Reports (Priority: P3)

The operator can view past threat reports to track attack trends over time, see which IPs have been blocked, and understand the security posture of the server.

**Why this priority**: Trend awareness helps the operator understand whether attacks are increasing, whether blocks are effective, and whether new defensive measures are needed.

**Independent Test**: Can be tested by running multiple analyses over time and then viewing the report history to verify reports are persisted and accessible.

**Acceptance Scenarios**:

1. **Given** multiple threat analyses have been run previously, **When** the operator requests the report history, **Then** a list of past reports is shown with timestamps and summary statistics.
2. **Given** a specific past report, **When** the operator views it, **Then** the full report content is displayed including recommendations and any actions that were taken.

---

### User Story 4 - Cross-Reference with Cloudflare Edge Data (Priority: P3)

The operator can optionally enrich the threat analysis with Cloudflare edge data — WAF events, bot scores, and rate limit triggers — to see the full picture of what Cloudflare blocked vs what reached the server.

**Why this priority**: Provides defense-in-depth visibility. Lower priority because server-side logs alone are sufficient for core threat detection.

**Independent Test**: Can be tested by running analysis with CF API integration enabled and verifying the report includes edge-side data alongside server-side findings.

**Acceptance Scenarios**:

1. **Given** the Cloudflare API token has Analytics:Read permission, **When** the analysis runs, **Then** the report includes a section showing WAF blocks, bot detections, and rate limit triggers from Cloudflare's edge.
2. **Given** the API token lacks Analytics:Read permission, **When** the analysis runs, **Then** it gracefully skips edge data with a note suggesting the permission upgrade, and still produces the server-side report.

---

### Edge Cases

- What happens when access logs are empty or don't exist yet (Traefik access logging not enabled)?
- How does the system handle extremely large log files that exceed available memory on the t4g.small (2GB RAM)?
- What happens when the same IP appears in both "block" recommendations and legitimate traffic patterns?
- How does the system handle log rotation occurring mid-analysis?
- What happens when the Cloudflare API rate limit is hit during action enactment?

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST enable Traefik to produce JSON-format HTTP access logs with client IP (from Cloudflare headers), request method, path, status code, user agent, and timestamp.
- **FR-002**: System MUST rotate access logs to prevent disk exhaustion on the 20GB EBS volume.
- **FR-003**: System MUST provide a CLI subcommand that retrieves access logs from the EC2 instance via SSM and analyzes them for threat patterns.
- **FR-004**: System MUST detect the following attack categories: path scanning (known probe paths), authentication brute force, directory traversal attempts, suspicious user agents (known scanner signatures), and high request rates from single IPs.
- **FR-005**: System MUST produce a structured threat report with: summary statistics, top offending IPs with request counts and categories, specific recommended actions, and severity levels.
- **FR-006**: System MUST output recommendations in a machine-parseable format that a Claude Code skill can consume and act upon.
- **FR-007**: System MUST support enacting "block IP" recommendations by creating Cloudflare WAF IP access rules via the Cloudflare API.
- **FR-008**: System MUST support enacting "rate limit" recommendations by creating Cloudflare rate limiting rules via the Cloudflare API.
- **FR-009**: System MUST persist threat reports locally for historical review.
- **FR-010**: System MUST support a configurable analysis time window (default: last 24 hours).
- **FR-011**: All blocking actions MUST go through Cloudflare WAF (not server-side iptables) since there are no inbound ports — all traffic arrives via the Cloudflare Tunnel.
- **FR-012**: System MUST provide a dedicated Claude Code skill for threat analysis, report review, and action enactment.

### Key Entities

- **Threat Report**: A timestamped analysis result containing findings, statistics, and recommendations. Stored locally in a reports directory.
- **Finding**: A single detected threat pattern — an IP, attack category, evidence (sample log lines), severity, and count.
- **Recommendation**: An actionable defensive measure derived from findings — action type (block IP, rate limit, monitor), target (IP, endpoint), and rationale.
- **Action**: An enacted recommendation — the Cloudflare API call made, result, and timestamp.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Operator can generate a threat report from server logs in under 2 minutes end-to-end (command to report).
- **SC-002**: The system correctly identifies at least 90% of common scanning patterns (WordPress probes, .env access, phpMyAdmin, directory traversal) present in access logs.
- **SC-003**: Operator can enact a blocking recommendation (from report to active Cloudflare WAF rule) in under 30 seconds.
- **SC-004**: Access log disk usage stays under 500MB with rotation in place.
- **SC-005**: Threat reports are retained and accessible for at least 30 days.
- **SC-006**: The system gracefully handles missing Cloudflare API permissions without failing the entire analysis.

## Assumptions

- Traefik access logging can be enabled via config change and `config push` without downtime (Traefik reloads config).
- The Cloudflare API token used by appserver already has Zone WAF Edit permission (per CLAUDE.md), sufficient for creating IP block rules and rate limiting rules.
- The t4g.small instance (2GB RAM) has sufficient resources to run log analysis via shell tools (jq, awk, sort) without impacting running services, provided logs are processed in a streaming fashion rather than loaded entirely into memory.
- The operator will review recommendations before enacting them — the system defaults to report-only mode with explicit opt-in for action enactment.
- Access log volume for this low-traffic personal hosting setup is manageable (estimated low MB/day), making on-instance analysis feasible without a dedicated log aggregation service.
- Blocking actions via Cloudflare WAF are the appropriate defensive mechanism given the zero-inbound-port architecture.
