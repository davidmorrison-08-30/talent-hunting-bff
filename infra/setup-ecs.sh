#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Register the ECS task definitions and services.
#
#   backend  - the FastAPI service (uvicorn on port 8000)
#   frontend - the Nginx-served Vite bundle (port 80)
#   postgres - Postgres 16 with its data directory on EFS
#
# The backend and Postgres run in the same task so they share the loopback
# interface and the EFS mount; the frontend runs on its own.
# ---------------------------------------------------------------------------
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
PREFIX="talent-hunting"
CLUSTER="${PREFIX}-cluster"
VPC_ID="${VPC_ID:-}"
SUBNET_A="${SUBNET_A:-}"
SUBNET_B="${SUBNET_B:-}"
SERVICE_SG="${SERVICE_SG:-}"
EXEC_ROLE_ARN="${EXEC_ROLE_ARN:-}"
TASK_ROLE_ARN="${TASK_ROLE_ARN:-}"
EFS_ID="${EFS_ID:-}"
AP_ID="${AP_ID:-}"
BACKEND_TG_ARN="${BACKEND_TG_ARN:-}"
FRONTEND_TG_ARN="${FRONTEND_TG_ARN:-}"
ACCOUNT_ID="${ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"

if [ -z "$VPC_ID" ] || [ -z "$SERVICE_SG" ] || [ -z "$EXEC_ROLE_ARN" ]; then
    echo "ERROR: run setup-aws.sh first, or export VPC_ID, SERVICE_SG, EXEC_ROLE_ARN." >&2
    exit 1
fi

REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

# The application configuration is stored in Secrets Manager so it never
# appears in the task definition. Create it if it does not exist yet.
SECRET_NAME="${PREFIX}/backend-config"

echo "==> Ensuring the secret ${SECRET_NAME}"
SECRET_ARN="$(aws secretsmanager describe-secret --secret-id "$SECRET_NAME" --region "$AWS_REGION" \
    --query 'ARN' --output text 2>/dev/null || true)"
if [ -z "$SECRET_ARN" ] || [ "$SECRET_ARN" = "None" ]; then
    SECRET_ARN="$(aws secretsmanager create-secret \
        --name "$SECRET_NAME" \
        --description "Talent Hunting backend configuration" \
        --region "$AWS_REGION" \
        --query 'ARN' --output text)"
    echo "    created (fill in the values before the first deploy)"
fi
echo "    $SECRET_ARN"

echo "==> Registering the backend + postgres task definition"
cat > /tmp/tr-backend-task.json <<JSON
{
  "family": "${PREFIX}-backend",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "1024",
  "memory": "2048",
  "executionRoleArn": "${EXEC_ROLE_ARN}",
  "taskRoleArn": "${TASK_ROLE_ARN}",
  "runtimePlatform": {"cpuArchitecture": "X86_64", "operatingSystemFamily": "LINUX"},
  "containerDefinitions": [
    {
      "name": "backend",
      "image": "${REGISTRY}/${PREFIX}:latest",
      "essential": true,
      "portMappings": [{"containerPort": 8000, "protocol": "tcp"}],
      "environment": [
        {"name": "RUN_MIGRATIONS_ON_STARTUP", "value": "true"},
        {"name": "ENABLE_DISPATCHER", "value": "true"},
        {"name": "AWS_REGION", "value": "${AWS_REGION}"},
        {"name": "DEBUG", "value": "false"},
        {"name": "LOG_LEVEL", "value": "INFO"}
      ],
      "secrets": [
        {"name": "DATABASE_URL", "valueFrom": "${SECRET_ARN}:DATABASE_URL::"},
        {"name": "DB_ECHO", "valueFrom": "${SECRET_ARN}:DB_ECHO::"},
        {"name": "X_CLIENT_ID", "valueFrom": "${SECRET_ARN}:X_CLIENT_ID::"},
        {"name": "X_CLIENT_SECRET", "valueFrom": "${SECRET_ARN}:X_CLIENT_SECRET::"},
        {"name": "X_REDIRECT_URI", "valueFrom": "${SECRET_ARN}:X_REDIRECT_URI::"},
        {"name": "X_BEARER_TOKEN", "valueFrom": "${SECRET_ARN}:X_BEARER_TOKEN::"},
        {"name": "X_SCOPES", "valueFrom": "${SECRET_ARN}:X_SCOPES::"},
        {"name": "AWS_BEDROCK_MODEL_ID", "valueFrom": "${SECRET_ARN}:AWS_BEDROCK_MODEL_ID::"},
        {"name": "AWS_BEARER_TOKEN_BEDROCK", "valueFrom": "${SECRET_ARN}:AWS_BEARER_TOKEN_BEDROCK::"},
        {"name": "DM_DAILY_CAP", "valueFrom": "${SECRET_ARN}:DM_DAILY_CAP::"},
        {"name": "DM_MIN_DELAY_SECONDS", "valueFrom": "${SECRET_ARN}:DM_MIN_DELAY_SECONDS::"},
        {"name": "DM_MAX_DELAY_SECONDS", "valueFrom": "${SECRET_ARN}:DM_MAX_DELAY_SECONDS::"},
        {"name": "DM_SIMILARITY_THRESHOLD", "valueFrom": "${SECRET_ARN}:DM_SIMILARITY_THRESHOLD::"},
        {"name": "DM_POLL_INTERVAL_SECONDS", "valueFrom": "${SECRET_ARN}:DM_POLL_INTERVAL_SECONDS::"},
        {"name": "DISCOVERY_SPEND_CEILING_USD", "valueFrom": "${SECRET_ARN}:DISCOVERY_SPEND_CEILING_USD::"}
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/${PREFIX}-backend",
          "awslogs-region": "${AWS_REGION}",
          "awslogs-stream-prefix": "backend"
        }
      },
      "healthCheck": {
        "command": ["CMD-SHELL", "curl -fsS http://localhost:8000/health || exit 1"],
        "interval": 30,
        "timeout": 5,
        "retries": 3,
        "startPeriod": 40
      }
    },
    {
      "name": "postgres",
      "image": "postgres:16-alpine",
      "essential": true,
      "environment": [
        {"name": "POSTGRES_USER", "value": "postgres"},
        {"name": "POSTGRES_PASSWORD", "value": "postgres"},
        {"name": "POSTGRES_DB", "value": "talent_hunting"},
        {"name": "PGDATA", "value": "/var/lib/postgresql/data/pgdata"}
      ],
      "mountPoints": [
        {"sourceVolume": "pgdata", "containerPath": "/var/lib/postgresql/data", "readOnly": false}
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/${PREFIX}-postgres",
          "awslogs-region": "${AWS_REGION}",
          "awslogs-stream-prefix": "postgres"
        }
      },
      "healthCheck": {
        "command": ["CMD-SHELL", "pg_isready -U postgres -d talent_hunting"],
        "interval": 15,
        "timeout": 5,
        "retries": 5,
        "startPeriod": 30
      }
    }
  ],
  "volumes": [
    {
      "name": "pgdata",
      "efsVolumeConfiguration": {
        "fileSystemId": "${EFS_ID}",
        "rootDirectory": "/",
        "transitEncryption": "ENABLED",
        "authorizationConfig": {"accessPointId": "${AP_ID}", "iam": "ENABLED"}
      }
    }
  ]
}
JSON

aws ecs register-task-definition --cli-input-json file:///tmp/tr-backend-task.json \
    --region "$AWS_REGION" > /dev/null
echo "    ${PREFIX}-backend registered"

echo "==> Registering the frontend task definition"
cat > /tmp/tr-frontend-task.json <<JSON
{
  "family": "${PREFIX}-frontend",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "512",
  "memory": "1024",
  "executionRoleArn": "${EXEC_ROLE_ARN}",
  "taskRoleArn": "${TASK_ROLE_ARN}",
  "runtimePlatform": {"cpuArchitecture": "X86_64", "operatingSystemFamily": "LINUX"},
  "containerDefinitions": [
    {
      "name": "frontend",
      "image": "${REGISTRY}/${PREFIX}-frontend:latest",
      "essential": true,
      "portMappings": [{"containerPort": 80, "protocol": "tcp"}],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/${PREFIX}-frontend",
          "awslogs-region": "${AWS_REGION}",
          "awslogs-stream-prefix": "frontend"
        }
      },
      "healthCheck": {
        "command": ["CMD-SHELL", "wget -q -O /dev/null http://localhost/ || exit 1"],
        "interval": 30,
        "timeout": 5,
        "retries": 3,
        "startPeriod": 15
      }
    }
  ]
}
JSON

aws ecs register-task-definition --cli-input-json file:///tmp/tr-frontend-task.json \
    --region "$AWS_REGION" > /dev/null
echo "    ${PREFIX}-frontend registered"

echo "==> Creating the ECS services"
ensure_service() {
    local service="$1" task_family="$2" tg_arn="$3"
    local existing
    existing="$(aws ecs describe-services --cluster "$CLUSTER" --services "$service" --region "$AWS_REGION" \
        --query "services[?serviceName==\`$service\`].serviceName | [0]" --output text 2>/dev/null || true)"
    if [ -z "$existing" ] || [ "$existing" = "None" ]; then
        aws ecs create-service \
            --cluster "$CLUSTER" \
            --service-name "$service" \
            --task-definition "$task_family" \
            --desired-count 1 \
            --launch-type FARGATE \
            --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_A,$SUBNET_B],securityGroups=[$SERVICE_SG],assignPublicIp=ENABLED}" \
            --load-balancers "targetGroupArn=$tg_arn,containerName=$( [ "$service" = "${PREFIX}-backend-svc" ] && echo backend || echo frontend ),containerPort=$( [ "$service" = "${PREFIX}-backend-svc" ] && echo 8000 || echo 80 )" \
            --health-check-grace-period-seconds 60 \
            --region "$AWS_REGION" > /dev/null
        echo "    created $service"
    else
        aws ecs update-service --cluster "$CLUSTER" --service "$service" \
            --task-definition "$task_family" --desired-count 1 \
            --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_A,$SUBNET_B],securityGroups=[$SERVICE_SG],assignPublicIp=ENABLED}" \
            --region "$AWS_REGION" > /dev/null
        echo "    updated $service"
    fi
}

ensure_service "${PREFIX}-backend-svc" "${PREFIX}-backend" "$BACKEND_TG_ARN"
ensure_service "${PREFIX}-frontend-svc" "${PREFIX}-frontend" "$FRONTEND_TG_ARN"

echo
echo "ECS services ready."
