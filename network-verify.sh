#!/usr/bin/env bash
# Validate VPC, subnets, routing, NAT, ALB, and ECS placement for a 3-tier app.
# Public ALB -> Private App (via NAT) -> Private DB (no internet route)

set -uo pipefail   # don't use -e so we can report all failures
REGION=${REGION:-us-east-1}
PREFIX=${PREFIX:-crudapp}

# Tag/Name patterns (adjust if your tags differ)
PUB_PATTERN=${PUB_PATTERN:-"*subnet-public*"}
APP_PATTERN=${APP_PATTERN:-"*app-subnet-private*"}
DB_PATTERN=${DB_PATTERN:-"*db-subnet-private*"}

pass(){ echo -e "✅  $*"; }
warn(){ echo -e "⚠️   $*"; }
fail(){ echo -e "❌  $*"; FAILED=1; }

FAILED=0

echo "=== VPC & IGW ==="
VPC_ID=$(aws ec2 describe-vpcs --region "$REGION" \
  --filters "Name=tag:Name,Values=*${PREFIX}*" \
  --query "Vpcs[0].VpcId" --output text)
if [[ "$VPC_ID" == "None" || -z "$VPC_ID" ]]; then
  fail "No VPC found for prefix '$PREFIX'."; exit 1
else
  pass "VPC: $VPC_ID"
fi

IGW=$(aws ec2 describe-internet-gateways --region "$REGION" \
  --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
  --query "InternetGateways[0].InternetGatewayId" --output text)
[[ "$IGW" == "None" || -z "$IGW" ]] && fail "No Internet Gateway attached." || pass "IGW: $IGW"

to_array(){ tr '\t' '\n' | awk 'NF'; }

echo -e "\n=== Subnet discovery (by tag:Name) ==="
mapfile -t PUB_ARR < <(aws ec2 describe-subnets --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=$PUB_PATTERN" \
  --query "Subnets[].SubnetId" --output text | to_array)
mapfile -t APP_ARR < <(aws ec2 describe-subnets --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=$APP_PATTERN" \
  --query "Subnets[].SubnetId" --output text | to_array)
mapfile -t DB_ARR < <(aws ec2 describe-subnets --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=$DB_PATTERN" \
  --query "Subnets[].SubnetId" --output text | to_array)

[[ ${#PUB_ARR[@]} -eq 0 ]] && fail "No PUBLIC subnets matched $PUB_PATTERN" || pass "Public: ${PUB_ARR[*]}"
[[ ${#APP_ARR[@]} -eq 0 ]] && fail "No APP subnets matched $APP_PATTERN"       || pass "App:    ${APP_ARR[*]}"
[[ ${#DB_ARR[@]}  -eq 0 ]] && fail "No DB subnets matched $DB_PATTERN"          || pass "DB:     ${DB_ARR[*]}"

# Build O(1) membership sets
declare -A PUB_SET=() APP_SET=() DB_SET=()
for id in "${PUB_ARR[@]}"; do PUB_SET["$id"]=1; done
for id in "${APP_ARR[@]}"; do APP_SET["$id"]=1; done
for id in "${DB_ARR[@]}";  do DB_SET["$id"]=1;  done

route_default_kind () {
  local s="$1"
  local rt
  rt=$(aws ec2 describe-route-tables --region "$REGION" \
    --filters "Name=association.subnet-id,Values=$s" \
    --query "RouteTables[0].RouteTableId" --output text)
  if [[ "$rt" == "None" || -z "$rt" ]]; then echo "OTHER none"; return; fi

  local g nat eoi eni
  g=$(aws ec2 describe-route-tables --region "$REGION" --route-table-ids "$rt" \
    --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'].GatewayId|[0]" --output text)
  nat=$(aws ec2 describe-route-tables --region "$REGION" --route-table-ids "$rt" \
    --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'].NatGatewayId|[0]" --output text)
  eoi=$(aws ec2 describe-route-tables --region "$REGION" --route-table-ids "$rt" \
    --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'].EgressOnlyInternetGatewayId|[0]" --output text)
  eni=$(aws ec2 describe-route-tables --region "$REGION" --route-table-ids "$rt" \
    --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'].NetworkInterfaceId|[0]" --output text)

  if [[ "$g" == igw-* ]]; then
    echo "IGW $g"
  elif [[ "$nat" == nat-* ]]; then
    echo "NAT $nat"
  elif [[ -z "$g$nat$eoi$eni" || "$g$nat$eoi$eni" == "NoneNoneNoneNone" ]]; then
    echo "NONE none"
  else
    echo "OTHER $g$nat$eoi$eni"
  fi
}

echo -e "\n=== Public subnets must default → IGW ==="
for s in "${PUB_ARR[@]}"; do
  read -r kind id <<<"$(route_default_kind "$s")"
  [[ "$kind" == "IGW" ]] && pass "Public $s → $id" || fail "Public $s default route is not IGW (got $kind $id)"
done

echo -e "\n=== App subnets must default → NAT (prefer same-AZ NAT) ==="
for s in "${APP_ARR[@]}"; do
  read -r kind id <<<"$(route_default_kind "$s")"
  if [[ "$kind" != "NAT" ]]; then
    fail "App $s default route is not NAT (got $kind $id)"
    continue
  fi
  SUB_AZ=$(aws ec2 describe-subnets --subnet-ids "$s" --region "$REGION" \
    --query "Subnets[0].AvailabilityZone" --output text)
  NAT_SUBNET=$(aws ec2 describe-nat-gateways --region "$REGION" --nat-gateway-ids "$id" \
    --query "NatGateways[0].SubnetId" --output text)
  NAT_AZ=$(aws ec2 describe-subnets --subnet-ids "$NAT_SUBNET" --region "$REGION" \
    --query "Subnets[0].AvailabilityZone" --output text)
  [[ "$SUB_AZ" == "$NAT_AZ" ]] && pass "App $s → $id (AZ OK: $SUB_AZ)" || warn "App $s → $id but NAT in $NAT_AZ (subnet AZ=$SUB_AZ)"
done

echo -e "\n=== DB subnets must have NO 0.0.0.0/0 ==="
for s in "${DB_ARR[@]}"; do
  read -r kind id <<<"$(route_default_kind "$s")"
  [[ "$kind" == "NONE" ]] && pass "DB $s has no internet route" || fail "DB $s has default route ($kind $id)"
done

echo -e "\n=== NAT Gateways present ==="
NATS=$(aws ec2 describe-nat-gateways --region "$REGION" --filter "Name=vpc-id,Values=$VPC_ID" \
  --query "NatGateways[?State=='available'].[NatGatewayId,SubnetId]" --output text)
[[ -z "$NATS" ]] && fail "No available NATs." || pass "NATs: $NATS"

echo -e "\n=== ALB must be internet-facing in PUBLIC subnets ==="
LB_ARN=$(aws elbv2 describe-load-balancers --region "$REGION" \
  --query "LoadBalancers[?VpcId=='$VPC_ID' && Scheme=='internet-facing']|[0].LoadBalancerArn" --output text)
if [[ "$LB_ARN" == "None" || -z "$LB_ARN" ]]; then
  fail "No internet-facing ALB in VPC."
else
  pass "ALB: $LB_ARN"
  mapfile -t ALB_SUBS < <(aws elbv2 describe-load-balancers --region "$REGION" --load-balancer-arns "$LB_ARN" \
    --query "LoadBalancers[0].AvailabilityZones[].SubnetId" --output text | to_array)
  for s in "${ALB_SUBS[@]}"; do
    if [[ -n "${PUB_SET[$s]:-}" ]]; then pass "ALB subnet $s is PUBLIC"; else fail "ALB subnet $s not in PUBLIC set"; fi
  done
  LST=$(aws elbv2 describe-listeners --region "$REGION" --load-balancer-arn "$LB_ARN" \
    --query "Listeners[].Port" --output text)
  [[ " $LST " == *" 80 "* ]] && pass "ALB has port 80" || fail "ALB missing 80"
  [[ " $LST " == *" 443 "* ]] && pass "ALB has port 443" || warn "ALB has no 443 (HTTP only)"
  TG_ARN=$(aws elbv2 describe-target-groups --region "$REGION" --load-balancer-arn "$LB_ARN" \
    --query "TargetGroups[0].TargetGroupArn" --output text)
  if [[ "$TG_ARN" != "None" && -n "$TG_ARN" ]]; then
    STATES=$(aws elbv2 describe-target-health --region "$REGION" --target-group-arn "$TG_ARN" \
      --query "TargetHealthDescriptions[].TargetHealth.State" --output text)
    if [[ -z "$STATES" ]]; then warn "Target group has no targets."
    elif echo "$STATES" | grep -qv healthy; then fail "Targets NOT healthy: $STATES"
    else pass "Targets healthy: $STATES"; fi
  fi
fi

echo -e "\n=== ECS service uses APP subnets, no public IPs ==="
CLUSTER=$(aws ecs list-clusters --region "$REGION" --query "clusterArns[?contains(@, \`$PREFIX\`)]|[0]" --output text)
SERVICE=$(aws ecs list-services --region "$REGION" --cluster "$CLUSTER" --query "serviceArns[0]" --output text)
if [[ "$CLUSTER" == "None" || "$SERVICE" == "None" || -z "$SERVICE" ]]; then
  warn "Could not auto-detect ECS service."
else
  ASSIGN=$(aws ecs describe-services --region "$REGION" --cluster "$CLUSTER" --services "$SERVICE" \
    --query "services[0].networkConfiguration.awsvpcConfiguration.assignPublicIp" --output text)
  [[ "$ASSIGN" == "DISABLED" ]] && pass "ECS assigns NO public IPs" || fail "ECS should not assign public IPs"
  mapfile -t ECSSUBS < <(aws ecs describe-services --region "$REGION" --cluster "$CLUSTER" --services "$SERVICE" \
    --query "services[0].networkConfiguration.awsvpcConfiguration.subnets" --output text | to_array)
  for s in "${ECSSUBS[@]}"; do
    if [[ -n "${APP_SET[$s]:-}" ]]; then pass "ECS subnet $s is an APP subnet"; else fail "ECS subnet $s not in APP set"; fi
  done
fi

echo -e "\n=== RESULT ==="
if [[ $FAILED -eq 0 ]]; then
  echo "All critical networking checks PASSED ✅"
else
  echo "One or more checks FAILED ❌ — see details above"; exit 1
fi
