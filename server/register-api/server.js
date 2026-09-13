#!/usr/bin/env node
// opengent registration API — zero dependencies (Node http + fs only).
//
// Allocates a slug + local port for a new terminal-share client, writes a
// Caddy route file so `domain.com/<slug>` reverse-proxies to that port, and
// reloads Caddy. Meant to run on the VPS, behind Caddy itself (reverse
// proxied at /api/register), or directly on its own port.
//
// State is a flat JSON file — fine for the expected scale (dozens to low
// hundreds of concurrent users). Swap for a real DB if that stops being true.

const http = require('http');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { execFile } = require('child_process');

const STATE_FILE = process.env.OPENGENT_STATE || path.join(__dirname, 'state.json');
const ROUTES_DIR = process.env.OPENGENT_ROUTES_DIR || '/etc/opengent/routes';
const PORT_MIN = parseInt(process.env.OPENGENT_PORT_MIN || '21000', 10);
const PORT_MAX = parseInt(process.env.OPENGENT_PORT_MAX || '21999', 10);
const LISTEN_PORT = parseInt(process.env.OPENGENT_API_PORT || '8790', 10);
const CADDY_RELOAD_CMD = process.env.OPENGENT_CADDY_RELOAD || 'systemctl reload caddy';
const RESERVED_SLUGS = new Set(['api', 'admin', 'register', 'health', 'assets', 'static']);
const SLUG_RE = /^[a-z0-9][a-z0-9-]{2,19}$/;

function loadState() {
  try {
    return JSON.parse(fs.readFileSync(STATE_FILE, 'utf8'));
  } catch {
    return { users: {} }; // slug -> { port, token, createdAt }
  }
}

function saveState(state) {
  fs.writeFileSync(STATE_FILE, JSON.stringify(state, null, 2));
}

function allocatePort(state) {
  const used = new Set(Object.values(state.users).map((u) => u.port));
  for (let p = PORT_MIN; p <= PORT_MAX; p++) {
    if (!used.has(p)) return p;
  }
  throw new Error('no free ports left in range');
}

function writeCaddyRoute(slug, port) {
  fs.mkdirSync(ROUTES_DIR, { recursive: true });
  const block = `handle /${slug}/* {\n    reverse_proxy 127.0.0.1:${port}\n}\n`;
  fs.writeFileSync(path.join(ROUTES_DIR, `${slug}.caddy`), block);
}

function removeCaddyRoute(slug) {
  const f = path.join(ROUTES_DIR, `${slug}.caddy`);
  if (fs.existsSync(f)) fs.unlinkSync(f);
}

function reloadCaddy(cb) {
  const [cmd, ...args] = CADDY_RELOAD_CMD.split(' ');
  execFile(cmd, args, (err, stdout, stderr) => {
    if (err) console.error('caddy reload failed:', stderr || err.message);
    cb();
  });
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

const server = http.createServer((req, res) => {
  if (req.method === 'GET' && req.url === '/health') {
    return json(res, 200, { ok: true });
  }

  if (req.method === 'POST' && req.url === '/register') {
    return readBody(req, (raw) => {
      let body;
      try { body = JSON.parse(raw || '{}'); } catch { return json(res, 400, { error: 'bad json' }); }

      const slug = String(body.username || '').toLowerCase().trim();
      if (!SLUG_RE.test(slug)) {
        return json(res, 400, { error: 'username must be 3-20 chars, lowercase letters/digits/hyphen, not starting with hyphen' });
      }
      if (RESERVED_SLUGS.has(slug)) {
        return json(res, 409, { error: 'username reserved' });
      }

      const state = loadState();

      // Re-registration: same slug returns its existing assignment instead
      // of erroring, so a client can safely retry / reconnect.
      if (state.users[slug]) {
        const u = state.users[slug];
        return json(res, 200, { slug, port: u.port, token: u.token, reused: true });
      }

      let port;
      try {
        port = allocatePort(state);
      } catch (e) {
        return json(res, 503, { error: e.message });
      }

      const token = crypto.randomBytes(16).toString('hex');
      state.users[slug] = { port, token, createdAt: new Date().toISOString() };
      saveState(state);
      writeCaddyRoute(slug, port);
      reloadCaddy(() => json(res, 201, { slug, port, token, reused: false }));
    });
  }

  if (req.method === 'DELETE' && req.url.startsWith('/register/')) {
    const slug = req.url.slice('/register/'.length).toLowerCase();
    const state = loadState();
    if (!state.users[slug]) return json(res, 404, { error: 'not found' });
    // Caller must present the token they were issued on registration.
    return readBody(req, (raw) => {
      let body;
      try { body = JSON.parse(raw || '{}'); } catch { body = {}; }
      if (body.token !== state.users[slug].token) return json(res, 403, { error: 'bad token' });
      delete state.users[slug];
      saveState(state);
      removeCaddyRoute(slug);
      reloadCaddy(() => json(res, 200, { ok: true }));
    });
  }

  json(res, 404, { error: 'not found' });
});

server.listen(LISTEN_PORT, () => {
  console.log(`opengent register-api listening on :${LISTEN_PORT}`);
  console.log(`routes dir: ${ROUTES_DIR}  port range: ${PORT_MIN}-${PORT_MAX}`);
});
