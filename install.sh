#!/usr/bin/env bash
# opengent client — turns your local terminal into https://SERVER/USERNAME
#
# Usage:
#   curl -sL https://SERVER/install.sh | bash
#     — the only thing you need to paste. No prompts: derives a username
#       from this machine (device model / hostname / whoami), self-
#       provisions an account, and goes live immediately. Prints two
#       links: a public read-only one anyone can watch like a stream,
#       and a second, unguessable one that's writable — no password,
#       whoever holds that URL can type.
#   curl -sL https://SERVER/install.sh | bash -s -- USERNAME
#     — pick your own username instead of the auto-derived one.
#   curl -sL https://SERVER/install.sh | OPENGENT_TOKEN=xxx bash -s -- USERNAME
#     — use an admin-issued token instead of self-provisioning.
#   ./install.sh [USERNAME]        # or run locally after cloning
#   ./install.sh stop USERNAME     # stop sharing + release the slug(s)
#   curl -sL https://SERVER/install.sh | bash -s -- type <link> "<text>"
#     — type into ANY opengent link (public or private, yours or someone
#       else's, on this machine or a different one) and print what came
#       back. No account, no share of your own needed. Same one script.
#   curl -sL https://SERVER/install.sh | bash -s -- read <link>
#     — just watch a link's current output for a few seconds, no typing.
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
#   OPENGENT_WRITABLE set to 0 to skip the writable link and share
#                     read-only only (default: 1 — prints both links; the
#                     writable one is a second, unguessable URL, no
#                     password needed, so keep it secret). The public
#                     https://SERVER/USERNAME/ link stays read-only
#                     either way.

set -euo pipefail

FRP_VERSION="0.68.0"
STATE_ROOT="${OPENGENT_HOME:-$HOME/.opengent}"

die() { echo "error: $*" >&2; exit 1; }

# Compact progress indicator — hides which tools/packages get installed
# underneath, so `curl | bash` output stays to "setting up... / links".
SPINNER_PID=""
spinner_start() {
  [ -t 2 ] || return 0
  ( while :; do for c in '|' '/' '-' '\'; do printf '\rsetting up %s' "$c" >&2; sleep 0.1; done; done ) &
  SPINNER_PID=$!
  disown "$SPINNER_PID" 2>/dev/null || true
}
spinner_stop() {
  if [ -n "$SPINNER_PID" ]; then
    kill "$SPINNER_PID" 2>/dev/null || true
    wait "$SPINNER_PID" 2>/dev/null || true
    SPINNER_PID=""
    printf '\r\033[K' >&2
  fi
}
trap spinner_stop EXIT

# Detects which AI coding agent (if any) is driving this shell, so the
# auto-derived username/link can carry that instead of a bare device name.
# Prefers the `agenthint` CLI if installed; falls back to the same env-var
# checks inline, so a fresh `curl | bash` machine without it still works.
detect_agent_tag() {
  if command -v agenthint >/dev/null 2>&1; then
    local a
    a="$(agenthint --json 2>/dev/null | sed -n 's/.*"agent":"\([^"]*\)".*/\1/p')"
    [ -n "$a" ] && { printf '%s' "$a" | cut -d- -f1 | cut -d_ -f1; return; }
  fi
  if [ -n "${AI_AGENT:-}" ]; then printf '%s' "$AI_AGENT" | cut -d- -f1 | cut -d_ -f1; return; fi
  if [ -n "${CLAUDECODE:-}" ] || [ -n "${CLAUDE_CODE_ENTRYPOINT:-}" ]; then printf claude; return; fi
  if [ -n "${CODEX_SANDBOX:-}" ] || [ -n "${CODEX_CI:-}" ] || [ -n "${CODEX_THREAD_ID:-}" ]; then printf codex; return; fi
  if [ -n "${CURSOR_TRACE_ID:-}" ] || [ -n "${CURSOR_AGENT:-}" ]; then printf cursor; return; fi
  if [ -n "${AIDER_MODEL:-}" ] || [ -n "${AIDER_CHAT_HISTORY_FILE:-}" ]; then printf aider; return; fi
  if [ -n "${GEMINI_CLI:-}" ]; then printf gemini; return; fi
  printf ''
}

# Turns this machine's own identity (Termux device model, hostname, or
# whoami — whichever resolves first) into a valid slug, so a bare
# `curl | bash` can self-provision and go live with no prompt at all.
# When an AI agent is detected driving the shell, its short name is
# appended (e.g. `pixel7-claude`) so the resulting link/username shows
# which agent is behind it at a glance.
auto_base_username() {
  local raw=""
  [ -n "${TERMUX_VERSION:-}" ] && raw="$(getprop ro.product.model 2>/dev/null || true)"
  [ -n "$raw" ] || raw="$(hostname 2>/dev/null || true)"
  [ -n "$raw" ] || raw="$(whoami 2>/dev/null || true)"
  [ -n "$raw" ] || raw="guest"
  raw="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"

  local agent
  agent="$(detect_agent_tag | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' | cut -c1-8)"

  if [ -n "$agent" ]; then
    local base_len=$((16 - 1 - ${#agent}))
    [ "$base_len" -lt 3 ] && base_len=3
    raw="$(printf '%s' "$raw" | cut -c1-"$base_len")-$agent"
  else
    raw="$(printf '%s' "$raw" | cut -c1-16)"
  fi

  raw="$(printf '%s' "$raw" | sed -E 's/^-+//; s/-+$//')"
  while [ "${#raw}" -lt 3 ]; do raw="${raw}0"; done
  printf '%s' "$raw"
}

case "${1:-}" in
  stop) shift; ACTION=stop; USERNAME="${1:-}" ;;
  type) shift; ACTION=type; TARGET_URL="${1:-}"; TYPE_TEXT="${2:-}"; WAIT_S="${3:-3}" ;;
  read) shift; ACTION=read; TARGET_URL="${1:-}"; TYPE_TEXT=""; WAIT_S="${2:-3}" ;;
  *) ACTION=start; USERNAME="${1:-}" ;;
esac

# --- type/read: drive or watch ANY opengent link, no account needed -------
# Doesn't touch the relay's HTTP API at all — the link itself is the only
# credential ttyd checks. Same mechanism as opening the link in a browser
# and typing, just scriptable: a minimal, dependency-free WebSocket client
# (stdlib only — no `pip install`) that speaks ttyd's wire protocol
# directly (a JSON init message, then messages prefixed with a command
# byte; '0' is input/output).
if [ "$ACTION" = type ] || [ "$ACTION" = read ]; then
  [ -n "$TARGET_URL" ] || die "usage: install.sh $ACTION <link> $( [ "$ACTION" = type ] && printf '"<text>" ' )[wait-seconds]"
  if ! command -v python3 >/dev/null; then
    if [ -n "${TERMUX_VERSION:-}" ]; then pkg install -y python >/dev/null 2>&1
    elif [ "$(uname -s)" = Linux ]; then sudo apt-get install -y python3 >/dev/null 2>&1
    elif [ "$(uname -s)" = Darwin ]; then brew install python3 >/dev/null 2>&1
    fi
  fi
  command -v python3 >/dev/null || die "python3 is required for '$ACTION' (stdlib only, no packages) — install it manually"

  WS_CLIENT="$STATE_ROOT/bin/ws_client.py"
  mkdir -p "$(dirname "$WS_CLIENT")"
  if [ ! -s "$WS_CLIENT" ]; then
    cat > "$WS_CLIENT" <<'PYEOF'
#!/usr/bin/env python3
import sys, socket, ssl, base64, os, struct, time
from urllib.parse import urlsplit

def ws_connect(url):
    u = urlsplit(url)
    tls = u.scheme in ("wss", "https")
    host = u.hostname
    port = u.port or (443 if tls else 80)
    path = u.path or "/"
    if u.query:
        path += "?" + u.query
    sock = socket.create_connection((host, port), timeout=10)
    if tls:
        sock = ssl.create_default_context().wrap_socket(sock, server_hostname=host)
    key = base64.b64encode(os.urandom(16)).decode()
    req = (f"GET {path} HTTP/1.1\r\nHost: {host}\r\nUpgrade: websocket\r\n"
           f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n"
           "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: tty\r\n\r\n")
    sock.sendall(req.encode())
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = sock.recv(4096)
        if not chunk:
            raise ConnectionError("connection closed during handshake")
        buf += chunk
    header, _, rest = buf.partition(b"\r\n\r\n")
    if b" 101 " not in header.split(b"\r\n", 1)[0]:
        raise ConnectionError(f"handshake failed: {header.splitlines()[0]!r}")
    return sock, rest

def send_frame(sock, data, opcode=0x2):
    mask = os.urandom(4)
    n = len(data)
    if n < 126:
        header = struct.pack("!BB", 0x80 | opcode, 0x80 | n)
    elif n < 65536:
        header = struct.pack("!BBH", 0x80 | opcode, 0x80 | 126, n)
    else:
        header = struct.pack("!BBQ", 0x80 | opcode, 0x80 | 127, n)
    sock.sendall(header + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))

class FrameReader:
    def __init__(self, sock, leftover=b""):
        self.sock = sock
        self.buf = leftover
    def _fill(self, n):
        while len(self.buf) < n:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise ConnectionError("connection closed")
            self.buf += chunk
    def read_frame(self):
        self._fill(2)
        b0, b1 = self.buf[0], self.buf[1]
        opcode, masked, length, pos = b0 & 0x0F, bool(b1 & 0x80), b1 & 0x7F, 2
        if length == 126:
            self._fill(pos + 2); length = struct.unpack("!H", self.buf[pos:pos+2])[0]; pos += 2
        elif length == 127:
            self._fill(pos + 8); length = struct.unpack("!Q", self.buf[pos:pos+8])[0]; pos += 8
        mask_key = b""
        if masked:
            self._fill(pos + 4); mask_key = self.buf[pos:pos+4]; pos += 4
        self._fill(pos + length)
        payload = self.buf[pos:pos+length]
        self.buf = self.buf[pos+length:]
        if masked:
            payload = bytes(b ^ mask_key[i % 4] for i, b in enumerate(payload))
        return opcode, payload

def main():
    url, text = sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else ""
    wait_s = float(sys.argv[3]) if len(sys.argv) > 3 else 3.0
    sock, leftover = ws_connect(url)
    reader = FrameReader(sock, leftover)
    sock.settimeout(0.3)
    send_frame(sock, b'{"AuthToken":"","columns":120,"rows":30}', opcode=0x1)
    if text:
        time.sleep(0.4)
        send_frame(sock, b"0" + text.encode() + b"\r", opcode=0x2)
    end = time.time() + wait_s
    out = []
    while time.time() < end:
        try:
            opcode, payload = reader.read_frame()
        except socket.timeout:
            continue
        except ConnectionError:
            break
        if opcode == 0x2 and payload[:1] == b"0":
            out.append(payload[1:])
        elif opcode == 0x8:
            break
    sys.stdout.buffer.write(b"".join(out))

if __name__ == "__main__":
    main()
PYEOF
  fi

  WS_URL="${TARGET_URL%/}"
  case "$WS_URL" in
    https://*) WS_URL="wss://${WS_URL#https://}" ;;
    http://*) WS_URL="ws://${WS_URL#http://}" ;;
    *) die "link must start with https:// or http://" ;;
  esac
  python3 "$WS_CLIENT" "$WS_URL/ws" "$TYPE_TEXT" "$WAIT_S" || die "couldn't reach '$TARGET_URL' — check the link is right and still live"
  exit 0
fi

if [ "$ACTION" != start ] && [ -z "$USERNAME" ]; then
  USERNAME="$(auto_base_username)"
  [ -d "$STATE_ROOT/$USERNAME" ] || die "usage: install.sh $ACTION ... USERNAME (no username given, and no auto-derived share '$USERNAME' found in $STATE_ROOT)"
fi

SERVER="${OPENGENT_SERVER:?set OPENGENT_SERVER=yourdomain.com (only needed for a local clone — fetching this script via curl from your server fills it in automatically)}"


# Auto mode: no username, no admin token — derive one from this machine
# and self-provision, retrying with a short random suffix on conflict.
# Sets USERNAME + the account token directly, so the shared token
# resolution block below is skipped entirely for this path.
AUTO_TOKENS_SET=0
if [ "$ACTION" = start ]; then spinner_start; fi
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
  [ -f "$STATE_DIR/ttyd.pid" ] && { kill "$(cat "$STATE_DIR/ttyd.pid")" 2>/dev/null || true; }
  [ -f "$STATE_DIR/write-ttyd.pid" ] && { kill "$(cat "$STATE_DIR/write-ttyd.pid")" 2>/dev/null || true; }
  [ -f "$STATE_DIR/frpc.pid" ] && { kill "$(cat "$STATE_DIR/frpc.pid")" 2>/dev/null || true; }
  [ -f "$STATE_DIR/tmux_share_session" ] && { tmux kill-session -t "$(cat "$STATE_DIR/tmux_share_session")" 2>/dev/null || true; }
  if [ -f "$STATE_DIR/meta.json" ]; then
    TOKEN=$(grep -o '"revokeToken":"[^"]*"' "$STATE_DIR/meta.json" | cut -d'"' -f4)
    curl -sf -X DELETE "https://$SERVER/api/register/$USERNAME" \
      -H 'Content-Type: application/json' -d "{\"token\":\"$TOKEN\"}" >/dev/null || true
  fi
  if [ -f "$STATE_DIR/write_meta.json" ] && [ -f "$STATE_DIR/write_slug" ]; then
    WRITE_SLUG_STOP="$(cat "$STATE_DIR/write_slug")"
    WTOKEN=$(grep -o '"revokeToken":"[^"]*"' "$STATE_DIR/write_meta.json" | cut -d'"' -f4)
    curl -sf -X DELETE "https://$SERVER/api/register/$WRITE_SLUG_STOP" \
      -H 'Content-Type: application/json' -d "{\"token\":\"$WTOKEN\"}" >/dev/null || true
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
  if [ "$IS_TERMUX" = 1 ]; then pkg install -y ttyd >/dev/null 2>&1
  elif [ "$OS" = "Linux" ]; then sudo apt-get update -qq >/dev/null 2>&1 && sudo apt-get install -y ttyd >/dev/null 2>&1
  elif [ "$OS" = "Darwin" ]; then brew install ttyd >/dev/null 2>&1
  fi
fi
command -v ttyd >/dev/null || die "ttyd install failed — install manually: $PKG_INSTALL ttyd"

# --- install frpc ---------------------------------------------------------
FRPC_BIN="$STATE_ROOT/bin/frpc"
if [ ! -x "$FRPC_BIN" ]; then
  mkdir -p "$STATE_ROOT/bin" "$STATE_ROOT/tmp"
  URL="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_${FRP_VERSION}_${FRP_OS}_${FRP_ARCH}.tar.gz"
  if ! curl -sL "$URL" -o "$STATE_ROOT/tmp/frp.tar.gz"; then
    [ "$FRP_OS" = android ] || die "download failed: $URL"
    FRP_OS=linux
    curl -sL "https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_${FRP_VERSION}_${FRP_OS}_${FRP_ARCH}.tar.gz" \
      -o "$STATE_ROOT/tmp/frp.tar.gz" || die "download failed"
  fi
  tar xzf "$STATE_ROOT/tmp/frp.tar.gz" -C "$STATE_ROOT/tmp" >/dev/null 2>&1
  cp "$STATE_ROOT/tmp/frp_${FRP_VERSION}_${FRP_OS}_${FRP_ARCH}/frpc" "$FRPC_BIN"
  chmod +x "$FRPC_BIN"
  rm -rf "$STATE_ROOT/tmp"
fi

# --- install qrencode, best-effort ----------------------------------------
# Only useful for the human-at-a-terminal case (scan with a phone), so
# only bother installing it when stdout is an actual terminal; skip
# silently on failure — a QR code is a nicety, never worth a die().
if [ -t 1 ] && ! command -v qrencode >/dev/null; then
  if [ "$IS_TERMUX" = 1 ]; then pkg install -y libqrencode >/dev/null 2>&1
  elif [ "$OS" = "Linux" ]; then sudo apt-get install -y qrencode >/dev/null 2>&1
  elif [ "$OS" = "Darwin" ]; then brew install qrencode >/dev/null 2>&1
  fi
fi

# Already inside tmux and no explicit OPENGENT_SHELL? Stream *this exact
# pane* — attaching another client to a live tmux session is safe (no new
# process, no risk to what's already running there), unlike trying to
# hijack an arbitrary bare terminal's pty. This is what makes "share
# whatever's already running" a one-liner: run it from inside the tmux
# session you want streamed, tmux or not otherwise required.
SHARE_CMD="${OPENGENT_SHELL:-}"
TMUX_SHARE_SESSION=""
if [ -z "$SHARE_CMD" ] && [ -n "${TMUX:-}" ]; then
  TMUX_SESSION="$(tmux display-message -p '#S' 2>/dev/null || true)"
  if [ -n "$TMUX_SESSION" ]; then
    SHARE_CMD="tmux attach -t $TMUX_SESSION"
    TMUX_SHARE_SESSION="$TMUX_SESSION"
  fi
fi
[ -n "$SHARE_CMD" ] || SHARE_CMD="$SHELL"

# Always multiplex through tmux — not just when a writable link is
# requested — so there's one universal, well-known way to drive any
# share programmatically (tmux send-keys/capture-pane against a fixed
# session name) regardless of OPENGENT_WRITABLE or OPENGENT_SHELL.
# Skipped only when already inside the tmux pane being shared (branch
# above) — that pane already has a name, no new session needed.
if [[ "$SHARE_CMD" != tmux\ attach* ]]; then
  command -v tmux >/dev/null || $PKG_INSTALL tmux >/dev/null 2>&1
  command -v tmux >/dev/null || die "tmux is required — install it manually"
  TMUX_SHARE_SESSION="opengent-$USERNAME"
  if ! tmux has-session -t "$TMUX_SHARE_SESSION" 2>/dev/null; then
    tmux new-session -d -s "$TMUX_SHARE_SESSION" "$SHARE_CMD"
  fi
  echo "$TMUX_SHARE_SESSION" > "$STATE_DIR/tmux_share_session"
  SHARE_CMD="tmux attach -t $TMUX_SHARE_SESSION"
fi

# --- custom ttyd page title, so the browser tab reads the domain ----------
# ttyd's own default page title ("ttyd - Terminal") is a static asset;
# `-t titleFixed=` only rewrites document.title after the client JS
# connects, so the tab briefly flashes the default first. Fetch ttyd's
# actual default page once (from the ttyd binary itself, so this tracks
# whatever version is actually installed instead of a vendored copy)
# and swap just the <title>. Best-effort — falls back to ttyd's default
# on any failure, never blocks the share.
CUSTOM_INDEX="$STATE_ROOT/ttyd-index-$SERVER.html"
if [ ! -s "$CUSTOM_INDEX" ]; then
  TMP_PORT=$(( (RANDOM % 5000) + 20000 ))
  nohup ttyd -p "$TMP_PORT" -i 127.0.0.1 true >/dev/null 2>&1 &
  TMP_TTYD_PID=$!
  disown 2>/dev/null || true
  sleep 0.5
  curl -s --max-time 2 "http://127.0.0.1:$TMP_PORT/" -o "$CUSTOM_INDEX.tmp" 2>/dev/null
  kill "$TMP_TTYD_PID" 2>/dev/null || true
  if [ -s "$CUSTOM_INDEX.tmp" ]; then
    sed "s|<title>ttyd - Terminal</title>|<title>$SERVER</title>|" "$CUSTOM_INDEX.tmp" > "$CUSTOM_INDEX" 2>/dev/null
  fi
  rm -f "$CUSTOM_INDEX.tmp"
fi
INDEX_ARGS=()
[ -s "$CUSTOM_INDEX" ] && INDEX_ARGS=(-I "$CUSTOM_INDEX")

# --- register with the relay ----------------------------------------------
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

# --- register a second, unlisted slug for the writable link ----------------
# On by default: every share gets a writable link alongside the read-only
# one. A random-hash slug instead of a password: capability-URL style —
# anyone holding the link can type, nobody has to type or store a
# password. Kept out of the homepage directory (unlisted:true) so it
# can't be found by browsing, only by having the link. Same account as
# the primary slug — SELF_SERVE_MAX_SLUGS covers both.
# Set OPENGENT_WRITABLE=0 to skip it and share read-only only.
WRITABLE="${OPENGENT_WRITABLE:-1}"
WRITE_SLUG=""
WRITE_PORT=""
if [ "$WRITABLE" = 1 ]; then
  WRITE_SLUG_FILE="$STATE_DIR/write_slug"
  if [ -f "$WRITE_SLUG_FILE" ]; then
    WRITE_SLUG="$(cat "$WRITE_SLUG_FILE")"
  else
    WRITE_SLUG="$(head -c 32 /dev/urandom | base64 | tr '[:upper:]' '[:lower:]' | tr -dc 'a-z0-9' | head -c 20)"
    printf '%s' "$WRITE_SLUG" > "$WRITE_SLUG_FILE"
  fi

  PREV_WRITE_TOKEN=""
  [ -f "$STATE_DIR/write_meta.json" ] && PREV_WRITE_TOKEN="$(grep -o '"revokeToken":"[^"]*"' "$STATE_DIR/write_meta.json" | cut -d'"' -f4)"
  WRITE_RESP="$(curl -sf -X POST "https://$SERVER/api/register" \
    -H 'Content-Type: application/json' \
    -d "{\"username\":\"$WRITE_SLUG\",\"authToken\":\"$ACCOUNT_TOKEN\",\"token\":\"$PREV_WRITE_TOKEN\",\"unlisted\":true}")" \
    || die "registering the writable link failed"
  WRITE_PORT="$(echo "$WRITE_RESP" | grep -o '"port":[0-9]*' | grep -o '[0-9]*')"
  WRITE_REVOKE_TOKEN="$(echo "$WRITE_RESP" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)"
  [ -n "$WRITE_PORT" ] || die "bad response from server for writable link: $WRITE_RESP"
  echo "{\"revokeToken\":\"$WRITE_REVOKE_TOKEN\",\"port\":$WRITE_PORT}" > "$STATE_DIR/write_meta.json"
fi

# --- start ttyd/frpc, retrying with a fresh LOCAL port on failure ----------
# A user doesn't want a cause, they want it to work. The one thing that
# actually goes wrong here in practice is this machine's own local port
# already being in use — re-registering doesn't help with that (the
# relay hands back the same lowest free port every time; verified this
# empirically — it's not the fix). What actually fixes it: ttyd's LOCAL
# bind port doesn't have to match frp's REMOTE port at all. frp forwards
# localPort -> remotePort, so keep remotePort ($PORT, from the relay)
# fixed and just pick a fresh random local port each retry — no
# re-registration, no network round-trip, just try another local port.
wait_for_ttyd() {
  local port="$1" base_path="$2" tries=0
  while [ "$tries" -lt 10 ]; do
    [ "$(curl -s --max-time 0.5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/$base_path/" 2>/dev/null)" = "200" ] && return 0
    sleep 0.1
    tries=$((tries + 1))
  done
  return 1
}

wait_for_frpc_proxy() {
  # "proxy added:" fires the instant frpc registers the proxy locally —
  # before frps has confirmed anything. The real outcome ("start proxy
  # success" or "start error: ...") lands ~100-200ms later. Checking for
  # "proxy added:" as success was a race: it matched before the actual
  # error line even had a chance to appear, so a real remote-port
  # collision on the relay's side got reported as a working share.
  local name="$1" tries=0
  while [ "$tries" -lt 20 ]; do
    grep -q "\[$name\] start error" "$STATE_DIR/frpc.log" 2>/dev/null && return 1
    grep -q "\[$name\] start proxy success" "$STATE_DIR/frpc.log" 2>/dev/null && return 0
    sleep 0.1
    tries=$((tries + 1))
  done
  return 1
}

random_local_port() { echo $(( (RANDOM % 20000) + 30000 )); }

STARTED=0
MAX_ATTEMPTS=5
for ATTEMPT in $(seq 1 $MAX_ATTEMPTS); do
  LOCAL_PORT="$(random_local_port)"
  WRITE_LOCAL_PORT=""
  [ -n "$WRITE_SLUG" ] && WRITE_LOCAL_PORT="$(random_local_port)"

  cat > "$STATE_DIR/frpc.toml" <<EOF
serverAddr = "$SERVER"
serverPort = 7000
auth.method = "token"
auth.token = "$FRP_TOKEN"

[[proxies]]
name = "$USERNAME"
type = "tcp"
localIP = "127.0.0.1"
localPort = $LOCAL_PORT
remotePort = $PORT
EOF
  if [ -n "$WRITE_SLUG" ]; then
    cat >> "$STATE_DIR/frpc.toml" <<EOF

[[proxies]]
name = "$WRITE_SLUG"
type = "tcp"
localIP = "127.0.0.1"
localPort = $WRITE_LOCAL_PORT
remotePort = $WRITE_PORT
EOF
  fi

  nohup "$FRPC_BIN" -c "$STATE_DIR/frpc.toml" >"$STATE_DIR/frpc.log" 2>&1 &
  echo $! > "$STATE_DIR/frpc.pid"
  disown 2>/dev/null || true

  # --- start the public terminal -------------------------------------------
  # Public and read-only, always — like watching a stream, not
  # remote-controlling someone's shell. The read-only guarantee comes
  # entirely from ttyd itself (it never forwards a keystroke to the pty
  # unless given -W) — deliberately not from tmux's own `-r` client flag,
  # which doesn't just stop that one client from typing, it blocks *all*
  # input into the session, including from another process's `tmux
  # send-keys` and from ttyd's own -W on the separate writable link below.
  nohup ttyd -p "$LOCAL_PORT" -i 127.0.0.1 -b "/$USERNAME" "${INDEX_ARGS[@]}" $SHARE_CMD \
    >"$STATE_DIR/ttyd.log" 2>&1 &
  echo $! > "$STATE_DIR/ttyd.pid"
  disown 2>/dev/null || true

  # --- start the writable link, if requested --------------------------------
  # No password: the URL itself is the credential (a ~103-bit random slug).
  # Anyone who has it can type; nobody has to type or store a password.
  if [ -n "$WRITE_SLUG" ]; then
    nohup ttyd -p "$WRITE_LOCAL_PORT" -i 127.0.0.1 -b "/$WRITE_SLUG" -W "${INDEX_ARGS[@]}" $SHARE_CMD \
      >"$STATE_DIR/write-ttyd.log" 2>&1 &
    echo $! > "$STATE_DIR/write-ttyd.pid"
    disown 2>/dev/null || true
  fi

  # --- verify the share actually came up -----------------------------------
  OK=1
  wait_for_ttyd "$LOCAL_PORT" "$USERNAME" || OK=0
  [ "$OK" = 1 ] && [ -n "$WRITE_SLUG" ] && { wait_for_ttyd "$WRITE_LOCAL_PORT" "$WRITE_SLUG" || OK=0; }
  [ "$OK" = 1 ] && { wait_for_frpc_proxy "$USERNAME" || OK=0; }
  [ "$OK" = 1 ] && [ -n "$WRITE_SLUG" ] && { wait_for_frpc_proxy "$WRITE_SLUG" || OK=0; }

  if [ "$OK" = 1 ]; then
    STARTED=1
    break
  fi
  [ -f "$STATE_DIR/ttyd.pid" ] && { kill "$(cat "$STATE_DIR/ttyd.pid")" 2>/dev/null || true; }
  [ -f "$STATE_DIR/write-ttyd.pid" ] && { kill "$(cat "$STATE_DIR/write-ttyd.pid")" 2>/dev/null || true; }
  [ -f "$STATE_DIR/frpc.pid" ] && { kill "$(cat "$STATE_DIR/frpc.pid")" 2>/dev/null || true; }
done

if [ "$STARTED" != 1 ]; then
  [ -f "$STATE_DIR/tmux_share_session" ] && { tmux kill-session -t "$(cat "$STATE_DIR/tmux_share_session")" 2>/dev/null || true; }
  curl -sf -X DELETE "https://$SERVER/api/register/$USERNAME" \
    -H 'Content-Type: application/json' -d "{\"token\":\"$REVOKE_TOKEN\"}" >/dev/null 2>&1 || true
  if [ -n "$WRITE_SLUG" ]; then
    curl -sf -X DELETE "https://$SERVER/api/register/$WRITE_SLUG" \
      -H 'Content-Type: application/json' -d "{\"token\":\"$WRITE_REVOKE_TOKEN\"}" >/dev/null 2>&1 || true
  fi
  die "couldn't get a share running after $MAX_ATTEMPTS tries (all local ports somehow unavailable) — see $STATE_DIR/ttyd.log and $STATE_DIR/frpc.log."
fi

# --- install a short local command, e.g. `tunl` for tunl.ac ----------------
# So next time is just `tunl` / `tunl stop`, not the full curl one-liner.
# The installed command just re-runs this same curl|bash — always fetches
# whatever's currently live on $SERVER, never goes stale on its own.
CLI_NAME="$(printf '%s' "$SERVER" | cut -d. -f1)"
if [[ "$CLI_NAME" =~ ^[a-z][a-z0-9_-]{1,30}$ ]]; then
  CLI_TMP="$(mktemp)"
  cat > "$CLI_TMP" <<CLIEOF
#!/usr/bin/env bash
exec curl -sL $SERVER/i | bash -s -- "\$@"
CLIEOF
  chmod +x "$CLI_TMP"
  CLI_INSTALLED=""
  if [ "$IS_TERMUX" = 1 ] && [ -w "$PREFIX/bin" ]; then
    cp "$CLI_TMP" "$PREFIX/bin/$CLI_NAME" 2>/dev/null && CLI_INSTALLED="$PREFIX/bin/$CLI_NAME"
  elif [ -w /usr/local/bin ] 2>/dev/null; then
    cp "$CLI_TMP" "/usr/local/bin/$CLI_NAME" 2>/dev/null && CLI_INSTALLED="/usr/local/bin/$CLI_NAME"
  elif command -v sudo >/dev/null; then
    sudo -n install -m 755 "$CLI_TMP" "/usr/local/bin/$CLI_NAME" 2>/dev/null && CLI_INSTALLED="/usr/local/bin/$CLI_NAME"
  fi
  if [ -z "$CLI_INSTALLED" ]; then
    mkdir -p "$HOME/.local/bin" 2>/dev/null
    cp "$CLI_TMP" "$HOME/.local/bin/$CLI_NAME" 2>/dev/null && CLI_INSTALLED="$HOME/.local/bin/$CLI_NAME"
  fi
  rm -f "$CLI_TMP"
fi

sleep 1
spinner_stop

if [ -t 1 ]; then
  C_DIM=$'\033[2m'; C_GREEN=$'\033[1;32m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
  C_DIM=''; C_GREEN=''; C_BOLD=''; C_RESET=''
fi

show_qr() {
  if [ -t 1 ] && command -v qrencode >/dev/null 2>&1; then
    qrencode -t ANSIUTF8 "$1"
  fi
}

printf '\n%s\n%s%s%s\n' "${C_DIM}public link (read-only, safe to share):${C_RESET}" "$C_GREEN" "https://$SERVER/$USERNAME/" "$C_RESET"
show_qr "https://$SERVER/$USERNAME/"
if [ -n "$WRITE_SLUG" ]; then
  printf '\n%s\n%s%s%s\n' "${C_DIM}private link (full control, keep secret):${C_RESET}" "$C_GREEN" "https://$SERVER/$WRITE_SLUG/" "$C_RESET"
fi
if [ -n "${CLI_INSTALLED:-}" ] && command -v "$CLI_NAME" >/dev/null 2>&1; then
  printf '\n%s %s%s%s\n' "${C_DIM}next time, just run:${C_RESET}" "$C_BOLD" "$CLI_NAME" "$C_RESET"
fi

if [ -n "$TMUX_SHARE_SESSION" ]; then
  printf '\n%s\n' "${C_DIM}drive it from here (no browser needed):${C_RESET}"
  printf '  tmux send-keys -t %s '"'"'<command>'"'"' Enter\n' "$TMUX_SHARE_SESSION"
  printf '  tmux capture-pane -t %s -p\n' "$TMUX_SHARE_SESSION"
fi
if [ -n "$WRITE_SLUG" ]; then
  printf '\n%s\n' "${C_DIM}drive it from anywhere else (same script, just a link):${C_RESET}"
  if [ -n "${CLI_INSTALLED:-}" ] && command -v "$CLI_NAME" >/dev/null 2>&1; then
    printf '  %s type https://%s/%s/ '"'"'<command>'"'"'\n' "$CLI_NAME" "$SERVER" "$WRITE_SLUG"
  else
    printf '  curl -sL %s/i | bash -s -- type https://%s/%s/ '"'"'<command>'"'"'\n' "$SERVER" "$SERVER" "$WRITE_SLUG"
  fi
fi
