#!/usr/bin/env bash
# Check AWS cost anomaly: compare yesterday vs the day before.
# Uses Cost Explorer API (always us-east-1 regardless of resource region).
# Prints JSON to stdout.
#
# Usage: ./check-cost.sh
#
# Output JSON fields:
#   available   bool   — false if API unavailable or insufficient data
#   yesterday   float  — yesterday's blended cost
#   day_before  float  — day-before-yesterday's blended cost
#   currency    string — e.g. "USD"
#   anomaly     string — "normal" | "elevated" (>$2/day) | "spike" (>1.5x prev)

set -euo pipefail

TODAY=$(date +%Y-%m-%d)
YESTERDAY=$(date -d '1 day ago' +%Y-%m-%d 2>/dev/null \
         || date -v-1d +%Y-%m-%d 2>/dev/null || echo "")
TWO_DAYS_AGO=$(date -d '2 days ago' +%Y-%m-%d 2>/dev/null \
            || date -v-2d +%Y-%m-%d 2>/dev/null || echo "")

[[ -n "$YESTERDAY" && -n "$TWO_DAYS_AGO" ]] \
  || { echo '{"available":false,"reason":"date calculation failed"}'; exit 0; }

RESULT=$(aws ce get-cost-and-usage \
  --profile appserver \
  --time-period "Start=${TWO_DAYS_AGO},End=${TODAY}" \
  --granularity DAILY \
  --metrics BlendedCost \
  --region us-east-1 \
  --output json 2>/dev/null) \
  || { echo '{"available":false,"reason":"API call failed"}'; exit 0; }

echo "$RESULT" | jq '
  .ResultsByTime as $r |
  if ($r | length) >= 2 then
    (($r[-2].Total.BlendedCost.Amount | tonumber) * 100 | round / 100 | fabs) as $prev |
    (($r[-1].Total.BlendedCost.Amount | tonumber) * 100 | round / 100 | fabs) as $curr |
    {
      available: true,
      yesterday: $curr,
      day_before: $prev,
      currency: $r[-1].Total.BlendedCost.Unit,
      anomaly: (
        if $prev > 0.01 and $curr > ($prev * 1.5) then "spike"
        elif $curr > 2.0 then "elevated"
        else "normal" end
      )
    }
  else {"available":false,"reason":"insufficient data"}
  end
' 2>/dev/null || echo '{"available":false,"reason":"parse failed"}'
