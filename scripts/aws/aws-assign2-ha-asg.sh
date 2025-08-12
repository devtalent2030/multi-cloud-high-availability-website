#!/usr/bin/env bash
# AWS Assign2 - VPC + ALB + ASG (2 AZ) with scaling policies
# Region: us-east-1
# Safe to re-run. Requires AWS CLI with credentials for us-east-1.

set -euo pipefail
IFS=$'\n\t'

############################################
# >>> EDIT THESE TWO <<<
############################################
LAST_RAW="nyota"                # your last name for naming
FULL_NAME="Talent Nyota"               # full name shown on the web page

############################################
# Constants / derived
############################################
export AWS_DEFAULT_REGION="us-east-1"
LAST="$(echo "$LAST_RAW" | tr '[:upper:]' '[:lower:]')"
NAME="${LAST}-assign2"             # e.g., ogunrinu-assign2

echo "==> Region: $AWS_DEFAULT_REGION   Name prefix: $NAME"

############################################
# Pick two AZs
############################################
read -r AZ1 AZ2 < <(aws ec2 describe-availability-zones \
  --filters Name=state,Values=available \
  --query 'AvailabilityZones[0:2].ZoneName' --output text)
echo "==> Using AZs: $AZ1  $AZ2"

############################################
# VPC + Subnets + IGW + NAT + Route Tables
############################################
# VPC (10.20.0.0/16)
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=cidr,Values=10.20.0.0/16" \
  --query "Vpcs[0].VpcId" --output text)
if [[ "$VPC_ID" == "None" ]]; then
  VPC_ID=$(aws ec2 create-vpc --cidr-block 10.20.0.0/16 \
    --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=${NAME}-vpc}]" \
    --query "Vpc.VpcId" --output text)
fi
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support    '{"Value":true}' >/dev/null || true
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames '{"Value":true}' >/dev/null || true
aws ec2 create-tags --resources "$VPC_ID" --tags Key=Name,Value="${NAME}-vpc" >/dev/null || true
echo "==> VPC_ID: $VPC_ID"

# Internet Gateway
IGW_ID=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
  --query "InternetGateways[0].InternetGatewayId" --output text)
if [[ "$IGW_ID" == "None" ]]; then
  IGW_ID=$(aws ec2 create-internet-gateway \
    --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=${NAME}-igw}]" \
    --query "InternetGateway.InternetGatewayId" --output text)
  aws ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
fi
aws ec2 create-tags --resources "$IGW_ID" --tags Key=Name,Value="${NAME}-igw" >/dev/null || true
echo "==> IGW_ID: $IGW_ID"

# Subnets
PUB_A=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" "Name=cidr-block,Values=10.20.0.0/24" --query "Subnets[0].SubnetId" --output text)
if [[ "$PUB_A" == "None" ]]; then
  PUB_A=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block 10.20.0.0/24 --availability-zone "$AZ1" \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${NAME}-pub-a}]" --query "Subnet.SubnetId" --output text)
fi
aws ec2 create-tags --resources "$PUB_A" --tags Key=Name,Value="${NAME}-pub-a" >/dev/null || true
aws ec2 modify-subnet-attribute --subnet-id "$PUB_A" --map-public-ip-on-launch >/dev/null || true

PUB_B=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" "Name=cidr-block,Values=10.20.1.0/24" --query "Subnets[0].SubnetId" --output text)
if [[ "$PUB_B" == "None" ]]; then
  PUB_B=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block 10.20.1.0/24 --availability-zone "$AZ2" \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${NAME}-pub-b}]" --query "Subnet.SubnetId" --output text)
fi
aws ec2 create-tags --resources "$PUB_B" --tags Key=Name,Value="${NAME}-pub-b" >/dev/null || true
aws ec2 modify-subnet-attribute --subnet-id "$PUB_B" --map-public-ip-on-launch >/dev/null || true

PRIV_A=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" "Name=cidr-block,Values=10.20.10.0/24" --query "Subnets[0].SubnetId" --output text)
if [[ "$PRIV_A" == "None" ]]; then
  PRIV_A=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block 10.20.10.0/24 --availability-zone "$AZ1" \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${NAME}-priv-a}]" --query "Subnet.SubnetId" --output text)
fi
aws ec2 create-tags --resources "$PRIV_A" --tags Key=Name,Value="${NAME}-priv-a" >/dev/null || true

PRIV_B=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" "Name=cidr-block,Values=10.20.11.0/24" --query "Subnets[0].SubnetId" --output text)
if [[ "$PRIV_B" == "None" ]]; then
  PRIV_B=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block 10.20.11.0/24 --availability-zone "$AZ2" \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${NAME}-priv-b}]" --query "Subnet.SubnetId" --output text)
fi
aws ec2 create-tags --resources "$PRIV_B" --tags Key=Name,Value="${NAME}-priv-b" >/dev/null || true

echo "==> Subnets: PUB_A=$PUB_A  PUB_B=$PUB_B  PRIV_A=$PRIV_A  PRIV_B=$PRIV_B"

# NAT Gateway (one AZ)
EIP_ALLOC=$(aws ec2 describe-addresses --filters "Name=tag:Name,Values=${NAME}-nat-eip" --query "Addresses[0].AllocationId" --output text)
if [[ "$EIP_ALLOC" == "None" ]]; then
  EIP_ALLOC=$(aws ec2 allocate-address --domain vpc \
    --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=${NAME}-nat-eip}]" \
    --query "AllocationId" --output text)
fi

NAT_ID=$(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=${NAME}-nat" \
  --query "NatGateways[0].NatGatewayId" --output text)
if [[ "$NAT_ID" == "None" ]]; then
  NAT_ID=$(aws ec2 create-nat-gateway --subnet-id "$PUB_A" --allocation-id "$EIP_ALLOC" \
    --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=${NAME}-nat}]" \
    --query "NatGateway.NatGatewayId" --output text)
fi
aws ec2 create-tags --resources "$NAT_ID" --tags Key=Name,Value="${NAME}-nat" >/dev/null || true

# Wait for NAT available
while : ; do
  STATE=$(aws ec2 describe-nat-gateways --nat-gateway-ids "$NAT_ID" --query "NatGateways[0].State" --output text)
  [[ "$STATE" == "available" ]] && break
  echo "   NAT state: $STATE ... waiting 10s"; sleep 10
done
echo "==> NAT_ID: $NAT_ID (available)"

# Route tables
RTB_PUB=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" \
  --query "RouteTables[?Routes[?GatewayId=='$IGW_ID']][0].RouteTableId" --output text)
if [[ "$RTB_PUB" == "None" ]]; then
  RTB_PUB=$(aws ec2 create-route-table --vpc-id "$VPC_ID" \
    --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${NAME}-rtb-public}]" \
    --query "RouteTable.RouteTableId" --output text)
  aws ec2 create-route --route-table-id "$RTB_PUB" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID" >/dev/null
  aws ec2 associate-route-table --route-table-id "$RTB_PUB" --subnet-id "$PUB_A" >/dev/null
  aws ec2 associate-route-table --route-table-id "$RTB_PUB" --subnet-id "$PUB_B" >/dev/null
else
  aws ec2 create-tags --resources "$RTB_PUB" --tags Key=Name,Value="${NAME}-rtb-public" >/dev/null || true
fi

RTB_PRIV=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" \
  --query "RouteTables[?Routes[?NatGatewayId=='$NAT_ID']][0].RouteTableId" --output text)
if [[ "$RTB_PRIV" == "None" ]]; then
  RTB_PRIV=$(aws ec2 create-route-table --vpc-id "$VPC_ID" \
    --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${NAME}-rtb-private}]" \
    --query "RouteTable.RouteTableId" --output text)
  aws ec2 create-route --route-table-id "$RTB_PRIV" --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "$NAT_ID" >/dev/null
  aws ec2 associate-route-table --route-table-id "$RTB_PRIV" --subnet-id "$PRIV_A" >/dev/null
  aws ec2 associate-route-table --route-table-id "$RTB_PRIV" --subnet-id "$PRIV_B" >/dev/null
else
  aws ec2 create-tags --resources "$RTB_PRIV" --tags Key=Name,Value="${NAME}-rtb-private" >/dev/null || true
fi
echo "==> RTs: RTB_PUB=$RTB_PUB  RTB_PRIV=$RTB_PRIV"

############################################
# Security Groups
############################################
# ALB SG: allow HTTP :80 from Internet
ALB_SG=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=${NAME}-alb-sg" \
  --query "SecurityGroups[0].GroupId" --output text 2>/dev/null || echo "None")
if [[ "$ALB_SG" == "None" ]]; then
  ALB_SG=$(aws ec2 create-security-group --group-name "${NAME}-alb-sg" --description "${NAME} alb sg" --vpc-id "$VPC_ID" \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${NAME}-alb-sg}]" \
    --query "GroupId" --output text)
fi
aws ec2 authorize-security-group-ingress --group-id "$ALB_SG" --ip-permissions \
  IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges='[{CidrIp=0.0.0.0/0,Description="HTTP from Internet"}]' 2>/dev/null || true

# App SG: allow :80 only from ALB SG
APP_SG=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=${NAME}-app-sg" \
  --query "SecurityGroups[0].GroupId" --output text 2>/dev/null || echo "None")
if [[ "$APP_SG" == "None" ]]; then
  APP_SG=$(aws ec2 create-security-group --group-name "${NAME}-app-sg" --description "${NAME} app sg" --vpc-id "$VPC_ID" \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${NAME}-app-sg}]" \
    --query "GroupId" --output text)
fi
aws ec2 authorize-security-group-ingress --group-id "$APP_SG" --ip-permissions \
  IpProtocol=tcp,FromPort=80,ToPort=80,UserIdGroupPairs="[{GroupId=$ALB_SG,Description=\"HTTP from ALB\"}]" 2>/dev/null || true

echo "==> SGs: ALB_SG=$ALB_SG  APP_SG=$APP_SG"

############################################
# Launch Template (Amazon Linux 2023 + nginx)
############################################
AMI_ID=$(aws ssm get-parameters --names "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-x86_64" \
  --query "Parameters[0].Value" --output text)

USER_DATA_FILE="/tmp/${NAME}-userdata.sh"
cat > "$USER_DATA_FILE" <<EOF
#!/bin/bash
set -euxo pipefail
dnf -y update
dnf -y install nginx
systemctl enable --now nginx
cat >/usr/share/nginx/html/index.html <<HTML
<!DOCTYPE html>
<html><head><title>\$(hostname)</title></head>
<body style="font-family:sans-serif">
  <h1 style="color:#4f46e5;">${FULL_NAME} — AWS ASG behind ALB</h1>
  <p>Served by: \$(hostname)</p>
  <p>AZ: \$(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone)</p>
  <p>Time: \$(date -Is)</p>
</body></html>
HTML
EOF
USER_DATA_B64=$(base64 -w0 "$USER_DATA_FILE")

LT_NAME="${NAME}-lt"
LT_ID=$(aws ec2 describe-launch-templates --launch-template-names "$LT_NAME" \
  --query "LaunchTemplates[0].LaunchTemplateId" --output text 2>/dev/null || echo "None")
if [[ "$LT_ID" == "None" ]]; then
  LT_ID=$(aws ec2 create-launch-template \
    --launch-template-name "$LT_NAME" --version-description "v1" \
    --launch-template-data "{
      \"ImageId\":\"$AMI_ID\",
      \"InstanceType\":\"t3.micro\",
      \"SecurityGroupIds\":[\"$APP_SG\"],
      \"UserData\":\"$USER_DATA_B64\",
      \"TagSpecifications\":[
        {\"ResourceType\":\"instance\",\"Tags\":[{\"Key\":\"Name\",\"Value\":\"$NAME-ec2\"}]},
        {\"ResourceType\":\"volume\",\"Tags\":[{\"Key\":\"Name\",\"Value\":\"$NAME-ec2\"}]}
      ]
    }" --query "LaunchTemplate.LaunchTemplateId" --output text)
  LT_VER="1"
else
  LT_VER=$(aws ec2 create-launch-template-version \
    --launch-template-id "$LT_ID" --version-description "nginx" \
    --launch-template-data "{
      \"ImageId\":\"$AMI_ID\",
      \"InstanceType\":\"t3.micro\",
      \"SecurityGroupIds\":[\"$APP_SG\"],
      \"UserData\":\"$USER_DATA_B64\",
      \"TagSpecifications\":[
        {\"ResourceType\":\"instance\",\"Tags\":[{\"Key\":\"Name\",\"Value\":\"$NAME-ec2\"}]},
        {\"ResourceType\":\"volume\",\"Tags\":[{\"Key\":\"Name\",\"Value\":\"$NAME-ec2\"}]}
      ]
    }" --query "LaunchTemplateVersion.VersionNumber" --output text)
fi
aws ec2 modify-launch-template --launch-template-id "$LT_ID" --default-version "$LT_VER" >/dev/null
echo "==> LT: $LT_ID  version=$LT_VER"

############################################
# Target Group + ALB + Listener
############################################
TG_NAME="${NAME}-tg"
TG_ARN=$(aws elbv2 describe-target-groups --names "$TG_NAME" --query "TargetGroups[0].TargetGroupArn" --output text 2>/dev/null || echo "None")
if [[ "$TG_ARN" == "None" ]]; then
  TG_ARN=$(aws elbv2 create-target-group --name "$TG_NAME" --protocol HTTP --port 80 \
    --vpc-id "$VPC_ID" --target-type instance \
    --health-check-protocol HTTP --health-check-path "/index.html" \
    --health-check-port "traffic-port" --matcher HttpCode=200-399 \
    --query "TargetGroups[0].TargetGroupArn" --output text)
fi
echo "==> TG_ARN: $TG_ARN"

ALB_NAME="${NAME}-alb"
ALB_ARN=$(aws elbv2 describe-load-balancers --names "$ALB_NAME" --query "LoadBalancers[0].LoadBalancerArn" --output text 2>/dev/null || echo "None")
if [[ "$ALB_ARN" == "None" ]]; then
  ALB_ARN=$(aws elbv2 create-load-balancer --name "$ALB_NAME" --type application --scheme internet-facing \
    --subnets "$PUB_A" "$PUB_B" --security-groups "$ALB_SG" \
    --query "LoadBalancers[0].LoadBalancerArn" --output text)
fi
ALB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" --query "LoadBalancers[0].DNSName" --output text)
echo "==> ALB_DNS: http://$ALB_DNS"

LSN_ARN=$(aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" \
  --query "Listeners[?Port==\`80\`].ListenerArn" --output text)
if [[ -z "${LSN_ARN:-}" ]]; then
  LSN_ARN=$(aws elbv2 create-listener --load-balancer-arn "$ALB_ARN" --protocol HTTP --port 80 \
    --default-actions "Type=forward,TargetGroupArn=$TG_ARN" --query "Listeners[0].ListenerArn" --output text)
fi

############################################
# Auto Scaling Group + Policies
############################################
ASG_NAME="${NAME}-asg"
ASG_EXISTS=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG_NAME" \
  --query "AutoScalingGroups[0].AutoScalingGroupName" --output text 2>/dev/null || echo "None")

if [[ "$ASG_EXISTS" == "None" ]]; then
  aws autoscaling create-auto-scaling-group \
    --auto-scaling-group-name "$ASG_NAME" \
    --min-size 2 --max-size 4 --desired-capacity 2 \
    --vpc-zone-identifier "${PRIV_A},${PRIV_B}" \
    --target-group-arns "$TG_ARN" \
    --launch-template "LaunchTemplateName=${NAME}-lt,Version=$LT_VER" \
    --health-check-type "ELB" --health-check-grace-period 90 \
    --tags "ResourceId=$ASG_NAME,ResourceType=auto-scaling-group,Key=Name,Value=${NAME}-asg,PropagateAtLaunch=true"
else
  aws autoscaling update-auto-scaling-group \
    --auto-scaling-group-name "$ASG_NAME" \
    --launch-template "LaunchTemplateName=${NAME}-lt,Version=$LT_VER" \
    --min-size 2 --max-size 4 --desired-capacity 2 >/dev/null
  aws autoscaling attach-load-balancer-target-groups \
    --auto-scaling-group-name "$ASG_NAME" --target-group-arns "$TG_ARN" >/dev/null || true
  aws autoscaling start-instance-refresh --auto-scaling-group-name "$ASG_NAME" \
    --strategy Rolling --preferences MinHealthyPercentage=50,InstanceWarmup=90 >/dev/null || true
fi
echo "==> ASG: $ASG_NAME (2 desired)"

# Scaling policies
POLICY_ARN_OUT=$(aws autoscaling put-scaling-policy \
  --auto-scaling-group-name "$ASG_NAME" --policy-name "${NAME}-scale-out" \
  --adjustment-type "ChangeInCapacity" --scaling-adjustment 1 --cooldown 60 \
  --policy-type "SimpleScaling" --query "PolicyARN" --output text)

aws cloudwatch put-metric-alarm \
  --alarm-name "${NAME}-cpu-scale-out" \
  --metric-name CPUUtilization --namespace AWS/EC2 --statistic Average \
  --period 60 --evaluation-periods 1 --threshold 60 \
  --comparison-operator GreaterThanOrEqualToThreshold \
  --dimensions "Name=AutoScalingGroupName,Value=$ASG_NAME" \
  --alarm-actions "$POLICY_ARN_OUT" >/dev/null

POLICY_ARN_IN=$(aws autoscaling put-scaling-policy \
  --auto-scaling-group-name "$ASG_NAME" --policy-name "${NAME}-scale-in" \
  --adjustment-type "ChangeInCapacity" --scaling-adjustment -1 --cooldown 120 \
  --policy-type "SimpleScaling" --query "PolicyARN" --output text)

aws cloudwatch put-metric-alarm \
  --alarm-name "${NAME}-cpu-scale-in" \
  --metric-name CPUUtilization --namespace AWS/EC2 --statistic Average \
  --period 60 --evaluation-periods 5 --threshold 30 \
  --comparison-operator LessThanOrEqualToThreshold \
  --dimensions "Name=AutoScalingGroupName,Value=$ASG_NAME" \
  --alarm-actions "$POLICY_ARN_IN" >/dev/null

############################################
# Optional wait for healthy targets (fast)
############################################
echo "==> Waiting for targets to become healthy (up to ~2 min)..."
DEADLINE=$((SECONDS+180))
while : ; do
  STATES=$(aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
    --query 'TargetHealthDescriptions[].TargetHealth.State' --output text || echo "")
  if echo "$STATES" | grep -q "healthy"; then
    echo "    Target states: $STATES"
    break
  fi
  [[ $SECONDS -gt $DEADLINE ]] && { echo "    Still not healthy; check console."; break; }
  sleep 10
done

############################################
# Summary
############################################
echo
echo "===================== SUMMARY ====================="
echo "VPC        : $VPC_ID (10.20.0.0/16)"
echo "Subnets    : PUB_A=$PUB_A  PUB_B=$PUB_B  PRIV_A=$PRIV_A  PRIV_B=$PRIV_B"
echo "IGW / NAT  : IGW_ID=$IGW_ID  NAT_ID=$NAT_ID"
echo "RTs        : RTB_PUB=$RTB_PUB (-> IGW)  RTB_PRIV=$RTB_PRIV (-> NAT)"
echo "SGs        : ALB_SG=$ALB_SG  APP_SG=$APP_SG"
echo "LT         : $LT_ID (version $LT_VER)"
echo "TG / ALB   : TG_ARN=$TG_ARN"
echo "ALB URL    : http://$ALB_DNS"
echo "ASG        : $ASG_NAME  (min=2, desired=2, max=4)"
echo "Scaling    : Policies + CloudWatch alarms created"
echo "===================================================="
