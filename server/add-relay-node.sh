#!/usr/bin/env bash
# opengent — add an additional relay node (Debian/Ubuntu).
#
# Run this ON THE NEW BOX. It installs only frps (no Caddy, no Postgres, no
# register-api/gateway — those stay centralized on node 1). It needs:
#   - this box's PUBLIC IP/host (for frpc control connections, port 7000)
#   - this box's PRIVATE-network IP (VPC/private LAN it shares with node 1's
#     gateway — tunneled ports bind here, never to the public interface)
#   - a free port range not already used by another node
#
# Usage:
#   sudo OPENGENT_PUBLIC_HOST=node2.example.com \
#        OPENGENT_INTERNAL_HOST=10.0.0.5 \
#        OPENGENT_FRP_TOKEN=<same token every client uses> \
#        ./add-relay-node.sh [port_min] [port_max]
#
# After it finishes, it prints the SQL to register this node — run that
# against the central Postgres (from node 1, or wherever DATABASE_URL is
# reachable) to make register-api start assigning slugs to it.

set -euo pipefail

PUBLIC_HOST="${OPENGENT_PUBLIC_HOST:?set OPENGENT_PUBLIC_HOST=this-node's-public-host}"
INTERNAL_HOST="${OPENGENT_INTERNAL_HOST:?set OPENGENT_INTERNAL_HOST=this-node's-private-network-IP}"
FRP_TOKEN="${OPENGENT_FRP_TOKEN:?set OPENGENT_FRP_TOKEN=<the shared token clients already use>}"
PORT_MIN="${1:-21000}"
PORT_MAX="${2:-21999}"
FRP_VERSION="0.68.0"
FRPS_API_PW="$(openssl rand -hex 20)"
INSTALL_DIR="/opt/opengent"

echo "==> installing frps ${FRP_VERSION}"
ARCH="$(uname -m)"; case "$ARCH" in x86_64) FA=amd64;; aarch64) FA=arm64;; *) echo "unsupported arch: $ARCH" >&2; exit 1;; esac
mkdir -p "$INSTALL_DIR"
curl -sL "https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_${FRP_VERSION}_linux_${FA}.tar.gz" \
  | tar xz -C "$INSTALL_DIR" --strip-components=1 "frp_${FRP_VERSION}_linux_${FA}/frps"

echo "==> writing frps.toml"
install -m 600 "$(dirname "$0")/frps.toml" "$INSTALL_DIR/frps.toml"
sed -i "s/CHANGE_ME_SHARED_SECRET/${FRP_TOKEN}/" "$INSTALL_DIR/frps.toml"
sed -i "s/CHANGE_ME_API_PW/${FRPS_API_PW}/" "$INSTALL_DIR/frps.toml"
sed -i "s/{ start = 21000, end = 21999 }/{ start = ${PORT_MIN}, end = ${PORT_MAX} }/" "$INSTALL_DIR/frps.toml"
sed -i "s/^proxyBindAddr = \"127.0.0.1\"/proxyBindAddr = \"${INTERNAL_HOST}\"/" "$INSTALL_DIR/frps.toml"
# frps webServer API also needs to answer on the private IP — node 1's
# sweep job polls it from off-box now, unlike the co-located node-1 case.
sed -i "s/^webServer.addr = \"127.0.0.1\"/webServer.addr = \"${INTERNAL_HOST}\"/" "$INSTALL_DIR/frps.toml"

echo "==> systemd unit"
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

cat <<EOF

==> frps is up on this node.

Register it with the fleet — run this against the central Postgres
(psql "\$DATABASE_URL", from node 1 or wherever it's reachable):

INSERT INTO relay_nodes (host, internal_host, port_min, port_max, frps_api_addr, frps_api_user, frps_api_pass, active)
VALUES ('${PUBLIC_HOST}', '${INTERNAL_HOST}', ${PORT_MIN}, ${PORT_MAX}, '${INTERNAL_HOST}:7500', 'opengent', '${FRPS_API_PW}', true);

register-api picks up new active nodes automatically on the next signup —
no restart needed.
EOF
