#!/usr/bin/env node
// opengent registration API — Postgres-backed state, Redis-backed rate
// limiting + route cache. Stateless: run as many replicas of this behind
// a load balancer as you want, they all read/write the same DB.
//
// Allocates a slug + port on the least-loaded relay node, for an account
// authenticated by its own token (see `users` table, provisioned with
// create-user.sh) — not a single fleet-wide shared secret, so one account
// can be deactivated or quota-limited without touching anyone else's.
// Routing to that port happens in the gateway service (server/gateway),
// which reads the `route:<slug>` Redis key this writes/deletes — no Caddy
// config change and no reload on signup/teardown.

const http = require('http');
const crypto = require('crypto');
const { Pool } = require('pg');
const { createClient } = require('redis');

const LISTEN_PORT = parseInt(process.env.OPENGENT_API_PORT || '8790', 10);
const RESERVED_SLUGS = new Set(['api', 'admin', 'register', 'health', 'assets', 'static']);
const SLUG_RE = /^[a-z0-9][a-z0-9-]{2,19}$/;

const DATABASE_URL = process.env.DATABASE_URL;
const REDIS_URL = process.env.REDIS_URL;
const FRP_TOKEN = process.env.OPENGENT_FRP_TOKEN;
if (!DATABASE_URL) { console.error('DATABASE_URL not set'); process.exit(1); }
if (!REDIS_URL) { console.error('REDIS_URL not set'); process.exit(1); }
if (!FRP_TOKEN) { console.error('OPENGENT_FRP_TOKEN not set'); process.exit(1); }

const SIGNUP_RATE_LIMIT_WINDOW_S = 3600;
// CGNAT means many genuine, distinct users can share one IP, and a normal
// user can easily retry a handful of times (typo'd username, re-running
// after clearing local state, a second device behind the same NAT). 5 was
// tight enough to hit routinely under completely legitimate use; this still
// bounds automated mass account creation without punishing that.
const SIGNUP_RATE_LIMIT_MAX = 30;
// 2, not 1: one public read-only slug (username) plus one unlisted slug for
// the optional writable link (OPENGENT_WRITABLE=1) — same account, no extra
// signup step.
const SELF_SERVE_MAX_SLUGS = 2;

async function signupRateLimited(ip) {
  try {
    const key = `ratelimit:signup:${ip}`;
    const count = await redis.incr(key);
    if (count === 1) await redis.expire(key, SIGNUP_RATE_LIMIT_WINDOW_S);
    return count > SIGNUP_RATE_LIMIT_MAX;
  } catch (e) {
    console.error('signup rate-limit check failed, allowing request:', e.message);
    return false;
  }
}

const RATE_LIMIT_WINDOW_S = 60;
const RATE_LIMIT_MAX = 10;
const SWEEP_INTERVAL_MS = 5 * 60_000;
const SWEEP_GRACE_MS = 3 * 60_000;

const pool = new Pool({ connectionString: DATABASE_URL });
const redis = createClient({ url: REDIS_URL });
redis.on('error', (e) => console.error('redis error:', e.message));

function sha256(s) {
  return crypto.createHash('sha256').update(s).digest('hex');
}

function safeEqual(a, b) {
  const bufA = Buffer.from(String(a));
  const bufB = Buffer.from(String(b));
  if (bufA.length !== bufB.length) return false;
  return crypto.timingSafeEqual(bufA, bufB);
}

function clientIp(req) {
  const fwd = req.headers['x-forwarded-for'];
  if (fwd) return fwd.split(',')[0].trim();
  return req.socket.remoteAddress;
}

async function rateLimited(ip) {
  try {
    const key = `ratelimit:register:${ip}`;
    const count = await redis.incr(key);
    if (count === 1) await redis.expire(key, RATE_LIMIT_WINDOW_S);
    return count > RATE_LIMIT_MAX;
  } catch (e) {
    console.error('rate-limit check failed, allowing request:', e.message);
    return false; // fail open — a Redis blip shouldn't take down signups
  }
}

// Looks an account up by its token (hashed, so raw tokens never sit in
// the DB or logs). This is the auth boundary for POST /register — each
// account gets its own token instead of one shared fleet-wide secret, so
// one can be deactivated/quota-limited without touching anyone else's.
async function authenticateAccount(rawToken) {
  const { rows } = await pool.query('SELECT * FROM users WHERE token_hash = $1 AND active', [sha256(rawToken)]);
  return rows[0] || null;
}

async function countTunnelsForUser(userId) {
  const { rows } = await pool.query('SELECT COUNT(*) FROM tunnels WHERE owner_user_id = $1', [userId]);
  return Number(rows[0].count);
}

async function setRouteCache(slug, internalHost, port) {
  try { await redis.set(`route:${slug}`, JSON.stringify({ host: internalHost, port })); } catch (e) { console.error('route cache set failed:', e.message); }
}

async function delRouteCache(slug) {
  try { await redis.del(`route:${slug}`); } catch (e) { console.error('route cache del failed:', e.message); }
}

function json(res, code, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(code, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) });
  res.end(body);
}

function readBody(req, cb) {
  let data = '';
  req.on('data', (c) => { data += c; if (data.length > 1e5) req.destroy(); });
  req.on('end', () => cb(data));
}

// Picks the active relay node with the most free port capacity, allocates
// a free port on it via retry-on-conflict (safe under concurrent
// register-api replicas: the DB's UNIQUE(relay_node_id, port) constraint
// is the actual race guard, not this selection query).
async function allocateOnLeastLoadedNode() {
  const { rows } = await pool.query(`
    SELECT rn.id, rn.host, rn.internal_host, rn.port_min, rn.port_max,
           rn.frps_api_addr, rn.frps_api_user, rn.frps_api_pass,
           (rn.port_max - rn.port_min + 1) - COUNT(t.slug) AS free
    FROM relay_nodes rn
    LEFT JOIN tunnels t ON t.relay_node_id = rn.id
    WHERE rn.active
    GROUP BY rn.id
    HAVING (rn.port_max - rn.port_min + 1) - COUNT(t.slug) > 0
    ORDER BY free DESC
    LIMIT 1
  `);
  if (!rows.length) throw new Error('no relay node with free capacity');
  return rows[0];
}

// The DB is not the source of truth for which ports are actually bound —
// frps is. A tunnel row can go missing (client crashed before the sweep
// ran, a row got deleted while frps's own connection to that client
// silently outlived it — common on mobile/NAT, where the underlying TCP
// connection dies without a clean close) while frps still holds the
// port. Without this cross-check, the allocator hands that same port
// back out, and the new registration fails with frps's own "start
// error: port already used" — a real, observed failure mode, not a
// hypothetical one. Fails open (returns null = "nothing extra known to
// exclude") if frps's API is unreachable, same as the sweep does.
function fetchLiveProxyPorts(node) {
  return new Promise((resolve) => {
    if (!node.frps_api_addr) return resolve(null);
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
            const ports = new Set();
            for (const p of parsed.proxies || []) {
              if (p.status === 'online' && p.conf && p.conf.remotePort) ports.add(p.conf.remotePort);
            }
            resolve(ports);
          } catch (e) {
            console.error(`fetchLiveProxyPorts: bad frps API response from node ${node.id}:`, e.message);
            resolve(null);
          }
        });
      }
    );
    req.on('error', (e) => { console.error(`fetchLiveProxyPorts: node ${node.id} frps API unreachable:`, e.message); resolve(null); });
    req.on('timeout', () => req.destroy());
  });
}

async function firstFreePort(node) {
  const { rows } = await pool.query('SELECT port FROM tunnels WHERE relay_node_id = $1', [node.id]);
  const used = new Set(rows.map((r) => r.port));
  const live = await fetchLiveProxyPorts(node);
  if (live) for (const p of live) used.add(p);
  for (let p = node.port_min; p <= node.port_max; p++) {
    if (!used.has(p)) return p;
  }
  return null;
}

async function registerSlug(slug, ownerUserId, unlisted) {
  for (let attempt = 0; attempt < 5; attempt++) {
    const node = await allocateOnLeastLoadedNode();
    const port = await firstFreePort(node);
    if (port == null) continue; // node filled up between select and here, retry

    const rawToken = crypto.randomBytes(16).toString('hex');
    try {
      await pool.query(
        `INSERT INTO tunnels (slug, relay_node_id, owner_user_id, port, token_hash, unlisted) VALUES ($1, $2, $3, $4, $5, $6)`,
        [slug, node.id, ownerUserId, port, sha256(rawToken), Boolean(unlisted)]
      );
      return { slug, port, token: rawToken, host: node.host, internalHost: node.internal_host };
    } catch (e) {
      if (e.code === '23505') continue; // unique_violation — lost the race, retry
      throw e;
    }
  }
  throw new Error('could not allocate a port after retries');
}

const server = http.createServer((req, res) => {
  if (req.method === 'GET' && req.url === '/health') {
    return json(res, 200, { ok: true });
  }

  if (req.method === 'POST' && req.url === '/register') {
    return (async () => {
      if (await rateLimited(clientIp(req))) return json(res, 429, { error: 'too many requests, slow down' });

      readBody(req, async (raw) => {
        let body;
        try { body = JSON.parse(raw || '{}'); } catch { return json(res, 400, { error: 'bad json' }); }

        if (!body.authToken) return json(res, 401, { error: 'missing authToken' });
        const account = await authenticateAccount(body.authToken);
        if (!account) return json(res, 401, { error: 'bad, unknown, or deactivated authToken' });

        const slug = String(body.username || '').toLowerCase().trim();
        if (!SLUG_RE.test(slug)) {
          return json(res, 400, { error: 'username must be 3-20 chars, lowercase letters/digits/hyphen, not starting with hyphen' });
        }
        if (RESERVED_SLUGS.has(slug)) {
          return json(res, 409, { error: 'username reserved' });
        }

        try {
          const { rows } = await pool.query(
            `SELECT t.*, rn.internal_host FROM tunnels t
             JOIN relay_nodes rn ON rn.id = t.relay_node_id
             WHERE t.slug = $1`,
            [slug]
          );
          const existing = rows[0];

          if (existing) {
            // Re-registration only succeeds if the caller proves ownership
            // with the token they were issued last time — otherwise this
            // would leak an existing user's revoke token to anyone who
            // guesses their slug.
            if (body.token && safeEqual(sha256(body.token), existing.token_hash)) {
              await pool.query('UPDATE tunnels SET last_seen = now(), unlisted = $2 WHERE slug = $1', [slug, Boolean(body.unlisted)]);
              await setRouteCache(slug, existing.internal_host, existing.port); // re-affirm in case the cache entry expired/was evicted
              return json(res, 200, { slug, port: existing.port, token: body.token, reused: true });
            }
            return json(res, 409, { error: 'username taken' });
          }

          const used = await countTunnelsForUser(account.id);
          if (used >= account.max_slugs) {
            return json(res, 403, { error: `account quota reached (${account.max_slugs} slugs)` });
          }

          const result = await registerSlug(slug, account.id, body.unlisted);
          await setRouteCache(result.slug, result.internalHost, result.port);
          return json(res, 201, { slug: result.slug, port: result.port, token: result.token, reused: false });
        } catch (e) {
          console.error('register failed:', e.message);
          return json(res, 503, { error: e.message });
        }
      });
    })();
  }

  if (req.method === 'DELETE' && req.url.startsWith('/register/')) {
    const slug = req.url.slice('/register/'.length).toLowerCase();
    return (async () => {
      try {
        const { rows } = await pool.query('SELECT * FROM tunnels WHERE slug = $1', [slug]);
        const existing = rows[0];
        if (!existing) return json(res, 404, { error: 'not found' });

        readBody(req, async (raw) => {
          let body;
          try { body = JSON.parse(raw || '{}'); } catch { body = {}; }
          if (!body.token || !safeEqual(sha256(body.token), existing.token_hash)) {
            return json(res, 403, { error: 'bad token' });
          }
          await pool.query('DELETE FROM tunnels WHERE slug = $1', [slug]);
          await delRouteCache(slug);
          return json(res, 200, { ok: true });
        });
      } catch (e) {
        console.error('deregister failed:', e.message);
        return json(res, 503, { error: e.message });
      }
    })();
  }

  // Self-serve account creation — no admin token needed. Ties one account
  // 1:1 to the username someone picks in install.sh's interactive flow,
  // so "username" doubles as both the account label and (on /register)
  // the slug. Capped at SELF_SERVE_MAX_SLUGS; an admin can raise a
  // specific account's quota later directly in Postgres if needed.
  if (req.method === 'POST' && req.url === '/signup') {
    return (async () => {
      if (await signupRateLimited(clientIp(req))) return json(res, 429, { error: 'too many signups from this IP, slow down' });

      readBody(req, async (raw) => {
        let body;
        try { body = JSON.parse(raw || '{}'); } catch { return json(res, 400, { error: 'bad json' }); }

        const username = String(body.username || '').toLowerCase().trim();
        if (!SLUG_RE.test(username)) {
          return json(res, 400, { error: 'username must be 3-20 chars, lowercase letters/digits/hyphen, not starting with hyphen' });
        }
        if (RESERVED_SLUGS.has(username)) {
          return json(res, 409, { error: 'username reserved' });
        }

        try {
          const { rows } = await pool.query('SELECT 1 FROM users WHERE label = $1', [username]);
          if (rows.length) return json(res, 409, { error: 'username taken — already have an account? re-run with your saved OPENGENT_TOKEN' });

          const accountToken = crypto.randomBytes(20).toString('hex');
          await pool.query(
            'INSERT INTO users (label, token_hash, max_slugs) VALUES ($1, $2, $3)',
            [username, sha256(accountToken), SELF_SERVE_MAX_SLUGS]
          );
          return json(res, 201, { frpToken: FRP_TOKEN, accountToken });
        } catch (e) {
          console.error('signup failed:', e.message);
          return json(res, 503, { error: e.message });
        }
      });
    })();
  }

  json(res, 404, { error: 'not found' });
});

// --- stale-slug sweep -------------------------------------------------
// A client that crashes/loses network without running `stop` never frees
// its slug+port. Periodically ask each relay node's frps which proxies
// are actually connected and drop any tunnel row that isn't (past a grace
// period, so a slug isn't killed in the gap between registering and frpc
// connecting).
function fetchConnectedProxyNames(node) {
  return new Promise((resolve) => {
    const [host, portStr] = node.frps_api_addr.split(':');
    const auth = Buffer.from(`${node.frps_api_user}:${node.frps_api_pass}`).toString('base64');
    const req = http.get(
      { host, port: Number(portStr), path: '/api/proxy/tcp', headers: { Authorization: `Basic ${auth}` }, timeout: 5000 },
      (res) => {
        let data = '';
        res.on('data', (c) => (data += c));
        res.on('end', () => {
          try {
            const parsed = JSON.parse(data);
            // frps lists every proxy it has ever seen, online or not — a
            // slug whose frpc died still shows up here with status
            // "offline", so without this filter the sweep never sees it
            // as missing and never deletes its row.
            resolve(new Set((parsed.proxies || []).filter((p) => p.status === 'online').map((p) => p.name)));
          } catch (e) {
            console.error(`sweep: bad frps API response from node ${node.id}:`, e.message);
            resolve(null);
          }
        });
      }
    );
    req.on('error', (e) => { console.error(`sweep: node ${node.id} frps API unreachable:`, e.message); resolve(null); });
    req.on('timeout', () => req.destroy());
  });
}

async function sweepStaleSlugs() {
  let nodes;
  try {
    nodes = (await pool.query('SELECT * FROM relay_nodes WHERE active')).rows;
  } catch (e) {
    console.error('sweep: could not load relay nodes:', e.message);
    return;
  }

  for (const node of nodes) {
    const connected = await fetchConnectedProxyNames(node);
    if (!connected) continue; // node's frps API unreachable this round — skip, don't kill live tunnels on a hunch

    let tunnels;
    try {
      tunnels = (await pool.query(
        `SELECT slug, created_at FROM tunnels WHERE relay_node_id = $1 AND created_at < now() - interval '${Math.floor(SWEEP_GRACE_MS / 1000)} seconds'`,
        [node.id]
      )).rows;
    } catch (e) {
      console.error(`sweep: could not load tunnels for node ${node.id}:`, e.message);
      continue;
    }

    for (const t of tunnels) {
      if (!connected.has(t.slug)) {
        console.log(`sweep: removing stale slug '${t.slug}' on node ${node.id} (no live frps proxy)`);
        try {
          await pool.query('DELETE FROM tunnels WHERE slug = $1', [t.slug]);
          await delRouteCache(t.slug);
        } catch (e) {
          console.error(`sweep: failed to remove '${t.slug}':`, e.message);
        }
      }
    }
  }
}

setInterval(() => sweepStaleSlugs().catch((e) => console.error('sweep failed:', e.message)), SWEEP_INTERVAL_MS);

async function main() {
  await redis.connect();
  await pool.query('SELECT 1'); // fail fast if DB unreachable
  server.listen(LISTEN_PORT, () => {
    console.log(`opengent register-api listening on :${LISTEN_PORT}`);
  });
}

main().catch((e) => { console.error('startup failed:', e.message); process.exit(1); });
