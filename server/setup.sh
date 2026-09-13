#!/usr/bin/env bash
# opengent — one-time VPS provisioning (Debian/Ubuntu).
# Installs Caddy (TLS + routing), frps (NAT relay), Node (register-api),
# wires them together as systemd services. Run as root on a fresh VPS
# that already has your domain's A record pointing at it.
#
# Usage: sudo OPENGENT_DOMAIN=example.com ./setup.sh

set -euo pipefail

DOMAIN="${OPENGENT_DOMAIN:?set OPENGENT_DOMAIN=yourdomain.com}"
FRP_VERSION="0.68.0"
FRP_TOKEN="$(openssl rand -hex 20)"
INSTALL_DIR="/opt/opengent"
ROUTES_DIR="/etc/opengent/routes"

echo "==> installing prerequisites"
apt-get update -qq
apt-get install -y -qq curl gnupg2 debian-keyring debian-archive-keyring apt-transport-https gettext-base nodejs npm

echo "==> installing Caddy"
if ! command -v caddy >/dev/null; then
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -qq
  apt-get install -y -qq caddy
fi

echo "==> installing frps ${FRP_VERSION}"
ARCH="$(uname -m)"; case "$ARCH" in x86_64) FA=amd64;; aarch64) FA=arm64;; *) echo "unsupported arch: $ARCH" >&2; exit 1;; esac
mkdir -p "$INSTALL_DIR"
curl -sL "https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_${FRP_VERSION}_linux_${FA}.tar.gz" \
  | tar xz -C "$INSTALL_DIR" --strip-components=1 "frp_${FRP_VERSION}_linux_${FA}/frps"

echo "==> writing configs"
mkdir -p "$ROUTES_DIR"
install -m 600 "$(dirname "$0")/frps.toml" "$INSTALL_DIR/frps.toml"
sed -i "s/CHANGE_ME_SHARED_SECRET/${FRP_TOKEN}/" "$INSTALL_DIR/frps.toml"
OPENGENT_DOMAIN="$DOMAIN" envsubst < "$(dirname "$0")/Caddyfile" > /etc/caddy/Caddyfile

mkdir -p /opt/opengent/register-api
cp -r "$(dirname "$0")/register-api/." /opt/opengent/register-api/

echo "==> systemd units"
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

cat > /etc/systemd/system/opengent-api.service <<EOF
[Unit]
Description=opengent register API
After=network.target
[Service]
Environment=OPENGENT_ROUTES_DIR=$ROUTES_DIR
ExecStart=/usr/bin/node /opt/opengent/register-api/server.js
Restart=always
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now opengent-frps opengent-api caddy
systemctl reload caddy || true

cat <<EOF

==> done.

  Domain:      https://$DOMAIN
  frp token:   $FRP_TOKEN   (give this to install.sh via OPENGENT_FRP_TOKEN)
  frps port:   7000
  Routes dir:  $ROUTES_DIR

Point users at:
  curl -sL https://$DOMAIN/install.sh | OPENGENT_SERVER=$DOMAIN OPENGENT_FRP_TOKEN=$FRP_TOKEN bash -s -- <username>
EOF
