#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Deploy the BFF to AWS: Lambda function + HTTP API (API Gateway v2).
#
# Usage:
#   ./deploy.sh <api-gateway-url> <backend-base-url> <frontend-origin>
#
# The values are written into the function's environment configuration, so no
# GitHub secret is needed for them.
# ---------------------------------------------------------------------------
set -euo pipefail

API_GATEWAY_URL="${1:?usage: deploy.sh <api-gateway-url> <backend-base-url> <frontend-origin>}"
BACKEND_BASE_URL="${2:?usage: deploy.sh <api-gateway-url> <backend-base-url> <frontend-origin>}"
FRONTEND_ORIGIN="${3:?usage: deploy.sh <api-gateway-url> <backend-base-url> <frontend-origin>}"
BACKEND_HOST_HEADER="${BACKEND_HOST_HEADER:-api.talent-hunting.internal}"

AWS_REGION="${AWS_REGION:-us-east-1}"
FUNCTION_NAME="talent-hunting-bff"
API_NAME="talent-hunting-bff-api"
ROLE_NAME="talent-hunting-bff-role"
LOG_GROUP="/aws/lambda/talent-hunting-bff"

#: How long the backend may take before the BFF gives up, in seconds.
#: This must stay below the API Gateway HTTP API integration cap (30s) so the
#: function can return a real error response instead of being killed mid-flight
#: and surfacing an opaque 503 to the caller.
UPSTREAM_TIMEOUT_SECONDS="${UPSTREAM_TIMEOUT_SECONDS:-25}"
#: The Lambda itself must outlive the upstream call but still finish before
#: API Gateway gives up on the integration.
LAMBDA_TIMEOUT_SECONDS="${LAMBDA_TIMEOUT_SECONDS:-29}"
LAMBDA_MEMORY_MB="${LAMBDA_MEMORY_MB:-256}"

ENV_VARS="BACKEND_BASE_URL=$BACKEND_BASE_URL,BACKEND_HOST_HEADER=$BACKEND_HOST_HEADER,FRONTEND_ORIGIN=$FRONTEND_ORIGIN,UPSTREAM_TIMEOUT_SECONDS=$UPSTREAM_TIMEOUT_SECONDS"

echo "==> Packaging the BFF"
ZIP_FILE="$(mktemp -t talent-hunting-bff-XXXXXX).zip"
zip -q "$ZIP_FILE" handler.py
echo "    $ZIP_FILE"

echo "==> Ensuring the CloudWatch log group exists"
aws logs create-log-group --log-group-name "$LOG_GROUP" --region "$AWS_REGION" 2>/dev/null || true

echo "==> Ensuring the execution role exists"
ROLE_ARN="$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text 2>/dev/null || true)"
if [ -z "$ROLE_ARN" ] || [ "$ROLE_ARN" = "None" ]; then
    echo "    creating $ROLE_NAME"
    aws iam create-role \
        --role-name "$ROLE_NAME" \
        --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
        --region "$AWS_REGION" >/dev/null
    aws iam attach-role-policy \
        --role-name "$ROLE_NAME" \
        --policy-arn "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole" \
        --region "$AWS_REGION"
    ROLE_ARN="$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text)"
    echo "    waiting for the role to propagate"
    sleep 10
fi
echo "    $ROLE_ARN"

echo "==> Creating or updating the function"
if aws lambda get-function --function-name "$FUNCTION_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
    aws lambda update-function-code \
        --function-name "$FUNCTION_NAME" \
        --zip-file "fileb://$ZIP_FILE" \
        --region "$AWS_REGION" >/dev/null
    aws lambda wait function-updated --function-name "$FUNCTION_NAME" --region "$AWS_REGION"
    aws lambda update-function-configuration \
        --function-name "$FUNCTION_NAME" \
        --runtime python3.12 \
        --handler handler.handler \
        --timeout "$LAMBDA_TIMEOUT_SECONDS" \
        --memory-size "$LAMBDA_MEMORY_MB" \
        --environment "Variables={$ENV_VARS}" \
        --region "$AWS_REGION" >/dev/null
else
    aws lambda create-function \
        --function-name "$FUNCTION_NAME" \
        --runtime python3.12 \
        --handler handler.handler \
        --role "$ROLE_ARN" \
        --timeout "$LAMBDA_TIMEOUT_SECONDS" \
        --memory-size "$LAMBDA_MEMORY_MB" \
        --environment "Variables={$ENV_VARS}" \
        --zip-file "fileb://$ZIP_FILE" \
        --region "$AWS_REGION" >/dev/null
    aws lambda wait function-active --function-name "$FUNCTION_NAME" --region "$AWS_REGION"
fi
FUNCTION_ARN="$(aws lambda get-function --function-name "$FUNCTION_NAME" --region "$AWS_REGION" \
    --query 'Configuration.FunctionArn' --output text)"
echo "    $FUNCTION_NAME ready"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

echo "==> Ensuring the HTTP API exists"
API_ID="$(aws apigatewayv2 get-apis --region "$AWS_REGION" \
    --query "Items[?Name=='$API_NAME'].ApiId | [0]" --output text)"
if [ -z "$API_ID" ] || [ "$API_ID" = "None" ]; then
    API_ID="$(aws apigatewayv2 create-api \
        --name "$API_NAME" \
        --protocol-type HTTP \
        --region "$AWS_REGION" \
        --query 'ApiId' --output text)"
    echo "    created API $API_ID"
else
    echo "    API $API_ID already exists"
fi

echo "==> Granting API Gateway permission to invoke the function"
# The permission is granted before the integration is created: API Gateway
# refuses to create a Lambda integration while the function cannot be
# invoked. The source ARN must contain the API id, not the API name.
aws lambda remove-permission \
    --function-name "$FUNCTION_NAME" \
    --statement-id "apigateway" \
    --region "$AWS_REGION" >/dev/null 2>&1 || true
aws lambda add-permission \
    --function-name "$FUNCTION_NAME" \
    --statement-id "apigateway" \
    --action lambda:InvokeFunction \
    --principal apigateway.amazonaws.com \
    --source-arn "arn:aws:execute-api:${AWS_REGION}:${ACCOUNT_ID}:${API_ID}/*/*" \
    --region "$AWS_REGION" >/dev/null

echo "==> Wiring the proxy integration"
INTEGRATION_ID="$(aws apigatewayv2 get-integrations --api-id "$API_ID" --region "$AWS_REGION" \
    --query "Items[0].IntegrationId" --output text 2>/dev/null || true)"
if [ -z "$INTEGRATION_ID" ] || [ "$INTEGRATION_ID" = "None" ]; then
    aws apigatewayv2 create-integration \
        --api-id "$API_ID" \
        --integration-type AWS_PROXY \
        --integration-uri "$FUNCTION_ARN" \
        --payload-format-version "2.0" \
        --region "$AWS_REGION" >/dev/null
else
    aws apigatewayv2 update-integration \
        --api-id "$API_ID" \
        --integration-id "$INTEGRATION_ID" \
        --integration-type AWS_PROXY \
        --integration-uri "$FUNCTION_ARN" \
        --payload-format-version "2.0" \
        --region "$AWS_REGION" >/dev/null
fi

echo "==> Wiring the proxy route"
ROUTE_ID="$(aws apigatewayv2 get-routes --api-id "$API_ID" --region "$AWS_REGION" \
    --query "Items[0].RouteId" --output text 2>/dev/null || true)"
if [ -z "$ROUTE_ID" ] || [ "$ROUTE_ID" = "None" ]; then
    aws apigatewayv2 create-route \
        --api-id "$API_ID" \
        --route-key '$default' \
        --target "integrations/$(
            aws apigatewayv2 get-integrations --api-id "$API_ID" --region "$AWS_REGION" \
                --query 'Items[0].IntegrationId' --output text
        )" \
        --region "$AWS_REGION" >/dev/null
else
    aws apigatewayv2 update-route \
        --api-id "$API_ID" \
        --route-id "$ROUTE_ID" \
        --route-key '$default' \
        --target "integrations/$(
            aws apigatewayv2 get-integrations --api-id "$API_ID" --region "$AWS_REGION" \
                --query 'Items[0].IntegrationId' --output text
        )" \
        --region "$AWS_REGION" >/dev/null
fi

echo "==> Creating the default stage"
aws apigatewayv2 create-stage --api-id "$API_ID" --stage-name '$default' --auto-deploy \
    --region "$AWS_REGION" >/dev/null 2>&1 || true

rm -f "$ZIP_FILE"

echo
echo "BFF deployed."
echo "  API ID:   $API_ID"
echo "  URL:      $API_GATEWAY_URL"
echo "  Function: $FUNCTION_NAME"
