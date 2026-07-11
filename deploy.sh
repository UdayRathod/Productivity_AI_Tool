#!/usr/bin/env bash
#
# One-shot deploy for the "Brain Dump -> Plan" Lambda backend.
#
# Creates (idempotently):
#   - an IAM role for the Lambda with permission to invoke Bedrock Nova
#   - the Lambda function (Python 3.12)
#   - a public, CORS-enabled Function URL
#
# Prereqs: AWS CLI v2 configured (`aws configure`) and Bedrock Nova access
# enabled in $REGION. See ../README.md.
#
# Usage:   ./infra/deploy.sh
# Re-run:  safe — it updates the function code if it already exists.

set -euo pipefail

# ---- Config (override via env vars) -----------------------------------------
REGION="${REGION:-us-east-1}"
FUNCTION_NAME="${FUNCTION_NAME:-brain-dump-planner}"
ROLE_NAME="${ROLE_NAME:-brain-dump-planner-role}"
MODEL_ID="${MODEL_ID:-us.amazon.nova-lite-v1:0}"
RUNTIME="python3.12"
HANDLER="lambda_function.handler"

# Resolve paths relative to this script so it runs from anywhere.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_DIR="$(cd "$SCRIPT_DIR/../backend" && pwd)"
BUILD_DIR="$(mktemp -d)"
ZIP_PATH="$BUILD_DIR/function.zip"

echo "==> Region:        $REGION"
echo "==> Function:      $FUNCTION_NAME"
echo "==> Model:         $MODEL_ID"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"

# ---- 1. IAM role -------------------------------------------------------------
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  echo "==> IAM role exists: $ROLE_NAME"
else
  echo "==> Creating IAM role: $ROLE_NAME"
  aws iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document "file://$SCRIPT_DIR/trust-policy.json" >/dev/null
  # Basic execution role for CloudWatch Logs.
  aws iam attach-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-arn "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
  echo "==> Waiting for role to propagate..."
  sleep 10
fi

# Attach/refresh the inline Bedrock policy every run (cheap + idempotent).
aws iam put-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name "invoke-nova" \
  --policy-document "file://$SCRIPT_DIR/bedrock-policy.json"

# ---- 2. Package the function -------------------------------------------------
echo "==> Packaging Lambda from $BACKEND_DIR"
cp "$BACKEND_DIR/lambda_function.py" "$BUILD_DIR/"
( cd "$BUILD_DIR" && zip -q "$ZIP_PATH" lambda_function.py )

# ---- 3. Create or update the function ---------------------------------------
if aws lambda get-function --function-name "$FUNCTION_NAME" --region "$REGION" >/dev/null 2>&1; then
  echo "==> Updating function code"
  aws lambda update-function-code \
    --function-name "$FUNCTION_NAME" \
    --zip-file "fileb://$ZIP_PATH" \
    --region "$REGION" >/dev/null
  aws lambda wait function-updated --function-name "$FUNCTION_NAME" --region "$REGION"
  aws lambda update-function-configuration \
    --function-name "$FUNCTION_NAME" \
    --timeout 30 --memory-size 256 \
    --environment "Variables={MODEL_ID=$MODEL_ID,BEDROCK_REGION=$REGION}" \
    --region "$REGION" >/dev/null
else
  echo "==> Creating function"
  aws lambda create-function \
    --function-name "$FUNCTION_NAME" \
    --runtime "$RUNTIME" \
    --role "$ROLE_ARN" \
    --handler "$HANDLER" \
    --zip-file "fileb://$ZIP_PATH" \
    --timeout 30 --memory-size 256 \
    --environment "Variables={MODEL_ID=$MODEL_ID,BEDROCK_REGION=$REGION}" \
    --region "$REGION" >/dev/null
  aws lambda wait function-active --function-name "$FUNCTION_NAME" --region "$REGION"
fi

# ---- 4. API Gateway HTTP API (public, in front of the Lambda) ---------------
#
# We use an HTTP API rather than a Lambda Function URL because some accounts
# reject anonymous (AuthType NONE) Function URL calls. An HTTP API with no
# authorizer is reliably public and lives on execute-api.amazonaws.com, which
# corporate proxies allow. It's also Free Tier (1M requests/month for 12 months).
API_NAME="${API_NAME:-brain-dump-api}"
LAMBDA_ARN="arn:aws:lambda:${REGION}:${ACCOUNT_ID}:function:${FUNCTION_NAME}"

# Find an existing API with this name, or create one.
API_ID="$(aws apigatewayv2 get-apis --region "$REGION" \
  --query "Items[?Name=='${API_NAME}'].ApiId | [0]" --output text)"

if [ "$API_ID" = "None" ] || [ -z "$API_ID" ]; then
  echo "==> Creating HTTP API: $API_NAME"
  API_ID="$(aws apigatewayv2 create-api \
    --name "$API_NAME" \
    --protocol-type HTTP \
    --region "$REGION" \
    --query ApiId --output text)"

  # Create the AWS_PROXY integration with an explicit, correct Lambda ARN.
  INTEGRATION_ID="$(aws apigatewayv2 create-integration \
    --api-id "$API_ID" \
    --integration-type AWS_PROXY \
    --integration-uri "$LAMBDA_ARN" \
    --payload-format-version "2.0" \
    --integration-method POST \
    --region "$REGION" \
    --query IntegrationId --output text)"

  # Catch-all route -> integration. The Lambda handles method + CORS itself.
  aws apigatewayv2 create-route \
    --api-id "$API_ID" \
    --route-key '$default' \
    --target "integrations/${INTEGRATION_ID}" \
    --region "$REGION" >/dev/null

  # Auto-deploying default stage: endpoint is the bare API URL, no stage path.
  aws apigatewayv2 create-stage \
    --api-id "$API_ID" \
    --stage-name '$default' \
    --auto-deploy \
    --region "$REGION" >/dev/null
else
  echo "==> HTTP API exists: $API_NAME ($API_ID)"
  # Make sure the integration URI is correct (guards against a bad ARN).
  INTEGRATION_ID="$(aws apigatewayv2 get-integrations --api-id "$API_ID" \
    --region "$REGION" --query "Items[0].IntegrationId" --output text)"
  aws apigatewayv2 update-integration \
    --api-id "$API_ID" \
    --integration-id "$INTEGRATION_ID" \
    --integration-uri "$LAMBDA_ARN" \
    --region "$REGION" >/dev/null
fi

# Allow API Gateway to invoke the Lambda (idempotent).
aws lambda add-permission \
  --function-name "$FUNCTION_NAME" \
  --statement-id "apigw-invoke" \
  --action "lambda:InvokeFunction" \
  --principal "apigateway.amazonaws.com" \
  --source-arn "arn:aws:execute-api:${REGION}:${ACCOUNT_ID}:${API_ID}/*" \
  --region "$REGION" >/dev/null 2>&1 || true

API_ENDPOINT="$(aws apigatewayv2 get-api --api-id "$API_ID" \
  --query ApiEndpoint --output text --region "$REGION")/"

rm -rf "$BUILD_DIR"

echo ""
echo "============================================================"
echo " Deployed!  Your public API endpoint:"
echo ""
echo "   $API_ENDPOINT"
echo ""
echo " Next: paste that URL into frontend/index.html (API_URL),"
echo " then host the frontend (see README.md)."
echo ""
echo " Quick test:"
echo "   curl -s -X POST '$API_ENDPOINT' \\"
echo "     -H 'Content-Type: application/json' \\"
echo "     -d '{\"brain_dump\":\"call dentist, finish deck for thursday, buy milk\"}'"
echo "============================================================"
