#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Deploy the BFF to AWS: Lambda function + REST API (API Gateway v1).
#
# Usage:
#   ./deploy.sh <backend-base-url> <frontend-origin>
#
# The values are written into the function's environment configuration, so no
# GitHub secret is needed for them. The public URL of the API is derived from
# the REST API id, so it does not have to be passed in.
# ---------------------------------------------------------------------------
set -euo pipefail

BACKEND_BASE_URL="${1:?usage: deploy.sh <backend-base-url> <frontend-origin>}"
FRONTEND_ORIGIN="${2:?usage: deploy.sh <backend-base-url> <frontend-origin>}"
BACKEND_HOST_HEADER="${BACKEND_HOST_HEADER:-api.talent-hunting.internal}"

AWS_REGION="${AWS_REGION:-us-east-1}"
FUNCTION_NAME="talent-hunting-bff"
API_NAME="talent-hunting-bff-api"
ROLE_NAME="talent-hunting-bff-role"
LOG_GROUP="/aws/lambda/talent-hunting-bff"

#: The Lambda timeout. It has to outlive the longest backend call (an LLM
#: inference) and is well above the API Gateway integration cap, so the
#: gateway is always the component that gives up first.
LAMBDA_TIMEOUT_SECONDS="${LAMBDA_TIMEOUT_SECONDS:-300}"
LAMBDA_MEMORY_MB="${LAMBDA_MEMORY_MB:-256}"

#: The API Gateway integration timeout, in milliseconds. 29000 is the maximum
#: a REST API integration accepts.
INTEGRATION_TIMEOUT_MILLIS="${INTEGRATION_TIMEOUT_MILLIS:-29000}"

ENV_VARS="BACKEND_BASE_URL=$BACKEND_BASE_URL,BACKEND_HOST_HEADER=$BACKEND_HOST_HEADER,FRONTEND_ORIGIN=$FRONTEND_ORIGIN"

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

echo "==> Ensuring the REST API exists"
API_ID="$(aws apigateway get-rest-apis --region "$AWS_REGION" \
    --query "items[?name=='$API_NAME'].id | [0]" --output text)"
if [ -z "$API_ID" ] || [ "$API_ID" = "None" ]; then
    API_ID="$(aws apigateway create-rest-api \
        --name "$API_NAME" \
        --endpoint-configuration types=REGIONAL \
        --region "$AWS_REGION" \
        --query 'id' --output text)"
    echo "    created API $API_ID"
else
    echo "    API $API_ID already exists"
fi

echo "==> Granting API Gateway permission to invoke the function"
# The permission is granted before the integration is created: API Gateway
# refuses to create a Lambda integration while the function cannot be
# invoked. A REST API source ARN carries the stage and the method path.
aws lambda remove-permission \
    --function-name "$FUNCTION_NAME" \
    --statement-id "apigateway" \
    --region "$AWS_REGION" >/dev/null 2>&1 || true
aws lambda add-permission \
    --function-name "$FUNCTION_NAME" \
    --statement-id "apigateway" \
    --action lambda:InvokeFunction \
    --principal apigateway.amazonaws.com \
    --source-arn "arn:aws:execute-api:${AWS_REGION}:${ACCOUNT_ID}:${API_ID}/*/*/*" \
    --region "$AWS_REGION" >/dev/null

echo "==> Wiring the proxy integration"
# The API is a catch-all: a {proxy+} resource forwards every path to the
# function, which rebuilds the original URL from the event.
ROOT_RESOURCE_ID="$(aws apigateway get-resources --rest-api-id "$API_ID" \
    --region "$AWS_REGION" --query 'items[?path==`/`].id | [0]' --output text)"
PROXY_RESOURCE_ID="$(aws apigateway get-resources --rest-api-id "$API_ID" \
    --region "$AWS_REGION" --query 'items[?path==`/{proxy+}`].id | [0]' --output text)"
if [ -z "$PROXY_RESOURCE_ID" ] || [ "$PROXY_RESOURCE_ID" = "None" ]; then
    PROXY_RESOURCE_ID="$(aws apigateway create-resource \
        --rest-api-id "$API_ID" \
        --parent-id "$ROOT_RESOURCE_ID" \
        --path-part '{proxy+}' \
        --region "$AWS_REGION" \
        --query 'id' --output text)"
    echo "    created the {proxy+} resource"
else
    echo "    the {proxy+} resource already exists"
fi

for METHOD in ANY GET POST PUT PATCH DELETE HEAD OPTIONS; do
    aws apigateway put-method \
        --rest-api-id "$API_ID" \
        --resource-id "$PROXY_RESOURCE_ID" \
        --http-method "$METHOD" \
        --authorization-type NONE \
        --region "$AWS_REGION" >/dev/null 2>&1 || true
done

aws apigateway put-integration \
    --rest-api-id "$API_ID" \
    --resource-id "$PROXY_RESOURCE_ID" \
    --http-method ANY \
    --type AWS_PROXY \
    --integration-http-method POST \
    --uri "arn:aws:apigateway:${AWS_REGION}:lambda:path/2015-03-31/functions/${FUNCTION_ARN}/invocations" \
    --timeout-in-millis "$INTEGRATION_TIMEOUT_MILLIS" \
    --region "$AWS_REGION" >/dev/null

echo "==> Deploying to the \$default stage"
DEPLOYMENT_ID="$(aws apigateway create-deployment \
    --rest-api-id "$API_ID" \
    --stage-name '$default' \
    --region "$AWS_REGION" \
    --query 'id' --output text)"
echo "    deployment $DEPLOYMENT_ID"

rm -f "$ZIP_FILE"

REST_API_URL="$(aws apigateway get-rest-api --rest-api-id "$API_ID" --region "$AWS_REGION" \
    --query 'endpointConfiguration.regionalEndpoint' --output text)"
if [ -z "$REST_API_URL" ] || [ "$REST_API_URL" = "None" ]; then
    REST_API_URL="https://${API_ID}.execute-api.${AWS_REGION}.amazonaws.com"
fi

echo
echo "BFF deployed."
echo "  API ID:   $API_ID"
echo "  URL:      $REST_API_URL"
echo "  Function: $FUNCTION_NAME"
