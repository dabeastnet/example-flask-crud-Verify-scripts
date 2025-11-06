#!/usr/bin/env bash
# Verifies your ECS service aligns with the design:
# - Service steady, assignPublicIp=DISABLED
# - Task definition & env vars (DATABASE_URL, RUN_MIGRATIONS, etc.)
# - awslogs group + recent error scan
# - ALB/TargetGroup attachment & health
set -euo pipefail

REGION=${REGION:-us-east-1}
PREFIX=${PREFIX:-crudapp}

pass() { echo -e "✅  $*"; }
warn() { echo -e "⚠️  $*"; }
fail() { echo -e "❌  $*"; exit 1; }

# --- Locate cluster & service ---
CLUSTER=$(aws ecs list-clusters --region "$REGION" \
  --query "clusterArns[?contains(@, \`$PREFIX\`)]|[0]" --output text)
if [[ "$CLUSTER" == "None" || -z "$CLUSTER" ]]; then
  CLUSTER=$(aws ecs list-clusters --region "$REGION" --query "clusterArns[0]" --output text)
fi
[[ "$CLUSTER" == "None" || -z "$CLUSTER" ]] && fail "No ECS cluster found"

SERVICE=$(aws ecs list-services --region "$REGION" --cluster "$CLUSTER" \
  --query "serviceArns[?contains(@, \`$PREFIX\`)]|[0]" --output text)
if [[ "$SERVICE" == "None" || -z "$SERVICE" ]]; then
  SERVICE=$(aws ecs list-services --region "$REGION" --cluster "$CLUSTER" \
    --query "serviceArns[0]" --output text)
fi
[[ "$SERVICE" == "None" || -z "$SERVICE" ]] && fail "No ECS service found in cluster $CLUSTER"

echo "Cluster: $CLUSTER"
echo "Service: $SERVICE"
aws ecs describe-services --region "$REGION" --cluster "$CLUSTER" --services "$SERVICE" \
  --query "services[0].[status,desiredCount,runningCount,pendingCount,launchType]" --output table

# --- Networking flags ---
ASSIGN=$(aws ecs describe-services --region "$REGION" --cluster "$CLUSTER" --services "$SERVICE" \
  --query "services[0].networkConfiguration.awsvpcConfiguration.assignPublicIp" --output text || echo "")
if [[ "$ASSIGN" == "DISABLED" ]]; then
  pass "assignPublicIp=DISABLED (private subnets as intended)"
else
  warn "assignPublicIp is '$ASSIGN' (expected DISABLED)"
fi

# --- Task definition & env ---
TASKDEF=$(aws ecs describe-services --region "$REGION" --cluster "$CLUSTER" --services "$SERVICE" \
  --query "services[0].taskDefinition" --output text)
[[ "$TASKDEF" == "None" || -z "$TASKDEF" ]] && fail "No task definition attached"
echo "TaskDef: $TASKDEF"

echo -e "\nContainer environment (first container):"
aws ecs describe-task-definition --region "$REGION" --task-definition "$TASKDEF" \
  --query "taskDefinition.containerDefinitions[0].environment" --output table || warn "No env block found"

# --- Logs ---
LOG_GROUP=$(aws ecs describe-task-definition --region "$REGION" --task-definition "$TASKDEF" \
  --query "taskDefinition.containerDefinitions[0].logConfiguration.options.\"awslogs-group\"" \
  --output text || echo "")
if [[ -n "$LOG_GROUP" && "$LOG_GROUP" != "None" ]]; then
  echo "Log group: $LOG_GROUP"
  echo -e "\nRecent errors (last 15m):"
  aws logs tail "$LOG_GROUP" --since 15m --format short --region "$REGION" | \
    egrep -i 'OperationalError|psycopg|alembic|migrat|error' || echo "(no obvious DB/migration errors)"
else
  warn "awslogs not configured in task definition (skipping log tail)"
fi

# --- ALB / TargetGroup health if attached ---
LBINFO=$(aws ecs describe-services --region "$REGION" --cluster "$CLUSTER" --services "$SERVICE" \
  --query "services[0].loadBalancers[0].[targetGroupArn,containerName,containerPort]" --output text || echo "")
if [[ -n "$LBINFO" && "$LBINFO" != "None" ]]; then
  read -r TGARN CNAME CPORT <<<"$LBINFO"
  echo -e "\nLoad balancer attachment:"
  echo "  Target Group: $TGARN"
  echo "  Container:    $CNAME:$CPORT"
  STATES=$(aws elbv2 describe-target-health --region "$REGION" --target-group-arn "$TGARN" \
    --query "TargetHealthDescriptions[].TargetHealth.State" --output text | tr '\n' ' ' || true)
  if [[ -n "$STATES" ]]; then
    if echo "$STATES" | grep -qv healthy; then
      fail "One or more targets are NOT healthy: $STATES"
    else
      pass "Targets healthy: $STATES"
    fi
  else
    warn "Target group has no registered targets"
  fi
else
  warn "Service has no load balancer attachment"
fi

# --- Subnets used by the service (for your records) ---
echo -e "\nSubnets used by service:"
aws ecs describe-services --region "$REGION" --cluster "$CLUSTER" --services "$SERVICE" \
  --query "services[0].networkConfiguration.awsvpcConfiguration.subnets" --output text
