#!/usr/bin/env bash
# opengent — relay-node cloud-init (Auto Scaling Group launch template user-data).
#
# Runs on first boot of an ASG-managed relay node (Debian/Ubuntu). Unlike
# add-relay-node.sh (run by hand on a one-off box), this script:
#   - fetches OPENGENT_FRP_TOKEN and DATABASE_URL from SSM Parameter Store
#     (via the instance's IAM role — no secrets in the launch template)
#   - self-registers into relay_nodes, keeping the row id for cleanup
#   - installs a lifecycle-watcher that marks itself inactive in Postgres
#     and completes the ASG termination lifecycle hook on scale-in
#
# Expects the instance profile to allow: ssm:GetParameter on
# /opengent/frp_token and /opengent/database_url, and
# autoscaling:CompleteLifecycleAction + autoscaling:RecordLifecycleActionHeartbeat.
# ASG name / lifecycle hook name below must match what
# autoscale-relay-nodes.sh created.

set -euo pipefail

ASG_NAME="opengent-relay-nodes"
HOOK_NAME="opengent-relay-terminating"
FRP_VERSION="0.68.0"
PORT_MIN="${OPENGENT_PORT_MIN:-21000}"
PORT_MAX="${OPENGENT_PORT_MAX:-21999}"
INSTALL_DIR="/opt/opengent"
REPO_URL="https://github.com/Osaka-Research/opengent"

mkdir -p "$INSTALL_DIR"
apt-get update -qq
apt-get install -y -qq curl git postgresql-client awscli jq

imds_token="$(curl -sX PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 21600')"
imds() { curl -s -H "X-aws-ec2-metadata-token: $imds_token" "http://169.254.169.254/latest/meta-data/$1"; }

INSTANCE_ID="$(imds instance-id)"
REGION="$(imds placement/region)"
PUBLIC_HOST="$(imds public-ipv4)"
INTERNAL_HOST="$(imds local-ipv4)"

FRP_TOKEN="$(aws ssm get-parameter --name /opengent/frp_token --with-decryption --region "$REGION" --query Parameter.Value --output text)"
DATABASE_URL="$(aws ssm get-parameter --name /opengent/database_url --with-decryption --region "$REGION" --query Parameter.Value --output text)"
echo -n "$DATABASE_URL" > "$INSTALL_DIR/database_url"
chmod 600 "$INSTALL_DIR/database_url"

echo "==> installing frps ${FRP_VERSION}"
ARCH="$(uname -m)"; case "$ARCH" in x86_64) FA=amd64;; aarch64) FA=arm64;; *) echo "unsupported arch: $ARCH" >&2; exit 1;; esac
curl -sL "https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_${FRP_VERSION}_linux_${FA}.tar.gz" \
  | tar xz -C "$INSTALL_DIR" --strip-components=1 "frp_${FRP_VERSION}_linux_${FA}/frps"

echo "==> fetching frps.toml template"
git clone --depth 1 "$REPO_URL" "$INSTALL_DIR/src"
FRPS_API_PW="$(openssl rand -hex 20)"
install -m 600 "$INSTALL_DIR/src/server/frps.toml" "$INSTALL_DIR/frps.toml"
sed -i "s/CHANGE_ME_SHARED_SECRET/${FRP_TOKEN}/" "$INSTALL_DIR/frps.toml"
sed -i "s/CHANGE_ME_API_PW/${FRPS_API_PW}/" "$INSTALL_DIR/frps.toml"
sed -i "s/{ start = 21000, end = 21999 }/{ start = ${PORT_MIN}, end = ${PORT_MAX} }/" "$INSTALL_DIR/frps.toml"
sed -i "s/^proxyBindAddr = \"127.0.0.1\"/proxyBindAddr = \"${INTERNAL_HOST}\"/" "$INSTALL_DIR/frps.toml"
sed -i "s/^webServer.addr = \"127.0.0.1\"/webServer.addr = \"${INTERNAL_HOST}\"/" "$INSTALL_DIR/frps.toml"

cat > /etc/systemd/system/opengent-frps.service <<EOF
[Unit]
Description=opengent frp server
After=network.target
[Service]
ExecStart=$INSTALL_DIR/frps -c $INSTALL_DIR/frps.toml
Restart=always
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now opengent-frps

echo "==> registering with fleet"
RELAY_ID="$(psql "$DATABASE_URL" -tA -c "
INSERT INTO relay_nodes (host, internal_host, port_min, port_max, frps_api_addr, frps_api_user, frps_api_pass, active)
VALUES ('${PUBLIC_HOST}', '${INTERNAL_HOST}', ${PORT_MIN}, ${PORT_MAX}, '${INTERNAL_HOST}:7500', 'opengent', '${FRPS_API_PW}', true)
RETURNING id;
")"
echo -n "$RELAY_ID" > "$INSTALL_DIR/relay_node_id"
echo "==> registered as relay_nodes.id=${RELAY_ID}"

cat > "$INSTALL_DIR/lifecycle-watch.sh" <<'WATCH'
#!/usr/bin/env bash
set -euo pipefail
INSTALL_DIR="/opt/opengent"
ASG_NAME="opengent-relay-nodes"
HOOK_NAME="opengent-relay-terminating"

imds_token="$(curl -sX PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 21600')"
imds() { curl -s -H "X-aws-ec2-metadata-token: $imds_token" "http://169.254.169.254/latest/meta-data/$1"; }
INSTANCE_ID="$(imds instance-id)"
REGION="$(imds placement/region)"

while true; do
  STATE="$(imds autoscaling/target-lifecycle-state 2>/dev/null || true)"
  if [ "$STATE" = "Terminated" ]; then
    RELAY_ID="$(cat "$INSTALL_DIR/relay_node_id")"
    DATABASE_URL="$(cat "$INSTALL_DIR/database_url")"
    psql "$DATABASE_URL" -c "UPDATE relay_nodes SET active=false WHERE id=${RELAY_ID};" || true
    aws autoscaling complete-lifecycle-action \
      --lifecycle-action-result CONTINUE \
      --instance-id "$INSTANCE_ID" \
      --lifecycle-hook-name "$HOOK_NAME" \
      --auto-scaling-group-name "$ASG_NAME" \
      --region "$REGION" || true
    break
  fi
  sleep 5
done
WATCH
chmod +x "$INSTALL_DIR/lifecycle-watch.sh"

cat > /etc/systemd/system/opengent-lifecycle-watch.service <<EOF
[Unit]
Description=opengent ASG termination watcher
After=opengent-frps.service
[Service]
ExecStart=$INSTALL_DIR/lifecycle-watch.sh
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now opengent-lifecycle-watch

echo "==> relay node ${INSTANCE_ID} ready (relay_nodes.id=${RELAY_ID}, host=${PUBLIC_HOST})"
