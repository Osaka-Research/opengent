# opengent

Turn any terminal — phone, laptop, CI box, agent sandbox — into a public URL at
`yourdomain.com/username`, with no public IP or port-forwarding required on the
client side.

```
curl -sL https://yourdomain.com/install.sh | bash
```

Asks for a username (and optionally a password) right there in the
terminal, self-provisions an account, and starts sharing — no admin, no
signup page, no token to go fetch first.

```
your terminal is live:

    https://yourdomain.com/yourname/

    user: yourname
    pass: <generated>
```

Prefer a non-interactive one-liner (scripting, CI, or an admin-issued
token with a higher quota)? Skip the prompts:

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
  password-protected, mounted at `/username`.
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

Each user gets their own ttyd process, own port, own path, own basic-auth
credentials. No shared shell, no shared session.

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

Run it again with `stop` to kill the local processes and free the slug on
the server.

## MCP server

`mcp/` exposes the same functionality as MCP tools, so an AI agent (Claude
Code, Claude Desktop, etc.) can share its own terminal on demand:

- `opengent_share(username, server?, frpToken?)` — start sharing, returns the URL + credentials
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

- `OPENGENT_FRP_TOKEN` is still one shared secret for every client — it
  only gates opening an frp tunnel at all (further bounded by
  `allowPorts` and `proxyBindAddr`, so a leaked one can't reach anything
  off the relay's tunnel range). Rotate it if it leaks.
- Claiming a username requires `OPENGENT_ACCOUNT_TOKEN`, issued per
  account via `create-user.sh` (not shared) — deactivate one account
  (`UPDATE users SET active = false ...`) without touching anyone else's,
  and each account is capped at `max_slugs` concurrent shares.
- ttyd's `-c user:pass` is HTTP basic auth over TLS (fine) but not
  brute-force rate-limited. Consider fronting with Caddy's `basicauth` or
  fail2ban for anything internet-facing long-term.
- Whoever connects to `/username` gets a real shell as whatever user ran
  `install.sh`. Treat the link like a root password.

## License

MIT
