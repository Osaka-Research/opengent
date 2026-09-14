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
const httpProxy = require('http-proxy');
const { Pool } = require('pg');
const { createClient } = require('redis');

const LISTEN_PORT = parseInt(process.env.OPENGENT_GATEWAY_PORT || '8791', 10);
const DATABASE_URL = process.env.DATABASE_URL;
const REDIS_URL = process.env.REDIS_URL;
if (!DATABASE_URL) { console.error('DATABASE_URL not set'); process.exit(1); }
if (!REDIS_URL) { console.error('REDIS_URL not set'); process.exit(1); }

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

async function handleRequest(req, res) {
  const slug = slugFromPath(req.url);
  if (!slug || !SLUG_RE.test(slug)) {
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    return res.end('opengent relay — https://github.com/Osaka-Research/opengent');
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
