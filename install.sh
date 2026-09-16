#!/usr/bin/env bash
# opengent client — turns your local terminal into https://SERVER/USERNAME
#
# Usage:
#   curl -sL https://SERVER/install.sh | bash
#     — the only thing you need to paste. No prompts: derives a username
#       from this machine (device model / hostname / whoami), self-
#       provisions an account, and goes live immediately. Terminal is
#       public and read-only by default — anyone with the URL can watch,
#       like a stream; nobody can type into it.
#   curl -sL https://SERVER/install.sh | bash -s -- USERNAME
#     — pick your own username instead of the auto-derived one.
#   curl -sL https://SERVER/install.sh | OPENGENT_TOKEN=xxx bash -s -- USERNAME
#     — use an admin-issued token instead of self-provisioning.
#   ./install.sh [USERNAME]        # or run locally after cloning
#   ./install.sh stop USERNAME     # stop sharing + release the slug
#
# Env:
#   OPENGENT_TOKEN    skip interactive signup and use this token instead
#                     (create-user.sh prints it as frp_token.account_token)
#   OPENGENT_SERVER   domain of the opengent relay — filled in automatically
#                     when this script is fetched via curl from your server;
#                     only set it by hand when running a local clone (required)
#   OPENGENT_SHELL    command to run in the shared terminal (default: attach
#                     to the current tmux pane if run from inside one — so
#                     sharing whatever's already running there needs no
#                     flags at all; otherwise your plain $SHELL)
#   OPENGENT_WRITABLE set to 1 to let (password-authenticated) viewers type
#                     into this terminal instead of just watching it

set -euo pipefail

FRP_VERSION="0.68.0"
STATE_ROOT="${OPENGENT_HOME:-$HOME/.opengent}"

die() { echo "error: $*" >&2; exit 1; }

# Turns this machine's own identity (Termux device model, hostname, or
# whoami — whichever resolves first) into a valid slug, so a bare
# `curl | bash` can self-provision and go live with no prompt at all.
auto_base_username() {
  local raw=""
  [ -n "${TERMUX_VERSION:-}" ] && raw="$(getprop ro.product.model 2>/dev/null || true)"
  [ -n "$raw" ] || raw="$(hostname 2>/dev/null || true)"
  [ -n "$raw" ] || raw="$(whoami 2>/dev/null || true)"
  [ -n "$raw" ] || raw="guest"
  raw="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' | cut -c1-16)"
  while [ "${#raw}" -lt 3 ]; do raw="${raw}0"; done
  printf '%s' "$raw"
}

[ "${1:-}" = "stop" ] && { shift; ACTION=stop; } || ACTION=start
USERNAME="${1:-}"
if [ "$ACTION" = stop ] && [ -z "$USERNAME" ]; then
  USERNAME="$(auto_base_username)"
  [ -d "$STATE_ROOT/$USERNAME" ] || die "usage: install.sh stop USERNAME (no username given, and no auto-derived share '$USERNAME' found in $STATE_ROOT)"
fi

SERVER="${OPENGENT_SERVER:?set OPENGENT_SERVER=yourdomain.com (only needed for a local clone — fetching this script via curl from your server fills it in automatically)}"

# Auto mode: no username, no admin token — derive one from this machine
# and self-provision, retrying with a short random suffix on conflict.
# Sets USERNAME + the account token directly, so the shared token
# resolution block below is skipped entirely for this path.
AUTO_TOKENS_SET=0
if [ "$ACTION" = start ] && [ -z "$USERNAME" ] && [ -z "${OPENGENT_TOKEN:-}" ]; then
  BASE="$(auto_base_username)"
  if [ -f "$STATE_ROOT/$BASE/account_token" ]; then
    USERNAME="$BASE"
  else
    for attempt in 1 2 3 4 5; do
      CANDIDATE="$BASE"
      [ "$attempt" = 1 ] || CANDIDATE="${BASE}-$(printf '%x' $((RANDOM % 4096)))"
      SIGNUP_RESP="$(curl -s -X POST "https://$SERVER/api/signup" \
        -H 'Content-Type: application/json' -d "{\"username\":\"$CANDIDATE\"}")"
      CAND_FRP="$(echo "$SIGNUP_RESP" | grep -o '"frpToken":"[^"]*"' | cut -d'"' -f4)" || true
      CAND_ACC="$(echo "$SIGNUP_RESP" | grep -o '"accountToken":"[^"]*"' | cut -d'"' -f4)" || true
      if [ -n "$CAND_FRP" ] && [ -n "$CAND_ACC" ]; then
        USERNAME="$CANDIDATE"; FRP_TOKEN="$CAND_FRP"; ACCOUNT_TOKEN="$CAND_ACC"
        mkdir -p "$STATE_ROOT/$USERNAME"
        printf '%s.%s' "$FRP_TOKEN" "$ACCOUNT_TOKEN" > "$STATE_ROOT/$USERNAME/account_token"
        chmod 600 "$STATE_ROOT/$USERNAME/account_token"
        AUTO_TOKENS_SET=1
        break
      fi
    done
    [ "$AUTO_TOKENS_SET" = 1 ] || die "could not auto-provision a username after $attempt attempts: $SIGNUP_RESP"
  fi
fi

[[ "$USERNAME" =~ ^[a-z0-9][a-z0-9-]{2,19}$ ]] || die "usage: install.sh [stop] USERNAME"
STATE_DIR="$STATE_ROOT/$USERNAME"

if [ "$ACTION" = stop ]; then
  echo "==> stopping $USERNAME"
  [ -f "$STATE_DIR/ttyd.pid" ] && kill "$(cat "$STATE_DIR/ttyd.pid")" 2>/dev/null
  [ -f "$STATE_DIR/frpc.pid" ] && kill "$(cat "$STATE_DIR/frpc.pid")" 2>/dev/null
  if [ -f "$STATE_DIR/meta.json" ]; then
    TOKEN=$(grep -o '"revokeToken":"[^"]*"' "$STATE_DIR/meta.json" | cut -d'"' -f4)
    curl -sf -X DELETE "https://$SERVER/api/register/$USERNAME" \
      -H 'Content-Type: application/json' -d "{\"token\":\"$TOKEN\"}" >/dev/null || true
  fi
  rm -rf "$STATE_DIR"
  echo "==> stopped. slug released."
  exit 0
fi

TOKEN_FILE="$STATE_DIR/account_token"
if [ "$AUTO_TOKENS_SET" = 1 ]; then
  : # already set above, during the auto-provisioning retry loop
elif [ -n "${OPENGENT_TOKEN:-}" ]; then
  FRP_TOKEN="${OPENGENT_TOKEN%%.*}"
  ACCOUNT_TOKEN="${OPENGENT_TOKEN#*.}"
  [ -n "$FRP_TOKEN" ] && [ -n "$ACCOUNT_TOKEN" ] && [ "$FRP_TOKEN" != "$ACCOUNT_TOKEN" ] \
    || die "OPENGENT_TOKEN malformed — expected frp_token.account_token"
elif [ -f "$TOKEN_FILE" ]; then
  FRP_TOKEN="$(cut -d. -f1 "$TOKEN_FILE")"
  ACCOUNT_TOKEN="$(cut -d. -f2- "$TOKEN_FILE")"
else
  echo "==> creating your account on $SERVER"
  SIGNUP_RESP="$(curl -sf -X POST "https://$SERVER/api/signup" \
    -H 'Content-Type: application/json' -d "{\"username\":\"$USERNAME\"}")" \
    || die "signup failed — username may be taken (if it's yours, re-run with OPENGENT_TOKEN=<saved token>) or the server is unreachable"
  FRP_TOKEN="$(echo "$SIGNUP_RESP" | grep -o '"frpToken":"[^"]*"' | cut -d'"' -f4)"
  ACCOUNT_TOKEN="$(echo "$SIGNUP_RESP" | grep -o '"accountToken":"[^"]*"' | cut -d'"' -f4)"
  [ -n "$FRP_TOKEN" ] && [ -n "$ACCOUNT_TOKEN" ] || die "bad signup response: $SIGNUP_RESP"
  mkdir -p "$STATE_DIR"
  printf '%s.%s' "$FRP_TOKEN" "$ACCOUNT_TOKEN" > "$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE"
fi
mkdir -p "$STATE_DIR"

# --- detect platform ---------------------------------------------------
OS="$(uname -s)"
ARCH="$(uname -m)"
IS_TERMUX=0
[ -n "${TERMUX_VERSION:-}" ] && IS_TERMUX=1

case "$ARCH" in
  x86_64|amd64) FRP_ARCH=amd64 ;;
  aarch64|arm64) FRP_ARCH=arm64 ;;
  *) die "unsupported arch: $ARCH (install ttyd + frpc manually, see README)" ;;
esac

if [ "$IS_TERMUX" = 1 ]; then
  FRP_OS=android
  PKG_INSTALL="pkg install -y"
elif [ "$OS" = "Linux" ]; then
  FRP_OS=linux
  PKG_INSTALL="sudo apt-get install -y"
elif [ "$OS" = "Darwin" ]; then
  FRP_OS=darwin
  PKG_INSTALL="brew install"
else
  die "unsupported OS: $OS"
fi

# --- install ttyd --------------------------------------------------------
if ! command -v ttyd >/dev/null; then
  echo "==> installing ttyd"
  if [ "$IS_TERMUX" = 1 ]; then pkg install -y ttyd
  elif [ "$OS" = "Linux" ]; then sudo apt-get update -qq && sudo apt-get install -y ttyd
  elif [ "$OS" = "Darwin" ]; then brew install ttyd
  fi
fi
command -v ttyd >/dev/null || die "ttyd install failed — install manually: $PKG_INSTALL ttyd"

# --- install frpc ---------------------------------------------------------
FRPC_BIN="$STATE_ROOT/bin/frpc"
if [ ! -x "$FRPC_BIN" ]; then
  echo "==> downloading frpc ${FRP_VERSION} ($FRP_OS/$FRP_ARCH)"
  mkdir -p "$STATE_ROOT/bin" "$STATE_ROOT/tmp"
  URL="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_${FRP_VERSION}_${FRP_OS}_${FRP_ARCH}.tar.gz"
  if ! curl -sL "$URL" -o "$STATE_ROOT/tmp/frp.tar.gz"; then
    [ "$FRP_OS" = android ] || die "download failed: $URL"
    echo "==> no android build, falling back to linux/$FRP_ARCH"
    FRP_OS=linux
    curl -sL "https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_${FRP_VERSION}_${FRP_OS}_${FRP_ARCH}.tar.gz" \
      -o "$STATE_ROOT/tmp/frp.tar.gz" || die "download failed"
  fi
  tar xzf "$STATE_ROOT/tmp/frp.tar.gz" -C "$STATE_ROOT/tmp"
  cp "$STATE_ROOT/tmp/frp_${FRP_VERSION}_${FRP_OS}_${FRP_ARCH}/frpc" "$FRPC_BIN"
  chmod +x "$FRPC_BIN"
  rm -rf "$STATE_ROOT/tmp"
fi

# --- register with the relay ----------------------------------------------
echo "==> registering '$USERNAME' with $SERVER"
# If we've registered this slug before (meta.json survived a restart),
# send its token back so the server can tell a legit retry apart from
# someone else trying to grab our slug.
PREV_TOKEN=""
[ -f "$STATE_DIR/meta.json" ] && PREV_TOKEN="$(grep -o '"revokeToken":"[^"]*"' "$STATE_DIR/meta.json" | cut -d'"' -f4)"
RESP="$(curl -sf -X POST "https://$SERVER/api/register" \
  -H 'Content-Type: application/json' \
  -d "{\"username\":\"$USERNAME\",\"authToken\":\"$ACCOUNT_TOKEN\",\"token\":\"$PREV_TOKEN\"}")" \
  || die "registration failed — username taken, bad token, or server unreachable"

PORT="$(echo "$RESP" | grep -o '"port":[0-9]*' | grep -o '[0-9]*')"
REVOKE_TOKEN="$(echo "$RESP" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)"
[ -n "$PORT" ] || die "bad response from server: $RESP"
echo "{\"revokeToken\":\"$REVOKE_TOKEN\",\"port\":$PORT}" > "$STATE_DIR/meta.json"

# --- credentials -------------------------------------------------------
# Public and read-only by default — like watching a stream, not remote-
# controlling someone's shell. ttyd is readonly unless given -W, so the
# only thing a password would gate here is *watching*, which defeats the
# point of a public terminal directory. Set OPENGENT_WRITABLE=1 to instead
# let (authenticated) viewers type into this terminal.
WRITABLE="${OPENGENT_WRITABLE:-0}"
TTYD_FLAGS=(-p "$PORT" -i 127.0.0.1 -b "/$USERNAME")
PASS=""
if [ "$WRITABLE" = 1 ]; then
  PASS="$(head -c 24 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 16)"
  echo "$PASS" > "$STATE_DIR/password"
  chmod 600 "$STATE_DIR/password"
  TTYD_FLAGS+=(-W -c "$USERNAME:$PASS")
fi

# --- write frpc config + start ---------------------------------------------
cat > "$STATE_DIR/frpc.toml" <<EOF
serverAddr = "$SERVER"
serverPort = 7000
auth.method = "token"
auth.token = "$FRP_TOKEN"

[[proxies]]
name = "$USERNAME"
type = "tcp"
localIP = "127.0.0.1"
localPort = $PORT
remotePort = $PORT
EOF

echo "==> starting frpc"
nohup "$FRPC_BIN" -c "$STATE_DIR/frpc.toml" >"$STATE_DIR/frpc.log" 2>&1 &
echo $! > "$STATE_DIR/frpc.pid"
disown 2>/dev/null || true

# Already inside tmux and no explicit OPENGENT_SHELL? Stream *this exact
# pane* — attaching another client to a live tmux session is safe (no new
# process, no risk to what's already running there), unlike trying to
# hijack an arbitrary bare terminal's pty. This is what makes "share
# whatever's already running" a one-liner: run it from inside the tmux
# session you want streamed, tmux or not otherwise required.
SHARE_CMD="${OPENGENT_SHELL:-}"
if [ -z "$SHARE_CMD" ] && [ -n "${TMUX:-}" ]; then
  TMUX_SESSION="$(tmux display-message -p '#S' 2>/dev/null || true)"
  [ -n "$TMUX_SESSION" ] && SHARE_CMD="tmux attach -t $TMUX_SESSION -r"
fi
[ -n "$SHARE_CMD" ] || SHARE_CMD="$SHELL"

echo "==> starting ttyd on 127.0.0.1:$PORT"
nohup ttyd "${TTYD_FLAGS[@]}" $SHARE_CMD \
  >"$STATE_DIR/ttyd.log" 2>&1 &
echo $! > "$STATE_DIR/ttyd.pid"
disown 2>/dev/null || true

sleep 1
if [ "$WRITABLE" = 1 ]; then
  cat <<EOF

==> your terminal is live (writable — viewers can type):

    https://$SERVER/$USERNAME/

    user: $USERNAME
    pass: $PASS

Stop sharing:
    OPENGENT_SERVER=$SERVER ./install.sh stop $USERNAME
EOF
else
  cat <<EOF

==> your terminal is live — public, read-only:

    https://$SERVER/$USERNAME/

Stop sharing:
    OPENGENT_SERVER=$SERVER ./install.sh stop $USERNAME
EOF
fi
