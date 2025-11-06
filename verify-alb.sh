#!/usr/bin/env bash
# Verifies: ALB is internet-facing, listeners (80/443), targets healthy, /health returns 200.
set -euo pipefail
REGION=${REGION:-us-east-1}
PREFIX=${PREFIX:-crudapp}

pass() { echo -e "✅  $*"; }
fail() { echo -e "❌  $*"; exit 1; }
warn() { echo -e "⚠️  $*"; }

# Find the ALB by name prefix
LB_ARN=$(aws elbv2 describe-load-balancers --region "$REGION" \
  --query "LoadBalancers[?contains(LoadBalancerName, \`$PREFIX\`)].LoadBalancerArn | [0]" \
  --output text)

[[ "$LB_ARN" == "None" || -z "$LB_ARN" ]] && fail "No ALB found matching '$PREFIX'"

read -r SCHEME DNS <<<"$(
  aws elbv2 describe-load-balancers --region "$REGION" --load-balancer-arns "$LB_ARN" \
    --query "LoadBalancers[0].[Scheme,DNSName]" --output text
)"
[[ "$SCHEME" == "internet-facing" ]] && pass "ALB is internet-facing: $DNS" || fail "ALB is not internet-facing"

# Listeners
read -r -a LST <<<"$(aws elbv2 describe-listeners --region "$REGION" --load-balancer-arn "$LB_ARN" \
  --query "Listeners[].Port" --output text || true)"
[[ " ${LST[*]} " == *" 80 "* ]] && pass "Listener 80 present" || fail "Listener 80 missing"
if [[ " ${LST[*]} " == *" 443 "* ]]; then
  pass "Listener 443 present (TLS)"
  PROTO=https
else
  warn "No 443 listener (HTTP only)"
  PROTO=http
fi

# Target group + health
TG_ARN=$(aws elbv2 describe-target-groups --region "$REGION" --load-balancer-arn "$LB_ARN" \
  --query "TargetGroups[0].TargetGroupArn" --output text)
[[ "$TG_ARN" == "None" || -z "$TG_ARN" ]] && fail "No target group attached to the ALB"

STATES=$(aws elbv2 describe-target-health --region "$REGION" --target-group-arn "$TG_ARN" \
  --query "TargetHealthDescriptions[].TargetHealth.State" --output text | tr '\n' ' ')
if [[ -z "$STATES" ]]; then
  warn "Target group has no registered targets"
else
  echo "Targets: $STATES"
  if echo "$STATES" | grep -qv healthy; then
    fail "One or more targets are not healthy"
  else
    pass "All targets healthy"
  fi
fi

# Try /health on the ALB
echo -n "ALB /health → "
CODE=$(curl -s -o /dev/null -w "%{http_code}" "$PROTO://$DNS/health" || true)
echo "$CODE"
[[ "$CODE" == "200" ]] && pass "Health endpoint returned 200" || warn "Health endpoint returned $CODE (check app routing/paths)"
