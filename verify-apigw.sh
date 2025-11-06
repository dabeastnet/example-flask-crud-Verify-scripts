#!/usr/bin/env bash
set -euo pipefail
REGION=${REGION:-us-east-1}

echo "=== API Gateway (HTTP APIs via apigatewayv2) ==="
APIS=$(aws apigatewayv2 get-apis --region "$REGION" --query "Items[].ApiId" --output text || true)
if [[ -z "$APIS" ]]; then
  echo "No HTTP APIs found (apigatewayv2). If you used REST APIs, check 'apigateway' instead."
  exit 0
fi

for ID in $APIS; do
  URL=$(aws apigatewayv2 get-api --api-id "$ID" --region "$REGION" --query "ApiEndpoint" --output text)
  NAME=$(aws apigatewayv2 get-api --api-id "$ID" --region "$REGION" --query "Name" --output text)
  echo "API: $NAME  URL: $URL"
  code=$(curl -s -o /dev/null -w "%{http_code}" "$URL/health" || true)
  echo "  /health → $code"
done
