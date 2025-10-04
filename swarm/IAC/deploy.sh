#!/usr/bin/env bash
set -euo pipefail

REGION="eu-west-1"
STACK_NAME="swarm-stack"
TEMPLATE="swarm-stack.yaml"

echo "Docker Swarm Scalable Infrastructure Deployment"

echo "[1/8] Fetching default VPC in ${REGION}..."
VPC_ID=$(aws ec2 describe-vpcs --region "$REGION" --filters "Name=isDefault,Values=true" \
  --query "Vpcs[0].VpcId" --output text)
if [[ -z "$VPC_ID" || "$VPC_ID" == "None" ]]; then
  echo "ERROR: No default VPC found in $REGION"
  exit 1
fi
echo "    Default VPC: $VPC_ID"

echo "[2/8] Fetching default public subnets..."
mapfile -t SUBNET_LINES < <(
  aws ec2 describe-subnets --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=map-public-ip-on-launch,Values=true" \
    --query "sort_by(Subnets,&AvailabilityZone)[].[SubnetId,AvailabilityZone]" \
    --output text
)
if (( ${#SUBNET_LINES[@]} < 3 )); then
  echo "ERROR: Need >=3 public subnets; found ${#SUBNET_LINES[@]}"
  printf '  %s\n' "${SUBNET_LINES[@]}"
  exit 1
fi

SUBNET_A=$(echo "${SUBNET_LINES[0]}" | awk '{print $1}')
AZ_A=$(echo "${SUBNET_LINES[0]}" | awk '{print $2}')
SUBNET_B=$(echo "${SUBNET_LINES[1]}" | awk '{print $1}')
AZ_B=$(echo "${SUBNET_LINES[1]}" | awk '{print $2}')
SUBNET_C=$(echo "${SUBNET_LINES[2]}" | awk '{print $1}')
AZ_C=$(echo "${SUBNET_LINES[2]}" | awk '{print $2}')

for S in SUBNET_A SUBNET_B SUBNET_C; do
  VAL="${!S}"
  if [[ ! "$VAL" =~ ^subnet- ]]; then
    echo "ERROR: Parsed $S='$VAL' which is not a subnet ID."
    printf '  %s\n' "${SUBNET_LINES[@]}"
    exit 1
  fi
done

echo "    Using subnets:"
echo "      A: $SUBNET_A ($AZ_A)"
echo "      B: $SUBNET_B ($AZ_B)"
echo "      C: $SUBNET_C ($AZ_C)"

echo "[3/8] EC2 Key Pair"
read -rp "Enter existing EC2 Key Pair name (leave blank to auto-create): " KEY_NAME
if [[ -z "$KEY_NAME" ]]; then
  KP_BASE="swarm-key"
  TS=$(date +%Y%m%d-%H%M%S)
  KEY_NAME="${KP_BASE}-${TS}"
  echo "    Creating key pair: $KEY_NAME"
  aws ec2 create-key-pair --region "$REGION" --key-name "$KEY_NAME" \
    --query "KeyMaterial" --output text > "${KEY_NAME}.pem"
  chmod 600 "${KEY_NAME}.pem"
  echo "    Saved private key: ${KEY_NAME}.pem"
else
  echo "    Using existing key pair: $KEY_NAME"
fi

echo "[4/8] Cluster size & instance type"
read -rp "Desired cluster size (default 3): " DESIRED
DESIRED="${DESIRED:-3}"
if ! [[ "$DESIRED" =~ ^[0-9]+$ ]] || (( DESIRED < 1 )); then
  echo "ERROR: Invalid desired capacity."
  exit 1
fi
read -rp "Max cluster size (default 6): " MAXSIZE
MAXSIZE="${MAXSIZE:-6}"
if ! [[ "$MAXSIZE" =~ ^[0-9]+$ ]] || (( MAXSIZE < DESIRED )); then
  echo "ERROR: Invalid max size (must be >= desired)."
  exit 1
fi
read -rp "Instance type (default t3.small): " ITYPE
ITYPE="${ITYPE:-t3.small}"

echo "[5/8] Demo service deployment"
read -rp "Launch demo Docker stack with nginx + visualizer? (true/false) [true]: " DEMO
DEMO="${DEMO:-true}"
if [[ "$DEMO" != "true" && "$DEMO" != "false" ]]; then
  echo "ERROR: Must be 'true' or 'false'"
  exit 1
fi

echo "[6/8] SSH ingress CIDR (default 0.0.0.0/0; set to something restrictive or 127.0.0.1/32 if only SSM):"
read -rp "SSH CIDR [0.0.0.0/0]: " SSHCIDR
SSHCIDR="${SSHCIDR:-0.0.0.0/0}"

echo "[7/8] Validating template presence..."
if [[ ! -f "$TEMPLATE" ]]; then
  echo "ERROR: Template $TEMPLATE not found"
  exit 1
fi

echo "[8/8] Deploying stack $STACK_NAME ..."
set +e
aws cloudformation deploy \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --template-file "$TEMPLATE" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    VpcId="$VPC_ID" \
    SubnetA="$SUBNET_A" \
    SubnetB="$SUBNET_B" \
    SubnetC="$SUBNET_C" \
    KeyName="$KEY_NAME" \
    DesiredCapacity="$DESIRED" \
    MaxSize="$MAXSIZE" \
    InstanceType="$ITYPE" \
    LaunchDemoService="$DEMO" \
    SSHIngressCidr="$SSHCIDR"
DEPLOY_RC=$?
set -e

if (( DEPLOY_RC != 0 )); then
  echo "Deployment failed. Recent events:"
  aws cloudformation describe-stack-events --stack-name "$STACK_NAME" --region "$REGION" \
    --query "StackEvents[0:15].[Timestamp,ResourceStatus,LogicalResourceId,ResourceStatusReason]" \
    --output table || true
  exit $DEPLOY_RC
fi

echo "Waiting for stack completion..."
STATUS=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" \
  --query "Stacks[0].StackStatus" --output text)
if [[ "$STATUS" == "CREATE_IN_PROGRESS" ]]; then
  aws cloudformation wait stack-create-complete --stack-name "$STACK_NAME" --region "$REGION"
elif [[ "$STATUS" == "UPDATE_IN_PROGRESS" ]]; then
  aws cloudformation wait stack-update-complete --stack-name "$STACK_NAME" --region "$REGION"
else
  echo "    Stack status: $STATUS"
fi

echo "Outputs:"
aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --query "Stacks[0].Outputs" \
  --output table

ALB_DNS=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='LoadBalancerDNSName'].OutputValue" \
  --output text)

echo
echo "Access URLs:"
echo "Nginx Service: http://$ALB_DNS"
if [[ "$DEMO" == "true" ]]; then
  echo "Visualizer UI: http://$ALB_DNS:8080"
fi
echo
echo "Management Commands (run on manager via SSM):"
echo "aws ssm start-session --region $REGION --target <instance-id>"
echo "docker node ls"
echo "docker stack ls"
echo "docker service ls"
echo "docker service scale myapp_web=5"
echo
echo "Cleanup:"
echo "aws cloudformation delete-stack --region $REGION --stack-name $STACK_NAME"
echo
echo "Docker Swarm cluster deployment finished."