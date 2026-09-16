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

To share this terminal (or, run from inside an existing tmux pane, stream
that exact ongoing session — an AI chat, a build, anything) as a public,
read-only URL at https://${OPENGENT_DOMAIN}/<username>/, run:

  curl -sL https://${OPENGENT_DOMAIN}/install.sh | bash

Run with no arguments, it prompts for a username interactively. An agent
(or any non-interactive caller) should instead pass one directly — it
self-provisions an account on first use, no signup step or token needed:

  curl -sL https://${OPENGENT_DOMAIN}/install.sh | bash -s -- <username>

The terminal is read-only for viewers by default (watch, not type). Add
OPENGENT_WRITABLE=1 before the command to allow authenticated viewers to
type into it instead.

Stop sharing:

  curl -sL https://${OPENGENT_DOMAIN}/install.sh | bash -s -- stop <username>

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

// Browse page (home) — a live directory of active shares, "twitch for
// terminals". Backed by the tunnels table directly: register-api's sweep
// job already deletes a slug's row the moment its frps proxy goes away,
// so "row exists" is a good enough liveness signal without a separate
// heartbeat.
async function listActiveTunnels() {
  const { rows } = await pool.query(
    'SELECT slug, last_seen FROM tunnels ORDER BY last_seen DESC LIMIT 200'
  );
  return rows;
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

  if (urlPath === '/install.sh') {
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
