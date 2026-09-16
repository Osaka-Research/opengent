-- opengent register-api schema. Run via: psql "$DATABASE_URL" -f schema.sql
-- (idempotent — safe to re-run after a schema change to migrate forward)

CREATE TABLE IF NOT EXISTS relay_nodes (
  id             SERIAL PRIMARY KEY,
  host           TEXT NOT NULL,           -- public host clients' frpc connects to (control channel, port 7000)
  internal_host  TEXT NOT NULL DEFAULT '127.0.0.1', -- private-network address the gateway proxies tunneled traffic to
  port_min       INT NOT NULL,
  port_max       INT NOT NULL,
  frps_api_addr  TEXT NOT NULL,           -- host:port of this node's frps webServer API
  frps_api_user  TEXT NOT NULL,
  frps_api_pass  TEXT NOT NULL,
  active         BOOLEAN NOT NULL DEFAULT true
);

ALTER TABLE relay_nodes ADD COLUMN IF NOT EXISTS internal_host TEXT NOT NULL DEFAULT '127.0.0.1';

-- One row per account. token_hash is how register-api tells accounts
-- apart on POST /register — replaces the single fleet-wide shared secret,
-- so a bad actor can be deactivated without rotating everyone else's
-- token, and a quota can be enforced per account instead of globally.
CREATE TABLE IF NOT EXISTS users (
  id          SERIAL PRIMARY KEY,
  label       TEXT NOT NULL,               -- admin-facing name/email, not shown to other users
  token_hash  TEXT NOT NULL UNIQUE,         -- sha256(account token), never store raw
  max_slugs   INT NOT NULL DEFAULT 3,
  active      BOOLEAN NOT NULL DEFAULT true,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS tunnels (
  slug           TEXT PRIMARY KEY,
  relay_node_id  INT NOT NULL REFERENCES relay_nodes(id),
  owner_user_id  INT REFERENCES users(id),
  port           INT NOT NULL,
  token_hash     TEXT NOT NULL,           -- sha256(revoke token), never store raw
  unlisted       BOOLEAN NOT NULL DEFAULT false, -- excluded from the homepage's live directory
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_seen      TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (relay_node_id, port)
);

ALTER TABLE tunnels ADD COLUMN IF NOT EXISTS owner_user_id INT REFERENCES users(id);
ALTER TABLE tunnels ADD COLUMN IF NOT EXISTS unlisted BOOLEAN NOT NULL DEFAULT false;

CREATE INDEX IF NOT EXISTS tunnels_relay_node_idx ON tunnels (relay_node_id);
CREATE INDEX IF NOT EXISTS tunnels_owner_idx ON tunnels (owner_user_id);

-- A viewer asking to type into a public (read-only-by-default) terminal.
-- No FK to tunnels(slug) on purpose — a request should stay in history
-- even after the tunnel it was for is long gone, and slugs get reused.
-- "currently granted" is computed at read time (status='granted' AND
-- expires_at > now()), not swept — a poller just sees it lapse.
CREATE TABLE IF NOT EXISTS control_requests (
  id          SERIAL PRIMARY KEY,
  slug        TEXT NOT NULL,
  status      TEXT NOT NULL DEFAULT 'pending', -- pending | granted | denied
  expires_at  TIMESTAMPTZ,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS control_requests_slug_idx ON control_requests (slug);
