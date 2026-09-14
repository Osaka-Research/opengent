#!/usr/bin/env bash
# opengent — one-time VPS provisioning (Debian/Ubuntu).
# Installs Caddy (TLS + routing), frps (NAT relay), Postgres + Redis
# (register-api state), Node (register-api), wires them together as
# systemd services. Run as root on a fresh VPS that already has your
# domain's A record pointing at it.
#
# Usage: sudo OPENGENT_DOMAIN=example.com ./setup.sh
#
# This provisions a single relay node (this box). To add more relay
# capacity later, stand up another VPS running just frps (see frps.toml)
# and INSERT a row for it into the relay_nodes table — register-api picks
# up new nodes automatically, no restart needed.

set -euo pipefail

DOMAIN="${OPENGENT_DOMAIN:?set OPENGENT_DOMAIN=yourdomain.com}"
FRP_VERSION="0.68.0"
FRP_TOKEN="$(openssl rand -hex 20)"
FRPS_API_PW="$(openssl rand -hex 20)"
DB_PASSWORD="$(openssl rand -hex 20)"
PORT_MIN="${OPENGENT_PORT_MIN:-21000}"
PORT_MAX="${OPENGENT_PORT_MAX:-21999}"
INSTALL_DIR="/opt/opengent"
DATABASE_URL="postgresql://opengent:${DB_PASSWORD}@127.0.0.1:5432/opengent"
REDIS_URL="redis://127.0.0.1:6379"

echo "==> installing prerequisites"
apt-get update -qq
apt-get install -y -qq curl gnupg2 debian-keyring debian-archive-keyring apt-transport-https gettext-base nodejs npm postgresql redis-server

echo "==> provisioning Postgres"
su - postgres -c "psql -tc \"SELECT 1 FROM pg_roles WHERE rolname='opengent'\"" | grep -q 1 \
  || su - postgres -c "psql -c \"CREATE ROLE opengent LOGIN PASSWORD '${DB_PASSWORD}';\""
su - postgres -c "psql -c \"ALTER ROLE opengent PASSWORD '${DB_PASSWORD}';\""
su - postgres -c "psql -tc \"SELECT 1 FROM pg_database WHERE datname='opengent'\"" | grep -q 1 \
  || su - postgres -c "createdb -O opengent opengent"
systemctl enable --now postgresql redis-server

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
install -m 600 "$(dirname "$0")/frps.toml" "$INSTALL_DIR/frps.toml"
sed -i "s/CHANGE_ME_SHARED_SECRET/${FRP_TOKEN}/" "$INSTALL_DIR/frps.toml"
sed -i "s/CHANGE_ME_API_PW/${FRPS_API_PW}/" "$INSTALL_DIR/frps.toml"
sed -i "s/{ start = 21000, end = 21999 }/{ start = ${PORT_MIN}, end = ${PORT_MAX} }/" "$INSTALL_DIR/frps.toml"
OPENGENT_DOMAIN="$DOMAIN" envsubst < "$(dirname "$0")/Caddyfile" > /etc/caddy/Caddyfile

mkdir -p /opt/opengent/register-api /opt/opengent/gateway
cp -r "$(dirname "$0")/register-api/." /opt/opengent/register-api/
cp -r "$(dirname "$0")/gateway/." /opt/opengent/gateway/

echo "==> installing register-api + gateway dependencies"
(cd /opt/opengent/register-api && npm install --omit=dev --no-audit --no-fund --loglevel=error)
(cd /opt/opengent/gateway && npm install --omit=dev --no-audit --no-fund --loglevel=error)

echo "==> running DB migration"
PGPASSWORD="$DB_PASSWORD" psql -h 127.0.0.1 -U opengent -d opengent -v ON_ERROR_STOP=1 \
  -f "$(dirname "$0")/register-api/schema.sql"

echo "==> creating default account (skipped if one named 'admin' already exists — re-running setup.sh is idempotent)"
ADMIN_EXISTS="$(PGPASSWORD="$DB_PASSWORD" psql -h 127.0.0.1 -U opengent -d opengent -tc "SELECT 1 FROM users WHERE label = 'admin'")"
if [ -z "$(echo "$ADMIN_EXISTS" | tr -d '[:space:]')" ]; then
  ADMIN_TOKEN="$(openssl rand -hex 20)"
  ADMIN_TOKEN_HASH="$(printf '%s' "$ADMIN_TOKEN" | sha256sum | cut -d' ' -f1)"
  PGPASSWORD="$DB_PASSWORD" psql -h 127.0.0.1 -U opengent -d opengent -v ON_ERROR_STOP=1 -c \
    "INSERT INTO users (label, token_hash, max_slugs) VALUES ('admin', '${ADMIN_TOKEN_HASH}', 20);"
else
  ADMIN_TOKEN="(unchanged — already created on a previous run; re-run server/create-user.sh for a new one if lost)"
fi

echo "==> registering this box as relay node 1"
PGPASSWORD="$DB_PASSWORD" psql -h 127.0.0.1 -U opengent -d opengent -v ON_ERROR_STOP=1 <<SQL
INSERT INTO relay_nodes (id, host, port_min, port_max, frps_api_addr, frps_api_user, frps_api_pass, active)
VALUES (1, '${DOMAIN}', ${PORT_MIN}, ${PORT_MAX}, '127.0.0.1:7500', 'opengent', '${FRPS_API_PW}', true)
ON CONFLICT (id) DO UPDATE SET
  host = EXCLUDED.host, port_min = EXCLUDED.port_min, port_max = EXCLUDED.port_max,
  frps_api_addr = EXCLUDED.frps_api_addr, frps_api_user = EXCLUDED.frps_api_user,
  frps_api_pass = EXCLUDED.frps_api_pass, active = true;
SQL

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
After=network.target postgresql.service redis-server.service
Requires=postgresql.service redis-server.service
[Service]
Environment=DATABASE_URL=$DATABASE_URL
Environment=REDIS_URL=$REDIS_URL
ExecStart=/usr/bin/node /opt/opengent/register-api/server.js
Restart=always
[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/opengent-gateway.service <<EOF
[Unit]
Description=opengent gateway (dynamic slug routing)
After=network.target postgresql.service redis-server.service
Requires=postgresql.service redis-server.service
[Service]
Environment=DATABASE_URL=$DATABASE_URL
Environment=REDIS_URL=$REDIS_URL
ExecStart=/usr/bin/node /opt/opengent/gateway/index.js
Restart=always
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now opengent-frps opengent-api opengent-gateway caddy
systemctl reload caddy || true

cat <<EOF

==> done.

  Domain:        https://$DOMAIN
  frp token:     $FRP_TOKEN   (fleet-wide, same for every user — OPENGENT_FRP_TOKEN)
  admin account: $ADMIN_TOKEN   (yours alone — OPENGENT_ACCOUNT_TOKEN)
  frps port:     7000

Every other user needs their own account — create one with:
  DATABASE_URL='$DATABASE_URL' ./create-user.sh <label> [max_slugs]

Then they run:
  curl -sL https://$DOMAIN/install.sh | OPENGENT_SERVER=$DOMAIN OPENGENT_FRP_TOKEN=$FRP_TOKEN OPENGENT_ACCOUNT_TOKEN=<theirs> bash -s -- <username>
EOF
