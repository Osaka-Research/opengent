#!/usr/bin/env bash
# opengent — create an account (admin, run against the central Postgres).
#
# register-api authenticates POST /register by account token now, not one
# shared secret — this issues a new one. The raw token is shown ONCE; only
# its hash is stored.
#
# Usage:
#   DATABASE_URL=postgresql://opengent:...@127.0.0.1:5432/opengent \
#     ./create-user.sh <label> [max_slugs]
#
# label is an admin-facing identifier (email, username, whatever you use
# to remember whose account this is) — never shown to other users.

set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }

DATABASE_URL="${DATABASE_URL:?set DATABASE_URL=postgresql://...}"
LABEL="${1:?usage: create-user.sh <label> [max_slugs]}"
MAX_SLUGS="${2:-3}"
FRP_TOKEN_FILE="/opt/opengent/frp_token"

[ -f "$FRP_TOKEN_FILE" ] || die "no $FRP_TOKEN_FILE — run this on the box setup.sh provisioned"
FRP_TOKEN="$(cat "$FRP_TOKEN_FILE")"

TOKEN="$(openssl rand -hex 20)"
TOKEN_HASH="$(printf '%s' "$TOKEN" | sha256sum | cut -d' ' -f1)"

psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -c \
  "INSERT INTO users (label, token_hash, max_slugs) VALUES ('${LABEL//\'/\'\'}', '${TOKEN_HASH}', ${MAX_SLUGS});"

cat <<EOF

==> account created: $LABEL (max $MAX_SLUGS slugs)

  OPENGENT_TOKEN=${FRP_TOKEN}.${TOKEN}

Give them just this:
  curl -sL https://<yourdomain>/install.sh | OPENGENT_TOKEN=${FRP_TOKEN}.${TOKEN} bash -s -- <username>

This token is shown once; it's stored only as a hash, so if it's lost, run
this script again for a new one and deactivate the old row
(UPDATE users SET active = false WHERE label = '...').
EOF
