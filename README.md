# opengent

Turn any terminal — phone, laptop, CI box, agent sandbox — into a public URL at
`yourdomain.com/username`, with no public IP or port-forwarding required on the
client side.

```
curl -sL yourdomain.com/i | bash
```

No prompts, nothing to type: derives a username from this machine
(device model / hostname / whoami), self-provisions an account, and
starts sharing — no admin, no signup page, no token to go fetch first.
Prints two links: a public, read-only one anyone can watch like a
stream, and a second, unguessable writable one — anyone holding *that*
URL can type, no password, the link itself is the credential. Pass
`OPENGENT_WRITABLE=0` to skip the writable link, or `bash -s -- yourname`
to pick your own username.

Run it from inside a `tmux` pane and it streams *that exact pane* — an
ongoing AI chat session, a long build, whatever's already running there
— automatically, no flags needed. That's the only way to share something
already in progress without restarting it: attaching another client to a
live tmux session is safe, but there's no safe way to retroactively grab
an arbitrary bare terminal's pty without risking the original process.

```
public link (read-only, safe to share): https://yourdomain.com/yourname/
private link (full control, keep secret): https://yourdomain.com/<random-hash>/
```

The share always lives in a local tmux session named `opengent-yourname`
(also printed in the output above), so the same agent/shell that ran the
command can drive it directly — no browser needed:

```
tmux send-keys -t opengent-yourname 'claude' Enter
tmux capture-pane -t opengent-yourname -p
```

Prefer an admin-issued token (scripting, CI, or a higher quota than the
self-serve default) instead of self-provisioning?

```
curl -sL yourdomain.com/i \
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

- **ttyd** runs locally on the client, as two processes by default: one
  read-only, mounted at `/username`, and one writable, mounted at a random
  unguessable slug instead of a username — no password, the URL itself is
  the credential (`OPENGENT_WRITABLE=0` to skip the second one). Both
  attach to the same `tmux` session (created automatically if you weren't
  already in one, and always — regardless of `OPENGENT_WRITABLE` — so
  there's one universal way to drive a share with `tmux send-keys`) so
  the writable link controls exactly what the read-only link shows.
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

## AWS deployment

Relay nodes run on EC2, provisioned via `server/setup.sh` /
`server/add-relay-node.sh`. Nodes are tagged `Name=opengent-gateway` (node
1, runs the full stack) or `Name=opengent-relay-*` (added capacity, frps
only) — look them up by tag instead of hardcoding instance IDs, so this
stays valid across accounts/regions and as nodes are added:

```
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=opengent-gateway,opengent-relay-*" \
  --query 'Reservations[].Instances[].{ID:InstanceId,Name:Tags[?Key==`Name`]|[0].Value,IP:PublicIpAddress,State:State.Name}' \
  --output table
```

Key pair and SSH user are whatever you passed/left default in
`setup.sh`/`add-relay-node.sh` for that box (default AMI user is usually
`ubuntu`). SSH in once you have the IP from the lookup above:

```
ssh -i ~/.ssh/<your-key> ubuntu@<public-ip>
```

### Redeploying after a code change

The gateway (`server/gateway/index.js`) reads `install.sh` into memory
**once at process start** (`fs.readFileSync` at module load) to serve it
at `/i` and `/install.sh`. A `git push` alone does **not** update what
`curl .../i | bash` serves on a running box — pull and restart there too:

```
ssh -i ~/.ssh/<your-key> ubuntu@<public-ip>
cd <path to the clone setup.sh was run from>
sudo git pull
sudo cp install.sh /opt/opengent/install.sh
sudo cp -r server/gateway/. /opt/opengent/gateway/
sudo cp -r server/register-api/. /opt/opengent/register-api/
sudo systemctl restart opengent-gateway opengent-api
```

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

- The public `/username` link is always read-only (`ttyd` without `-W`) —
  connecting lets you watch, not type. Safe to hand out publicly, same as
  a stream URL.
- By default a second link is also created at a random ~103-bit slug
  (`/<random-hash>/`, unlisted — it never appears in the homepage
  directory) that's writable with no further auth: whoever has that URL
  types into a real shell as whatever user ran `install.sh`. There's no
  approval step and no password — the URL itself is the full credential,
  so treat it like a root password: don't post it anywhere public, and
  anyone it leaks to (browser history, a proxy log, a pasted screenshot)
  has the same access you do until you `stop` the share. Set
  `OPENGENT_WRITABLE=0` if you only want the read-only link.
- The fleet-wide frp token gates opening a tunnel at all (further
  bounded by `allowPorts` and `proxyBindAddr`, so a leaked one can't
  reach anything off the relay's tunnel range) — but `/api/signup`
  hands it to anyone who asks, by design, so it's no longer really
  secret. Rotate it (`frps.toml` + every relay node) if self-serve
  signup itself needs to be shut off, not just the token.
- Self-serve accounts (`/api/signup`) get a 2-slug quota (username +
  the optional writable link) and are rate limited at 5 signups/hour/IP.
  Admin-issued accounts (`create-user.sh`) aren't shared and can be
  deactivated (`UPDATE users SET active = false ...`) or given a higher
  `max_slugs` without touching anyone else's.

## License

MIT
