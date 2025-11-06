#!/usr/bin/env bash
# Verifies RDS posture for the 3-tier design:
# - Not publicly accessible
# - Multi-AZ status
# - DB subnet group has NO 0.0.0.0/0 internet route
# - DB SG allows 5432 from App SG
set -euo pipefail

REGION=${REGION:-us-east-1}
PREFIX=${PREFIX:-crudapp}
APP_SG_NAME=${APP_SG_NAME:-crud-app-sg}

pass() { echo -e "✅  $*"; }
warn() { echo -e "⚠️  $*"; }
fail() { echo -e "❌  $*"; exit 1; }

# --- Locate DB instance ---
DBID=$(aws rds describe-db-instances --region "$REGION" \
  --query "DBInstances[?contains(DBInstanceIdentifier, \`$PREFIX\`)].DBInstanceIdentifier | [0]" \
  --output text)
[[ "$DBID" == "None" || -z "$DBID" ]] && fail "DB instance not found for prefix '$PREFIX'"

aws rds describe-db-instances --region "$REGION" --db-instance-identifier "$DBID" \
  --query "DBInstances[0].[DBInstanceIdentifier,DBInstanceStatus,Engine,EngineVersion,DBInstanceClass,PubliclyAccessible,MultiAZ,Endpoint.Address]" \
  --output table

# --- PubliclyAccessible and Multi-AZ ---
PUB=$(aws rds describe-db-instances --region "$REGION" --db-instance-identifier "$DBID" \
  --query "DBInstances[0].PubliclyAccessible" --output text)
[[ "$PUB" == "False" ]] && pass "RDS is NOT publicly accessible" || fail "RDS should not be publicly accessible"

MZ=$(aws rds describe-db-instances --region "$REGION" --db-instance-identifier "$DBID" \
  --query "DBInstances[0].MultiAZ" --output text)
[[ "$MZ" == "True" ]] && pass "Multi-AZ enabled" || warn "Multi-AZ disabled (okay for cost-saving in lab)"

# --- DB subnet group & routes (no internet default) ---
SNG=$(aws rds describe-db-instances --region "$REGION" --db-instance-identifier "$DBID" \
  --query "DBInstances[0].DBSubnetGroup.DBSubnetGroupName" --output text)
echo "DB Subnet Group: $SNG"

DB_SUBNETS=$(aws rds describe-db-subnet-groups --region "$REGION" --db-subnet-group-name "$SNG" \
  --query "DBSubnetGroups[0].Subnets[].SubnetIdentifier" --output text)
echo "DB Subnets: $DB_SUBNETS"

for s in $DB_SUBNETS; do
  RT=$(aws ec2 describe-route-tables --region "$REGION" \
      --filters Name=association.subnet-id,Values="$s" \
      --query "RouteTables[0].RouteTableId" --output text)
  DEF=$(aws ec2 describe-route-tables --region "$REGION" --route-table-ids "$RT" \
      --query "length(RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'])" --output text)
  if [[ "$DEF" == "0" ]]; then
    pass "DB subnet $s has no internet default route"
  else
    fail "DB subnet $s has a default route 0.0.0.0/0 — should be NONE"
  fi
done

# --- Security Groups: DB allows 5432 from App SG ---
DB_SG=$(aws rds describe-db-instances --region "$REGION" --db-instance-identifier "$DBID" \
  --query "DBInstances[0].VpcSecurityGroups[0].VpcSecurityGroupId" --output text)
[[ "$DB_SG" == "None" || -z "$DB_SG" ]] && fail "Could not resolve DB security group"

APP_SG=$(aws ec2 describe-security-groups --region "$REGION" \
  --filters Name=group-name,Values="$APP_SG_NAME" \
  --query "SecurityGroups[0].GroupId" --output text || true)

echo "DB_SG=$DB_SG  APP_SG=${APP_SG:-unknown}"

IN_JSON=$(aws ec2 describe-security-groups --region "$REGION" --group-ids "$DB_SG" \
  --query "SecurityGroups[0].IpPermissions" --output json)

if [[ -n "${APP_SG:-}" && "$APP_SG" != "None" ]] \
   && echo "$IN_JSON" | grep -q '"FromPort": 5432' \
   && echo "$IN_JSON" | grep -q "\"GroupId\": \"$APP_SG\""; then
  pass "DB SG allows 5432 from APP SG ($APP_SG)"
elif echo "$IN_JSON" | grep -q '"FromPort": 5432'; then
  warn "DB SG allows 5432 but not specifically from $APP_SG_NAME (check source group)"
else
  fail "DB SG missing inbound 5432 rule from App"
fi

# --- Optional: parameter group name (for your docs) ---
PG=$(aws rds describe-db-instances --region "$REGION" --db-instance-identifier "$DBID" \
  --query "DBInstances[0].DBParameterGroups[0].DBParameterGroupName" --output text || echo "")
[[ -n "$PG" && "$PG" != "None" ]] && echo "Parameter group: $PG"

echo "Done."
