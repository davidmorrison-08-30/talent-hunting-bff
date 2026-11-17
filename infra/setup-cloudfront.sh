#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Create the CloudFront distribution in front of the shared ALB.
#
# The distribution's origin is the ALB DNS name. CloudFront cannot override
# the "Host" header of a custom origin, so the ALB is configured to route by
# path instead:
#
#   /api/*  -> backend target group
#   /*      -> frontend target group (the listener default action)
#
# The host-header rules (app./api.talent-hunting.internal) are kept on the
# ALB so direct ALB access still works for debugging.
#
# Usage:
#   ./setup-cloudfront.sh
# ---------------------------------------------------------------------------
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
PREFIX="talent-hunting"
ALB_NAME="${PREFIX}-alb"

ALB_DNS="$(aws elbv2 describe-load-balancers --names "$ALB_NAME" \
    --query 'LoadBalancers[0].DNSName' --output text --region "$AWS_REGION")"

CALLER_REFERENCE="talent-hunting-$(date +%s)"

echo "==> Creating the CloudFront distribution"

# The AWS CLI expects list members as Items/Quantity pairs. Note that the
# "Host" header cannot be used in CustomHeaders for custom origins.
aws cloudfront create-distribution \
    --distribution-config \
"Comment=${PREFIX} frontend,Enabled=true,CallerReference=${CALLER_REFERENCE},Origins={Quantity=1,Items=[{Id=alb-origin,DomainName=${ALB_DNS},OriginPath=,CustomOriginConfig={HTTPPort=80,HTTPSPort=443,OriginProtocolPolicy=http-only,OriginSslProtocols={Quantity=1,Items=[TLSv1.2]},OriginReadTimeout=60,OriginKeepaliveTimeout=30},ConnectionAttempts=3,ConnectionTimeout=10}]},DefaultCacheBehavior={TargetOriginId=alb-origin,ViewerProtocolPolicy=redirect-to-https,Compress=true,AllowedMethods={Quantity=2,Items=[GET,HEAD]},ForwardedValues={QueryString=false,Cookies={Forward=none}},MinTTL=0,DefaultTTL=300,MaxTTL=86400},CacheBehaviors={Quantity=1,Items=[{PathPattern=/api/*,TargetOriginId=alb-origin,ViewerProtocolPolicy=redirect-to-https,Compress=true,AllowedMethods={Quantity=7,Items=[GET,HEAD,OPTIONS,PUT,PATCH,POST,DELETE]},ForwardedValues={QueryString=true,Cookies={Forward=none}},MinTTL=0,DefaultTTL=0,MaxTTL=0}]},CustomErrorResponses={Quantity=1,Items=[{ErrorCode=404,ResponseCode=404,ResponsePagePath=/index.html,ErrorCachingMinTTL=0}]},ViewerCertificate={CloudFrontDefaultCertificate=true,MinimumProtocolVersion=TLSv1.2_2021}" \
    --query 'Distribution.Id' --output text > /tmp/tr-cf-dist-id.txt

DIST_ID="$(cat /tmp/tr-cf-dist-id.txt)"
echo "    distribution: $DIST_ID"

aws cloudfront wait distribution-deployed --id "$DIST_ID"
echo "    deployed"

DOMAIN="$(aws cloudfront get-distribution --id "$DIST_ID" \
    --query 'Distribution.DomainName' --output text)"

echo
echo "CloudFront ready."
echo "  Distribution ID: $DIST_ID"
echo "  URL:             https://$DOMAIN"
echo "  App:             https://$DOMAIN/"
echo "  API:             https://$DOMAIN/api/v1/health"
