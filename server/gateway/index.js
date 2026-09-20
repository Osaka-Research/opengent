#!/usr/bin/env node
// opengent gateway — the one thing Caddy forwards every non-/api request
// to. Looks up which port a slug's tunnel is on (Redis cache, Postgres on
// miss) and proxies the request/websocket to it.
//
// Replaces writing a static Caddy `handle` block per user and reloading
// Caddy on every signup/teardown — that approach doesn't scale: reload
// cost grows with route count, and a Caddyfile with hundreds of thousands
// of blocks is its own liability. This is a single static Caddy rule that
// never changes.

const http = require('http');
const fs = require('fs');
const path = require('path');
const httpProxy = require('http-proxy');
const { Pool } = require('pg');
const { createClient } = require('redis');

const HOMEPAGE_HTML = fs.readFileSync(path.join(__dirname, 'homepage.html'));

const LISTEN_PORT = parseInt(process.env.OPENGENT_GATEWAY_PORT || '8791', 10);
const DATABASE_URL = process.env.DATABASE_URL;
const REDIS_URL = process.env.REDIS_URL;
const OPENGENT_DOMAIN = process.env.OPENGENT_DOMAIN;
if (!DATABASE_URL) { console.error('DATABASE_URL not set'); process.exit(1); }
if (!REDIS_URL) { console.error('REDIS_URL not set'); process.exit(1); }
if (!OPENGENT_DOMAIN) { console.error('OPENGENT_DOMAIN not set'); process.exit(1); }

// Served at /install.sh with an `export OPENGENT_SERVER=...` line injected
// right after the shebang, so the advertised `curl .../install.sh | bash`
// never needs the domain spelled out by hand. Injecting a line (rather than
// substituting a placeholder token throughout the file) keeps this from
// colliding with the script's own text — e.g. its usage comments, or a
// guard that checks whether OPENGENT_SERVER was actually provided.
const RAW_INSTALL_SH = fs.readFileSync(path.join(__dirname, '..', 'install.sh'), 'utf8');
const INSTALL_SH = RAW_INSTALL_SH.replace(
  /^#!.*\n/,
  (shebangLine) => `${shebangLine}export OPENGENT_SERVER="${OPENGENT_DOMAIN}"\n`
);

// llms.txt (https://llmstxt.org) — a plaintext convention AI agents/crawlers
// check for machine-readable instructions, so an agent that visits this
// site can find and run the install command on its own, same intent as
// the always-visible (non-JS-gated) command on the homepage itself.
const LLMS_TXT = `# ${OPENGENT_DOMAIN}

> Turn a terminal into a public, watchable URL. Point a browser at
> https://${OPENGENT_DOMAIN}/ to see who's live right now.

If you're an AI agent running this non-interactively — no tmux pane, no
real terminal attached, e.g. via your own shell/exec tool — that's the
common case, and it needs one extra thing: set OPENGENT_SHELL to
whatever you want shared (a build, a log tail, a long job — or just an
interactive shell someone can drive from the writable link below):

  curl -sL ${OPENGENT_DOMAIN}/i | OPENGENT_SHELL="bash -i" bash -s -- <username>

Without OPENGENT_SHELL (and without running inside an existing tmux
pane), install.sh deliberately refuses to start — it won't silently
open an unattended, publicly-writable shell that nobody actually asked
for. Set OPENGENT_SHELL to the real command you're running (e.g.
"npm run dev", "tail -f build.log") whenever there's something
specific to share instead of a bare shell.

Already inside a tmux pane and want to stream that exact ongoing
session (an AI chat, a build, anything already running there)? Just:

  curl -sL ${OPENGENT_DOMAIN}/i | bash

Either way it self-provisions an account (no signup step or token
needed) and prints two URLs: a public read-only one —
https://${OPENGENT_DOMAIN}/<username>/, anyone can watch, nobody can
type — and a second, unguessable writable one
(https://${OPENGENT_DOMAIN}/<random-hash>/) that anyone holding it can
type into, no password. Pass a username explicitly instead
(bash -s -- <username>) to choose your own, or set OPENGENT_WRITABLE=0
before the command to skip the writable link.

Stop sharing:

  curl -sL ${OPENGENT_DOMAIN}/i | bash -s -- stop

Source: https://github.com/Osaka-Research/opengent
`;

const SLUG_RE = /^[a-z0-9][a-z0-9-]{2,19}$/;
const CACHE_TTL_S = 3600; // safety net only — register-api invalidates this key explicitly on change

const pool = new Pool({ connectionString: DATABASE_URL });
const redis = createClient({ url: REDIS_URL });
redis.on('error', (e) => console.error('redis error:', e.message));

const proxy = httpProxy.createProxyServer({ ws: true, xfwd: true });
proxy.on('error', (err, req, res) => {
  console.error('proxy error:', err.message);
  if (res && !res.headersSent) {
    res.writeHead(502, { 'Content-Type': 'text/plain' });
    res.end('tunnel unreachable');
  }
});

function slugFromPath(url) {
  const m = /^\/([^/]+)/.exec(url);
  return m ? m[1].toLowerCase() : null;
}

// Multi-node: each relay node's tunneled ports are bound to that node's
// private-network address (relay_nodes.internal_host), never its public
// interface — this gateway reaches them directly over the VPC/private LAN.
// Requires the gateway box and every relay node to share that network.
async function lookupTarget(slug) {
  const cacheKey = `route:${slug}`;
  try {
    const cached = await redis.get(cacheKey);
    if (cached) return JSON.parse(cached);
  } catch (e) {
    console.error('redis lookup failed:', e.message);
  }

  const { rows } = await pool.query(
    `SELECT rn.internal_host AS host, t.port FROM tunnels t
     JOIN relay_nodes rn ON rn.id = t.relay_node_id
     WHERE t.slug = $1`,
    [slug]
  );
  if (!rows.length) return null;
  const target = { host: rows[0].host, port: rows[0].port };
  try { await redis.set(cacheKey, JSON.stringify(target), { EX: CACHE_TTL_S }); } catch { /* best effort */ }
  return target;
}

// A tunnel row can outlive its actual connection for a few minutes —
// register-api's sweep only runs every 5 minutes (SWEEP_INTERVAL_MS) with
// a 3-minute grace period, and a client that crashes or loses network
// without running `stop` leaves a row behind until then. Rather than show
// a dead slug on the homepage for that whole window, ask each relay
// node's frps API which proxies are actually connected right now and
// filter the list to those, same signal register-api's sweep itself uses.
const CONNECTED_CACHE_TTL_S = 5; // short: just enough to survive a burst of concurrent /_active polls

function fetchConnectedProxyNames(node) {
  return new Promise((resolve) => {
    const [host, portStr] = node.frps_api_addr.split(':');
    const auth = Buffer.from(`${node.frps_api_user}:${node.frps_api_pass}`).toString('base64');
    const req = http.get(
      { host, port: Number(portStr), path: '/api/proxy/tcp', headers: { Authorization: `Basic ${auth}` }, timeout: 3000 },
      (res) => {
        let data = '';
        res.on('data', (c) => (data += c));
        res.on('end', () => {
          try {
            const parsed = JSON.parse(data);
            // frps lists every proxy it has ever seen, online or not —
            // status distinguishes them, so filter to online before using
            // this as a "what's actually connected right now" signal.
            resolve(new Set((parsed.proxies || []).filter((p) => p.status === 'online').map((p) => p.name)));
          } catch (e) {
            console.error(`connected-proxy check: bad frps API response from node ${node.id}:`, e.message);
            resolve(null);
          }
        });
      }
    );
    req.on('error', (e) => { console.error(`connected-proxy check: node ${node.id} frps API unreachable:`, e.message); resolve(null); });
    req.on('timeout', () => req.destroy());
  });
}

async function connectedProxyNamesForNode(node) {
  const cacheKey = `connected-proxies:${node.id}`;
  try {
    const cached = await redis.get(cacheKey);
    if (cached) return new Set(JSON.parse(cached));
  } catch (e) {
    console.error('connected-proxy cache read failed:', e.message);
  }
  const names = await fetchConnectedProxyNames(node);
  if (names) {
    try { await redis.set(cacheKey, JSON.stringify([...names]), { EX: CONNECTED_CACHE_TTL_S }); } catch { /* best effort */ }
  }
  return names; // null means the node's frps API was unreachable this round
}

// Browse page (home) — a live directory of active shares, "twitch for
// terminals".
async function listActiveTunnels() {
  const { rows } = await pool.query(
    // unlisted slugs (the random-hash writable link) never show up here —
    // the whole point is that only someone holding the URL can find it.
    `SELECT t.slug, t.last_seen, t.relay_node_id,
            rn.frps_api_addr, rn.frps_api_user, rn.frps_api_pass
     FROM tunnels t JOIN relay_nodes rn ON rn.id = t.relay_node_id
     WHERE NOT t.unlisted ORDER BY t.last_seen DESC LIMIT 200`
  );
  if (!rows.length) return [];

  const nodes = new Map();
  for (const r of rows) {
    if (!nodes.has(r.relay_node_id)) {
      nodes.set(r.relay_node_id, { id: r.relay_node_id, frps_api_addr: r.frps_api_addr, frps_api_user: r.frps_api_user, frps_api_pass: r.frps_api_pass });
    }
  }
  const connectedByNode = new Map(
    await Promise.all([...nodes.values()].map(async (n) => [n.id, await connectedProxyNamesForNode(n)]))
  );

  return rows
    .filter((r) => {
      const connected = connectedByNode.get(r.relay_node_id);
      // Node's frps API unreachable this round — fail open (same call
      // register-api's own sweep makes) rather than hide everyone on a
      // hunch; a real outage still gets caught by the sweep's DB deletes.
      if (!connected) return true;
      return connected.has(r.slug);
    })
    .map((r) => ({ slug: r.slug, last_seen: r.last_seen }));
}

async function handleRequest(req, res) {
  const urlPath = req.url.split('?')[0];

  if (urlPath === '/' || urlPath === '') {
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    return res.end(HOMEPAGE_HTML);
  }

  if (urlPath === '/_active') {
    const list = await listActiveTunnels();
    res.writeHead(200, { 'Content-Type': 'application/json' });
    return res.end(JSON.stringify(list));
  }

  if (urlPath === '/install.sh' || urlPath === '/i') {
    res.writeHead(200, { 'Content-Type': 'text/x-shellscript; charset=utf-8' });
    return res.end(INSTALL_SH);
  }

  if (urlPath === '/llms.txt') {
    res.writeHead(200, { 'Content-Type': 'text/plain; charset=utf-8' });
    return res.end(LLMS_TXT);
  }

  const slug = slugFromPath(req.url);
  if (!slug || !SLUG_RE.test(slug)) {
    res.writeHead(404, { 'Content-Type': 'text/plain' });
    return res.end('not found');
  }
  const target = await lookupTarget(slug);
  if (!target) {
    res.writeHead(404, { 'Content-Type': 'text/plain' });
    return res.end('no such share');
  }
  proxy.web(req, res, { target: `http://${target.host}:${target.port}` });
}

const server = http.createServer((req, res) => {
  handleRequest(req, res).catch((e) => {
    console.error('gateway error:', e.message);
    if (!res.headersSent) { res.writeHead(502); res.end('gateway error'); }
  });
});

server.on('upgrade', (req, socket, head) => {
  const slug = slugFromPath(req.url);
  if (!slug || !SLUG_RE.test(slug)) return socket.destroy();
  lookupTarget(slug)
    .then((target) => {
      if (!target) return socket.destroy();
      proxy.ws(req, socket, head, { target: `http://${target.host}:${target.port}` });
    })
    .catch(() => socket.destroy());
});

async function main() {
  await redis.connect();
  await pool.query('SELECT 1');
  server.listen(LISTEN_PORT, () => console.log(`opengent gateway listening on :${LISTEN_PORT}`));
}

main().catch((e) => { console.error('startup failed:', e.message); process.exit(1); });
