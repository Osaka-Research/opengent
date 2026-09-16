# opengent

Turn any terminal — phone, laptop, CI box, agent sandbox — into a public URL at
`yourdomain.com/username`, with no public IP or port-forwarding required on the
client side.

```
curl -sL https://yourdomain.com/install.sh | bash
```

No prompts, nothing to type: derives a username from this machine
(device model / hostname / whoami), self-provisions an account, and
starts sharing — no admin, no signup page, no token to go fetch first.
Public and read-only by default — anyone with the URL can watch, like
a stream; nobody can type into it. Pass `OPENGENT_WRITABLE=1` if you
want authenticated viewers to be able to type instead, or
`bash -s -- yourname` to pick your own username.

Run it from inside a `tmux` pane and it streams *that exact pane* — an
ongoing AI chat session, a long build, whatever's already running there
— automatically, no flags needed. That's the only way to share something
already in progress without restarting it: attaching another client to a
live tmux session is safe, but there's no safe way to retroactively grab
an arbitrary bare terminal's pty without risking the original process.

```
your terminal is live — public, read-only:

    https://yourdomain.com/yourname/
```

Prefer an admin-issued token (scripting, CI, or a higher quota than the
self-serve default) instead of self-provisioning?

```
curl -sL https://yourdomain.com/install.sh \
  | OPENGENT_TOKEN=<given-by-admin> bash -s -- yourname
```

Stop sharing at any time:

```
OPENGENT_SERVER=yourdomain.com ./install.sh stop yourname
```

## How it works

```
 client device            VPS (public IP + domain)
 ┌────────────┐           ┌──────────────────────────────┐
 │ ttyd        │  frpc    │ frps        Caddy      routes │
 │ (local pty) │ ───tcp──▶│ (relay) ──▶ (TLS+path)         │
 └────────────┘  tunnel   └──────────────────────────────┘
                                          │
                              https://domain.com/yourname
```

- **ttyd** runs locally on the client, serving one pty over HTTP/WebSocket,
  mounted at `/username` — public and read-only by default (`OPENGENT_WRITABLE=1`
  for password-gated write access).
- **frpc/frps** ([fatedier/frp](https://github.com/fatedier/frp)) punches a
  TCP tunnel from the client to the VPS — works from behind NAT/CGNAT (phones
  on mobile data, laptops on home wifi), no port-forwarding needed. `frps`
  binds tunneled ports to `127.0.0.1` only, so they're unreachable except
  through Caddy on the same box.
- **Caddy** terminates TLS (automatic Let's Encrypt) on the VPS and routes
  `/username/*` to that user's tunneled port.
- **register-api** is a stateless Node service (Postgres for tunnel/relay
  state, Redis for rate limiting) that allocates a free port on the
  least-loaded relay node for a new username, writes the Caddy route, and
  reloads Caddy. Stateless means you can run multiple replicas behind a
  load balancer as usage grows — see `server/setup.sh` for how a single
  box is provisioned, and its header comment for adding more relay nodes.

Each user gets their own ttyd process, own port, own path. No shared
shell, no shared session.

## Server setup (one-time, admin)

Point your domain's A record at a fresh Debian/Ubuntu VPS, then:

```
git clone https://github.com/Osaka-Research/opengent
cd opengent/server
sudo OPENGENT_DOMAIN=yourdomain.com ./setup.sh
```

This installs Caddy, frps, Postgres, Redis, the register-api, and the
gateway as systemd services, runs the DB migration, registers this box as
relay node 1, and prints the `OPENGENT_FRP_TOKEN` to hand out to clients.

### Adding relay capacity (multi-node)

Each relay node's tunneled ports are a hard-capped range (~1000 concurrent
shares by default). To scale past that, add more nodes on the same
private network (VPC/LAN) as node 1:

```
git clone https://github.com/Osaka-Research/opengent
cd opengent/server
sudo OPENGENT_PUBLIC_HOST=node2.yourdomain.com \
     OPENGENT_INTERNAL_HOST=10.0.0.5 \
     OPENGENT_FRP_TOKEN=<the token from setup.sh> \
     ./add-relay-node.sh 22000 22999
```

It installs just frps and prints an `INSERT` to run against the central
Postgres — register-api picks up the new node automatically, no restart.
The gateway reaches every node's tunnel ports over the private network
(never the public internet), so all nodes must share one.

## Client setup (per user)

See the one-liner at the top. Requires `curl`, `tar`, and either `ttyd`
already installed or a package manager the script knows about (`pkg` on
Termux, `apt` on Debian/Ubuntu, `brew` on macOS). `frpc` is downloaded
automatically, pinned to a fixed version, into `~/.opengent/bin`.

**Windows:** run it inside WSL (`wsl --install` if you don't have it —
built into Windows 10/11), not in PowerShell/cmd directly. `ttyd` needs a
real Unix pty, which WSL provides and native Windows doesn't; there's no
native-PowerShell client.

Run it again with `stop` to kill the local processes and free the slug on
the server.

## MCP server

`mcp/` exposes the same functionality as MCP tools, so an AI agent (Claude
Code, Claude Desktop, etc.) can share its own terminal on demand:

- `opengent_share(username, server?, token?, writable?)` — start sharing (self-provisions an account if `token` isn't given), returns the public URL
- `opengent_stop(username, server?)` — stop sharing, release the slug
- `opengent_list()` — list shares started on this machine and whether they're still running

Install and register it:

```
cd opengent/mcp
npm install
```

```json
{
  "mcpServers": {
    "opengent": {
      "command": "node",
      "args": ["/path/to/opengent/mcp/index.js"],
      "env": {
        "OPENGENT_SERVER": "yourdomain.com",
        "OPENGENT_FRP_TOKEN": "<given-by-admin>",
        "OPENGENT_ACCOUNT_TOKEN": "<given-by-admin>"
      }
    }
  }
}
```

It's a thin wrapper — every tool call just drives `install.sh` under the
hood, so behavior and requirements (ttyd, frpc, etc.) are identical to the
CLI flow above.

## Security notes

- Terminals are read-only by default (`ttyd` without `-W`) — connecting
  to `/username` lets you watch, not type. Safe to hand the link out
  publicly, same as a stream URL.
- `OPENGENT_WRITABLE=1` changes that: viewers who supply the printed
  `user:pass` (HTTP basic auth over TLS) can type into a real shell as
  whatever user ran `install.sh`. Treat that link+password like a root
  password, and note basic auth isn't brute-force rate-limited — front
  it with Caddy's `basicauth` or fail2ban for anything long-term.
- The fleet-wide frp token gates opening a tunnel at all (further
  bounded by `allowPorts` and `proxyBindAddr`, so a leaked one can't
  reach anything off the relay's tunnel range) — but `/api/signup`
  hands it to anyone who asks, by design, so it's no longer really
  secret. Rotate it (`frps.toml` + every relay node) if self-serve
  signup itself needs to be shut off, not just the token.
- Self-serve accounts (`/api/signup`) get a 1-slug quota and are rate
  limited at 5 signups/hour/IP. Admin-issued accounts (`create-user.sh`)
  aren't shared and can be deactivated (`UPDATE users SET active = false
  ...`) or given a higher `max_slugs` without touching anyone else's.

## License

MIT
