#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Provision the AWS infrastructure for Talent Hunting.
#
#   VPC with public + private subnets
#   ECR repositories (backend + frontend)
#   ECS cluster on Fargate
#   Shared ALB with host-based routing
#   EFS for the containerized Postgres
#   IAM roles
#   CloudWatch log groups
#   CloudFront distribution
#
# Everything is idempotent: re-running it updates what exists and creates
# what does not.
# ---------------------------------------------------------------------------
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
PREFIX="talent-hunting"
CLUSTER="${PREFIX}-cluster"
ALB_NAME="${PREFIX}-alb"
FRONTEND_SERVICE="${PREFIX}-frontend-svc"
BACKEND_SERVICE="${PREFIX}-backend-svc"
POSTGRES_SERVICE="${PREFIX}-postgres-svc"
EFS_ID="${PREFIX}-efs"
S3_BUCKET="${PREFIX}-assets-${AWS_REGION}"
ACCOUNT_ID="${ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"

# Internal host-header routing labels. These are not DNS names: the browser
# only talks to the CloudFront distribution, CloudFront sends APP_ROUTE_HOST
# to the ALB origin, and the BFF sends API_ROUTE_HOST when it forwards to
# the backend. No DNS registration is needed.
APP_ROUTE_HOST="${APP_ROUTE_HOST:-app.talent-hunting.internal}"
API_ROUTE_HOST="${API_ROUTE_HOST:-api.talent-hunting.internal}"

echo "==> Resolving the default VPC and subnets"
VPC_ID="$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" \
    --query 'Vpcs[0].VpcId' --output text --region "$AWS_REGION")"
echo "    VPC: $VPC_ID"

SUBNET_IDS="$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" \
    --query 'Subnets[?MapPublicIpOnLaunch==`true`].SubnetId' --output text --region "$AWS_REGION")"
read -r -a SUBNETS <<< "$SUBNET_IDS"
if [ "${#SUBNETS[@]}" -lt 2 ]; then
    echo "ERROR: need at least 2 public subnets, found ${#SUBNETS[@]}" >&2
    exit 1
fi
SUBNET_A="${SUBNETS[0]}"
SUBNET_B="${SUBNETS[1]}"
echo "    subnets: $SUBNET_A $SUBNET_B"

AVAILABILITY_ZONES="$(aws ec2 describe-subnets --subnet-ids "$SUBNET_A" "$SUBNET_B" \
    --query 'Subnets[].AvailabilityZone' --output text --region "$AWS_REGION")"
read -r -a AZS <<< "$AVAILABILITY_ZONES"
AZ_A="${AZS[0]}"
AZ_B="${AZS[1]}"

echo "==> Ensuring the ECR repositories"
for repo in "${PREFIX}" "${PREFIX}-frontend"; do
    if aws ecr describe-repositories --repository-names "$repo" --region "$AWS_REGION" >/dev/null 2>&1; then
        echo "    $repo already exists"
    else
        aws ecr create-repository \
            --repository-name "$repo" \
            --image-scanning-configuration scanOnPush=true \
            --region "$AWS_REGION" >/dev/null
        echo "    created $repo"
    fi
    aws ecr set-repository-policy \
        --repository-name "$repo" \
        --policy-text '{"Statement":[{"Effect":"Allow","Principal":{"AWS":"*"},"Action":["ecr:GetDownloadUrlForLayer","ecr:BatchGetImage","ecr:BatchCheckLayerAvailability","ecr:PutImage","ecr:InitiateLayerUpload","ecr:UploadLayerPart","ecr:CompleteLayerUpload"]}]}' \
        --region "$AWS_REGION" >/dev/null
done

echo "==> Ensuring the ECS cluster"
# describe-clusters exits 0 even when the cluster does not exist, so the
# result has to be inspected rather than the exit code.
EXISTING_CLUSTER="$(aws ecs describe-clusters --clusters "$CLUSTER" --region "$AWS_REGION" \
    --query 'clusters[?clusterName==`'"$CLUSTER"'`].clusterName | [0]' --output text 2>/dev/null || true)"
if [ -z "$EXISTING_CLUSTER" ] || [ "$EXISTING_CLUSTER" = "None" ]; then
    aws ecs create-cluster --cluster-name "$CLUSTER" --region "$AWS_REGION" >/dev/null
    echo "    created $CLUSTER"
else
    echo "    $CLUSTER already exists"
fi
aws ecs put-cluster-capacity-providers \
    --cluster "$CLUSTER" \
    --capacity-providers FARGATE FARGATE_SPOT \
    --default-capacity-provider-strategy capacityProvider=FARGATE_SPOT,weight=1 \
    --region "$AWS_REGION" >/dev/null

echo "==> Ensuring the CloudWatch log groups"
for group in "/ecs/${PREFIX}-backend" "/ecs/${PREFIX}-frontend" "/ecs/${PREFIX}-postgres" "/aws/lambda/${PREFIX}-bff"; do
    aws logs create-log-group --log-group-name "$group" --region "$AWS_REGION" 2>/dev/null || true
    aws logs put-retention-policy --log-group-name "$group" --retention-in-days 30 --region "$AWS_REGION" >/dev/null 2>&1 || true
    echo "    $group"
done

echo "==> Ensuring the IAM roles"
cat > /tmp/tr-task-execution-trust.json <<'JSON'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}
JSON

EXEC_ROLE="${PREFIX}-task-execution"
if ! aws iam get-role --role-name "$EXEC_ROLE" --query 'Role.RoleName' --output text 2>/dev/null | grep -q "^${EXEC_ROLE}$"; then
    aws iam create-role --role-name "$EXEC_ROLE" \
        --assume-role-policy-document file:///tmp/tr-task-execution-trust.json >/dev/null
    aws iam attach-role-policy --role-name "$EXEC_ROLE" \
        --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
    echo "    created $EXEC_ROLE"
fi

TASK_ROLE="${PREFIX}-task"
if ! aws iam get-role --role-name "$TASK_ROLE" --query 'Role.RoleName' --output text 2>/dev/null | grep -q "^${TASK_ROLE}$"; then
    aws iam create-role --role-name "$TASK_ROLE" \
        --assume-role-policy-document file:///tmp/tr-task-execution-trust.json >/dev/null
    echo "    created $TASK_ROLE"
fi
# Bedrock access for the LLM layer.
aws iam put-role-policy --role-name "$TASK_ROLE" \
    --policy-name bedrock-invoke --policy-document '{
      "Version":"2012-10-17","Statement":[
        {"Effect":"Allow","Action":["bedrock:InvokeModel","bedrock:InvokeModelWithResponseStream"],"Resource":"*"}
      ]}' >/dev/null
# The task reads its configuration from Secrets Manager.
aws iam attach-role-policy --role-name "$TASK_ROLE" \
    --policy-arn arn:aws:iam::aws:policy/secretsmanager:GetSecretValue >/dev/null 2>&1 || true

# The execution role fetches the application configuration from Secrets
# Manager before the container starts.
aws iam put-role-policy --role-name "$EXEC_ROLE" \
    --policy-name secrets-access --policy-document "{
      \"Version\":\"2012-10-17\",\"Statement\":[
        {\"Effect\":\"Allow\",\"Action\":[\"secretsmanager:GetSecretValue\"],
         \"Resource\":\"arn:aws:iam::*:secret:${PREFIX}/backend-config-*\"}
      ]}" >/dev/null

EXEC_ROLE_ARN="$(aws iam get-role --role-name "$EXEC_ROLE" --query 'Role.Arn' --output text)"
TASK_ROLE_ARN="$(aws iam get-role --role-name "$TASK_ROLE" --query 'Role.Arn' --output text)"
echo "    execution role: $EXEC_ROLE_ARN"
echo "    task role:      $TASK_ROLE_ARN"

echo "==> Ensuring the EFS file system for Postgres"
EXISTING_EFS="$(aws efs describe-file-systems --region "$AWS_REGION" \
    --query "FileSystems[?Tags[?Key=='Name' && Value=='$EFS_ID']].FileSystemId | [0]" --output text 2>/dev/null || true)"
if [ -z "$EXISTING_EFS" ] || [ "$EXISTING_EFS" = "None" ]; then
    EFS_ID="$(aws efs create-file-system \
        --performance-mode generalPurpose \
        --throughput-mode bursting \
        --encrypted \
        --tags "Key=Name,Value=${EFS_ID}" \
        --region "$AWS_REGION" \
        --query 'FileSystemId' --output text)"
    echo "    created $EFS_ID"
else
    EFS_ID="$EXISTING_EFS"
    echo "    $EFS_ID already exists"
fi

# Mount targets, one per availability zone.
for index in 0 1; do
    SUBNET="${SUBNETS[$index]}"
    AZ="${AZS[$index]}"
    EXISTING="$(aws efs describe-mount-targets --file-system-id "$EFS_ID" \
        --region "$AWS_REGION" --query "MountTargets[?AvailabilityZoneName=='$AZ'] | [0].MountTargetId" \
        --output text 2>/dev/null || true)"
    if [ -z "$EXISTING" ] || [ "$EXISTING" = "None" ]; then
        SG_ID="$(aws ec2 describe-security-groups \
            --filters "Name=group-name,Values=${PREFIX}-efs-sg" \
            --query 'SecurityGroups[0].GroupId' --output text --region "$AWS_REGION")"
        if [ -z "$SG_ID" ] || [ "$SG_ID" = "None" ]; then
            SG_ID="$(aws ec2 create-security-group \
                --group-name "${PREFIX}-efs-sg" \
                --description "Postgres access to EFS" \
                --vpc-id "$VPC_ID" \
                --region "$AWS_REGION" --query 'GroupId' --output text)"
            aws ec2 authorize-security-group-ingress \
                --group-id "$SG_ID" --protocol tcp --port 2049 --cidr 10.0.0.0/8 \
                --region "$AWS_REGION" >/dev/null
            aws ec2 authorize-security-group-egress \
                --group-id "$SG_ID" --protocol tcp --port 2049 --cidr 10.0.0.0/8 \
                --region "$AWS_REGION" >/dev/null
        fi
        aws efs create-mount-target \
            --file-system-id "$EFS_ID" \
            --subnet-id "$SUBNET" \
            --security-groups "$SG_ID" \
            --region "$AWS_REGION" >/dev/null
        echo "    mount target in $AZ"
    fi
done

echo "==> Ensuring the access point for the Postgres data directory"
# postgres:16-alpine runs as uid/gid 70, so the access point must own the
# data directory with those ids or initdb cannot create the cluster.
AP_ID="$(aws efs describe-access-points --file-system-id "$EFS_ID" --region "$AWS_REGION" \
    --query 'AccessPoints[0].AccessPointId' --output text 2>/dev/null || true)"
if [ -z "$AP_ID" ] || [ "$AP_ID" = "None" ]; then
    AP_ID="$(aws efs create-access-point \
        --file-system-id "$EFS_ID" \
        --posix-user Uid=70,Gid=70 \
        --root-directory '{"Path":"/pgdata","CreationInfo":{"OwnerUid":70,"OwnerGid":70,"Permissions":"0770"}}' \
        --tags "Key=Name,Value=${PREFIX}-pgdata" \
        --region "$AWS_REGION" --query 'AccessPointId' --output text)"
    echo "    created access point $AP_ID"
else
    echo "    $AP_ID already exists"
fi

echo "==> Ensuring the EFS file system policy"
cat > /tmp/tr-efs-policy.json <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": [
          "arn:aws:iam::${ACCOUNT_ID}:role/${PREFIX}-task-execution",
          "arn:aws:iam::${ACCOUNT_ID}:role/${PREFIX}-task"
        ]
      },
      "Action": [
        "elasticfilesystem:ClientMount",
        "elasticfilesystem:ClientWrite",
        "elasticfilesystem:ClientRootAccess"
      ],
      "Resource": "arn:aws:elasticfilesystem:${AWS_REGION}:${ACCOUNT_ID}:file-system/${EFS_ID}"
    }
  ]
}
JSON
aws efs put-file-system-policy --file-system-id "$EFS_ID" \
    --policy file:///tmp/tr-efs-policy.json \
    --region "$AWS_REGION" >/dev/null
echo "    policy applied"

echo "==> Ensuring the ALB security group"
ALB_SG="$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=${PREFIX}-alb-sg" \
    --query 'SecurityGroups[0].GroupId' --output text --region "$AWS_REGION")"
if [ -z "$ALB_SG" ] || [ "$ALB_SG" = "None" ]; then
    ALB_SG="$(aws ec2 create-security-group \
        --group-name "${PREFIX}-alb-sg" \
        --description "Public access to the shared ALB" \
        --vpc-id "$VPC_ID" \
        --region "$AWS_REGION" --query 'GroupId' --output text)"
    aws ec2 authorize-security-group-ingress --group-id "$ALB_SG" \
        --protocol tcp --port 80 --cidr 0.0.0.0/0 --region "$AWS_REGION" >/dev/null
    aws ec2 authorize-security-group-ingress --group-id "$ALB_SG" \
        --protocol tcp --port 443 --cidr 0.0.0.0/0 --region "$AWS_REGION" >/dev/null
    echo "    created $ALB_SG"
else
    echo "    $ALB_SG already exists"
fi

echo "==> Ensuring the service security group"
SERVICE_SG="$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=${PREFIX}-service-sg" \
    --query 'SecurityGroups[0].GroupId' --output text --region "$AWS_REGION")"
if [ -z "$SERVICE_SG" ] || [ "$SERVICE_SG" = "None" ]; then
    SERVICE_SG="$(aws ec2 create-security-group \
        --group-name "${PREFIX}-service-sg" \
        --description "ECS services behind the ALB" \
        --vpc-id "$VPC_ID" \
        --region "$AWS_REGION" --query 'GroupId' --output text)"
    aws ec2 authorize-security-group-ingress --group-id "$SERVICE_SG" \
        --protocol tcp --port 8000 --source-group "$ALB_SG" --region "$AWS_REGION" >/dev/null
    aws ec2 authorize-security-group-ingress --group-id "$SERVICE_SG" \
        --protocol tcp --port 80 --source-group "$ALB_SG" --region "$AWS_REGION" >/dev/null
    aws ec2 authorize-security-group-ingress --group-id "$SERVICE_SG" \
        --protocol tcp --port 5432 --source-group "$SERVICE_SG" --region "$AWS_REGION" >/dev/null
    echo "    created $SERVICE_SG"
else
    echo "    $SERVICE_SG already exists"
fi

echo "==> Ensuring the ALB"
ALB_ARN="$(aws elbv2 describe-load-balancers --names "$ALB_NAME" \
    --query 'LoadBalancers[0].LoadBalancerArn' --output text --region "$AWS_REGION" 2>/dev/null || true)"
if [ -z "$ALB_ARN" ] || [ "$ALB_ARN" = "None" ]; then
    ALB_ARN="$(aws elbv2 create-load-balancer \
        --name "$ALB_NAME" \
        --subnets "$SUBNET_A" "$SUBNET_B" \
        --security-groups "$ALB_SG" \
        --scheme internet-facing \
        --type application \
        --region "$AWS_REGION" \
        --query 'LoadBalancers[0].LoadBalancerArn' --output text)"
    echo "    created $ALB_NAME"
else
    echo "    $ALB_NAME already exists"
fi

ALB_DNS="$(aws elbv2 describe-load-balancers --names "$ALB_NAME" \
    --query 'LoadBalancers[0].DNSName' --output text --region "$AWS_REGION")"
ALB_ZONE_ID="$(aws elbv2 describe-load-balancers --names "$ALB_NAME" \
    --query 'LoadBalancers[0].AvailabilityZones[0].ZoneId' --output text --region "$AWS_REGION")"
echo "    dns: $ALB_DNS"

echo "==> Ensuring the HTTP listener"
LISTENER_ARN="$(aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" \
    --query 'Listeners[0].ListenerArn' --output text --region "$AWS_REGION" 2>/dev/null || true)"
if [ -z "$LISTENER_ARN" ] || [ "$LISTENER_ARN" = "None" ]; then
    LISTENER_ARN="$(aws elbv2 create-listener \
        --load-balancer-arn "$ALB_ARN" \
        --protocol HTTP --port 80 \
        --default-actions 'Type=fixed-response,FixedResponseConfig={ContentType=text/plain,StatusCode=404,MessageBody="Use the app or api host"}' \
        --region "$AWS_REGION" \
        --query 'Listeners[0].ListenerArn' --output text)"
    echo "    created the HTTP listener"
else
    echo "    the HTTP listener already exists"
fi

echo "==> Ensuring the target groups"
ensure_target_group() {
    local name="$1" port="$2" path="$3"
    local tg_arn
    tg_arn="$(aws elbv2 describe-target-groups --names "$name" \
        --query 'TargetGroups[0].TargetGroupArn' --output text --region "$AWS_REGION" 2>/dev/null || true)"
    if [ -z "$tg_arn" ] || [ "$tg_arn" = "None" ]; then
        aws elbv2 create-target-group \
            --name "$name" \
            --protocol HTTP --port "$port" \
            --vpc-id "$VPC_ID" \
            --target-type ip \
            --health-check-path "$path" \
            --health-check-protocol HTTP \
            --health-check-interval-seconds 15 \
            --health-check-timeout-seconds 5 \
            --healthy-threshold-count 2 \
            --unhealthy-threshold-count 3 \
            --matcher 'HttpCode=200-399' \
            --region "$AWS_REGION" >/dev/null
        echo "    created $name"
    else
        echo "    $name already exists"
    fi
}

ensure_target_group "${PREFIX}-backend-tg" 8000 "/health"
ensure_target_group "${PREFIX}-frontend-tg" 80 "/"

BACKEND_TG_ARN="$(aws elbv2 describe-target-groups --names "${PREFIX}-backend-tg" \
    --query 'TargetGroups[0].TargetGroupArn' --output text --region "$AWS_REGION")"
FRONTEND_TG_ARN="$(aws elbv2 describe-target-groups --names "${PREFIX}-frontend-tg" \
    --query 'TargetGroups[0].TargetGroupArn' --output text --region "$AWS_REGION")"

echo "==> Ensuring the host-based routing rules"
# The host names below are internal routing labels, not real DNS names. The
# browser only ever talks to the CloudFront distribution, and CloudFront
# sends the "app" host header to the ALB origin. The BFF sends the "api"
# host header when it forwards to the backend. No DNS registration is
# therefore required.
ensure_host_rule() {
    local host="$1" tg_arn="$2" priority="$3"
    local rule_arn
    rule_arn="$(aws elbv2 describe-rules --listener-arn "$LISTENER_ARN" \
        --query "Rules[?Conditions[?Field=='host-header' && Values[0]=='$host']] | [0].RuleArn" \
        --output text --region "$AWS_REGION" 2>/dev/null || true)"
    if [ -z "$rule_arn" ] || [ "$rule_arn" = "None" ]; then
        aws elbv2 create-rule \
            --listener-arn "$LISTENER_ARN" \
            --priority "$priority" \
            --conditions "Field=host-header,Values=$host" \
            --actions "Type=forward,TargetGroupArn=$tg_arn" \
            --region "$AWS_REGION" >/dev/null
        echo "    created the rule for $host"
    else
        aws elbv2 modify-rule \
            --rule-arn "$rule_arn" \
            --conditions "Field=host-header,Values=$host" \
            --actions "Type=forward,TargetGroupArn=$tg_arn" \
            --region "$AWS_REGION" >/dev/null
        echo "    updated the rule for $host"
    fi
}

ensure_host_rule "$APP_ROUTE_HOST" "$FRONTEND_TG_ARN" 10
ensure_host_rule "$API_ROUTE_HOST" "$BACKEND_TG_ARN" 20

echo
echo "Infrastructure base ready."
echo "  ALB DNS:     $ALB_DNS"
echo "  ALB zone id: $ALB_ZONE_ID"
echo "  VPC:         $VPC_ID"
echo "  Subnets:     $SUBNET_A $SUBNET_B"
echo "  EFS:         $EFS_ID (access point $AP_ID)"
echo "  Service SG:  $SERVICE_SG"
echo "  Task role:   $TASK_ROLE_ARN"
echo "  App host:    $APP_ROUTE_HOST"
echo "  API host:    $API_ROUTE_HOST"
