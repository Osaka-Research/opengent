#!/usr/bin/env bash
# opengent — provision an Auto Scaling Group of relay-only nodes (standalone
# from node 1's fixed gateway box; run this from your own machine with AWS
# CLI + credentials for the target account, NOT on any server).
#
# Prereqs: node 1 must already be set up (setup.sh) so you have its
# FRP_TOKEN and DATABASE_URL. Relay nodes never touch Caddy/Postgres/
# register-api directly — they self-register a row into relay_nodes on
# boot and deregister (mark inactive) on scale-in, via relay-node-userdata.sh.
#
# Usage:
#   OPENGENT_FRP_TOKEN=<from node 1 setup.sh output> \
#   OPENGENT_DATABASE_URL=<from node 1 setup.sh output, reachable from the VPC> \
#   OPENGENT_GATEWAY_SG=<node 1's security group id, so relay nodes can allow it in> \
#   OPENGENT_VPC_ID=<vpc id> \
#   OPENGENT_SUBNET_IDS=<comma-separated subnet ids, one or more AZs> \
#   ./autoscale-relay-nodes.sh
#
# Creates (all tagged Project=opengent, nothing shared with any other
# project/box): IAM role+profile, security group, launch template, ASG
# with a CPU target-tracking policy, and an EC2_INSTANCE_TERMINATING
# lifecycle hook. Safe to re-run — skips resources that already exist.

set -euo pipefail

FRP_TOKEN="${OPENGENT_FRP_TOKEN:?set OPENGENT_FRP_TOKEN (from node 1 setup.sh)}"
DATABASE_URL="${OPENGENT_DATABASE_URL:?set OPENGENT_DATABASE_URL (from node 1 setup.sh, must be reachable from the VPC)}"
GATEWAY_SG="${OPENGENT_GATEWAY_SG:?set OPENGENT_GATEWAY_SG (node 1 gateway security group id)}"
VPC_ID="${OPENGENT_VPC_ID:?set OPENGENT_VPC_ID}"
SUBNET_IDS="${OPENGENT_SUBNET_IDS:?set OPENGENT_SUBNET_IDS (comma-separated)}"
REGION="${OPENGENT_REGION:-ap-south-1}"
INSTANCE_TYPE="${OPENGENT_INSTANCE_TYPE:-t4g.micro}"
MIN_SIZE="${OPENGENT_ASG_MIN:-0}"
MAX_SIZE="${OPENGENT_ASG_MAX:-5}"
DESIRED="${OPENGENT_ASG_DESIRED:-1}"
AMI_ID="${OPENGENT_AMI_ID:-}"
ASG_NAME="opengent-relay-nodes"
HOOK_NAME="opengent-relay-terminating"
ROLE_NAME="opengent-relay-node"
SG_NAME="opengent-relay-sg"
LT_NAME="opengent-relay-lt"

if [ -z "$AMI_ID" ]; then
  AMI_ID="$(aws ec2 describe-images --region "$REGION" \
    --owners 099720109477 \
    --filters "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-*" \
              "Name=state,Values=available" \
    --query "sort_by(Images,&CreationDate)[-1].ImageId" --output text)"
fi
echo "==> using AMI $AMI_ID"

echo "==> SSM parameters"
aws ssm put-parameter --region "$REGION" --name /opengent/frp_token --type SecureString --value "$FRP_TOKEN" --overwrite >/dev/null
aws ssm put-parameter --region "$REGION" --name /opengent/database_url --type SecureString --value "$DATABASE_URL" --overwrite >/dev/null

echo "==> IAM role"
if ! aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{"Effect": "Allow", "Principal": {"Service": "ec2.amazonaws.com"}, "Action": "sts:AssumeRole"}]
  }' >/dev/null
  aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name opengent-relay-node-policy --policy-document '{
    "Version": "2012-10-17",
    "Statement": [
      {"Effect": "Allow", "Action": ["ssm:GetParameter"], "Resource": [
        "arn:aws:ssm:*:*:parameter/opengent/frp_token",
        "arn:aws:ssm:*:*:parameter/opengent/database_url"
      ]},
      {"Effect": "Allow", "Action": [
        "autoscaling:CompleteLifecycleAction",
        "autoscaling:RecordLifecycleActionHeartbeat"
      ], "Resource": "*"}
    ]
  }' >/dev/null
  aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
  aws iam create-instance-profile --instance-profile-name "$ROLE_NAME" >/dev/null
  aws iam add-role-to-instance-profile --instance-profile-name "$ROLE_NAME" --role-name "$ROLE_NAME"
  echo "    waiting for instance profile to propagate..."
  sleep 10
else
  echo "    role already exists, skipping"
fi

echo "==> security group"
SG_ID="$(aws ec2 describe-security-groups --region "$REGION" --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$VPC_ID" --query "SecurityGroups[0].GroupId" --output text)"
if [ "$SG_ID" = "None" ] || [ -z "$SG_ID" ]; then
  SG_ID="$(aws ec2 create-security-group --region "$REGION" --group-name "$SG_NAME" --description "opengent relay nodes (standalone)" --vpc-id "$VPC_ID" --query GroupId --output text)"
  aws ec2 create-tags --region "$REGION" --resources "$SG_ID" --tags Key=Project,Value=opengent
  # frpc control channel: public, any client
  aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SG_ID" --protocol tcp --port 7000 --cidr 0.0.0.0/0 >/dev/null
  # frps API + tunneled port range: gateway (node 1) only, over private network
  aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SG_ID" --protocol tcp --port 7500 --source-group "$GATEWAY_SG" >/dev/null
  aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SG_ID" --protocol tcp --port 21000-21999 --source-group "$GATEWAY_SG" >/dev/null
else
  echo "    security group already exists, skipping rules"
fi

echo "==> launch template"
USER_DATA_B64="$(base64 -w0 "$(dirname "$0")/relay-node-userdata.sh")"
LT_DATA=$(cat <<JSON
{
  "ImageId": "$AMI_ID",
  "InstanceType": "$INSTANCE_TYPE",
  "IamInstanceProfile": {"Name": "$ROLE_NAME"},
  "SecurityGroupIds": ["$SG_ID"],
  "UserData": "$USER_DATA_B64",
  "TagSpecifications": [{"ResourceType": "instance", "Tags": [{"Key": "Project", "Value": "opengent"}, {"Key": "Name", "Value": "opengent-relay-node"}]}],
  "MetadataOptions": {"HttpTokens": "required", "HttpEndpoint": "enabled"}
}
JSON
)
if aws ec2 describe-launch-templates --region "$REGION" --launch-template-names "$LT_NAME" >/dev/null 2>&1; then
  aws ec2 create-launch-template-version --region "$REGION" --launch-template-name "$LT_NAME" --launch-template-data "$LT_DATA" >/dev/null
  aws ec2 modify-launch-template --region "$REGION" --launch-template-name "$LT_NAME" --default-version '$Latest' >/dev/null
  echo "    new launch template version published"
else
  aws ec2 create-launch-template --region "$REGION" --launch-template-name "$LT_NAME" --launch-template-data "$LT_DATA" \
    --tag-specifications "ResourceType=launch-template,Tags=[{Key=Project,Value=opengent}]" >/dev/null
fi

echo "==> auto scaling group"
ASG_COUNT="$(aws autoscaling describe-auto-scaling-groups --region "$REGION" --auto-scaling-group-names "$ASG_NAME" --query "length(AutoScalingGroups)" --output text)"
if [ "$ASG_COUNT" = "0" ]; then
  aws autoscaling create-auto-scaling-group --region "$REGION" \
    --auto-scaling-group-name "$ASG_NAME" \
    --launch-template "LaunchTemplateName=$LT_NAME,Version=\$Latest" \
    --min-size "$MIN_SIZE" --max-size "$MAX_SIZE" --desired-capacity "$DESIRED" \
    --vpc-zone-identifier "$SUBNET_IDS" \
    --tags "Key=Project,Value=opengent,PropagateAtLaunch=true"

  aws autoscaling put-scaling-policy --region "$REGION" \
    --auto-scaling-group-name "$ASG_NAME" --policy-name opengent-relay-cpu-target \
    --policy-type TargetTrackingScaling \
    --target-tracking-configuration '{"PredefinedMetricSpecification": {"PredefinedMetricType": "ASGAverageCPUUtilization"}, "TargetValue": 50.0}' >/dev/null

  aws autoscaling put-lifecycle-hook --region "$REGION" \
    --lifecycle-hook-name "$HOOK_NAME" --auto-scaling-group-name "$ASG_NAME" \
    --lifecycle-transition "autoscaling:EC2_INSTANCE_TERMINATING" \
    --heartbeat-timeout 180 --default-result CONTINUE >/dev/null
else
  echo "    ASG already exists, skipping (edit in console/CLI directly, or delete it first to re-run this)"
fi

echo "==> done. Relay nodes will register into relay_nodes automatically; register-api picks them up on next signup, no restart needed."
