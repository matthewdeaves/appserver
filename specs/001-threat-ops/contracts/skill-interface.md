# Contract: threat-ops Skill Interface

## Skill Metadata

```yaml
name: threat-ops
description: "Analyze server threats, review reports, and enact defensive actions. Use when: threat analysis, suspicious traffic, block IPs, review attacks, security posture."
user-invocable: true
argument-hint: "[analyze | review | block <ip> | status]"
allowed-tools: "Read, Grep, Glob, Bash, Agent"
effort: high
```

## Invocation Patterns

### Analyze (default)

Trigger: `/threat-ops`, `/threat-ops analyze`, "run threat analysis", "check for attacks"

Workflow:
1. Run `appserver.sh threats` via subagent
2. Read the generated report.json
3. Present SUMMARY.md to the user
4. For each high-confidence recommendation, offer to enact it
5. Record any actions taken

### Review

Trigger: `/threat-ops review`, "show threat report", "what attacks are happening"

Workflow:
1. Run `appserver.sh threats list` to show available reports
2. Read the latest (or specified) report
3. Present findings with context and severity
4. Highlight any unenacted high-confidence recommendations

### Block

Trigger: `/threat-ops block 1.2.3.4`, "block this IP"

Workflow:
1. Validate IP format
2. Check if already blocked via `appserver.sh threats blocked`
3. Run `appserver.sh threats block <ip> --note "<reason>"`
4. Verify success
5. Update actions.json in the relevant report

### Status

Trigger: `/threat-ops status`, "what's blocked", "show blocked IPs"

Workflow:
1. Run `appserver.sh threats blocked`
2. Present blocked IP list with notes and dates
3. Show latest report summary statistics

## Output Format

The skill produces a structured report following this template:

```markdown
## Threat Ops Report

**Action**: ANALYZED | BLOCKED | REVIEWED
**Timestamp**: [when]
**Status**: CLEAN | THREATS_DETECTED | ACTION_TAKEN | ERROR

### Summary
[Key findings or action result]

### Findings (if analyze/review)
[Top findings by severity]

### Actions Taken (if block)
- [What was done, CF rule ID, verification]

### Recommendations
- [Remaining unenacted recommendations]

### For the user
- [Next steps or guidance]
```
