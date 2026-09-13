# opengent

Turn any terminal — phone, laptop, CI box, agent sandbox — into a public URL at
`yourdomain.com/username`, with no public IP or port-forwarding required on the
client side.

```
curl -sL https://yourdomain.com/install.sh \
  | OPENGENT_SERVER=yourdomain.com OPENGENT_FRP_TOKEN=<given-by-admin> \
    bash -s -- yourname
```

```
your terminal is live:

    https://yourdomain.com/yourname/

    user: yourname
    pass: <generated>
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
- **register-api** is a small, dependency-free Node service that allocates a
  free port for a new username, writes the Caddy route, and reloads Caddy.

Each user gets their own ttyd process, own port, own path, own basic-auth
credentials. No shared shell, no shared session.

## Server setup (one-time, admin)

Point your domain's A record at a fresh Debian/Ubuntu VPS, then:

```
git clone https://github.com/Osaka-Research/opengent
cd opengent/server
sudo OPENGENT_DOMAIN=yourdomain.com ./setup.sh
```

This installs Caddy, frps, and the register-api as systemd services, and
prints the `OPENGENT_FRP_TOKEN` to hand out to clients.

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
        "OPENGENT_FRP_TOKEN": "<given-by-admin>"
      }
    }
  }
}
```

It's a thin wrapper — every tool call just drives `install.sh` under the
hood, so behavior and requirements (ttyd, frpc, etc.) are identical to the
CLI flow above.

## Security notes

This is a minimal scaffold, not a hardened multi-tenant platform. Before
using it for anything beyond trusted collaborators:

- `OPENGENT_FRP_TOKEN` is one shared secret for every client. Anyone who has
  it can open an frp tunnel to any port in the configured range. Rotate it
  if it leaks; consider per-client tokens (frp supports auth plugins) for
  larger deployments.
- The registration API (`/api/register`) is unauthenticated — anyone who can
  reach it can claim an unused username. Put it behind an allowlist or an
  admin-issued invite token if that's not acceptable for your use case.
- ttyd's `-c user:pass` is HTTP basic auth over TLS (fine) but not
  brute-force rate-limited. Consider fronting with Caddy's `basicauth` or
  fail2ban for anything internet-facing long-term.
- Whoever connects to `/username` gets a real shell as whatever user ran
  `install.sh`. Treat the link like a root password.

## License

MIT
