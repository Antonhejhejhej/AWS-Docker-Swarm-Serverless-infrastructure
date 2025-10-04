#!/usr/bin/env bash
set -euo pipefail

REGION="eu-west-1"
STACK_NAME="serverless-demo"
TEMPLATE="serverless.yaml"
BUCKET="bucket-serverless-demo-$(date +%s)"
TABLE="SimpleTable"

echo "Serverless Demo Infrastructure Deployment (with CloudFront)"

echo "[1/5] Creating unique S3 bucket: $BUCKET"
echo "[2/5] DynamoDB table: $TABLE"
echo "[3/5] Validating template presence..."
if [[ ! -f "$TEMPLATE" ]]; then
  echo "ERROR: Template $TEMPLATE not found"
  exit 1
fi

echo "[4/5] Deploying stack $STACK_NAME ..."
set +e
aws cloudformation deploy \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --template-file "$TEMPLATE" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    BucketName="$BUCKET" \
    DynamoTableName="$TABLE"
DEPLOY_RC=$?
set -e

if (( DEPLOY_RC != 0 )); then
  echo "Deployment failed. Recent events:"
  aws cloudformation describe-stack-events --stack-name "$STACK_NAME" --region "$REGION" \
    --query "StackEvents[0:10].[Timestamp,ResourceStatus,LogicalResourceId,ResourceStatusReason]" \
    --output table || true
  exit $DEPLOY_RC
fi

echo "[5/5] Seeding DynamoDB with one row..."
aws dynamodb put-item \
  --table-name "$TABLE" \
  --region "$REGION" \
  --item '{"id": {"S": "demo"}, "value": {"S": "Janne Schaffer!"}}'

echo "Uploading index.html to S3 (CloudFront will serve this)..."
aws s3 cp index.html s3://$BUCKET/index.html

echo "Stack deployed. Waiting for CloudFront Distribution to deploy (this can take several minutes)..."

CF_URL=$(aws cloudformation describe-stacks --stack-name $STACK_NAME --region $REGION \
  --query "Stacks[0].Outputs[?OutputKey=='CloudFrontURL'].OutputValue" --output text)
S3_URL=$(aws cloudformation describe-stacks --stack-name $STACK_NAME --region $REGION \
  --query "Stacks[0].Outputs[?OutputKey=='WebsiteURL'].OutputValue" --output text)
API_URL=$(aws cloudformation describe-stacks --stack-name $STACK_NAME --region $REGION \
  --query "Stacks[0].Outputs[?OutputKey=='ApiEndpoint'].OutputValue" --output text)

echo "S3 Website URL: $S3_URL"
echo "CloudFront URL: $CF_URL"
echo "API endpoint (for client.js): $API_URL"

echo ""
echo "Next step: Update client.js with the API endpoint above and upload it to S3:"
echo "aws s3 cp client.js s3://$BUCKET/client.js"
echo ""
echo "Then visit the CloudFront URL to test the frontend UI."