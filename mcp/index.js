#!/usr/bin/env node
// opengent MCP server — lets an agent share its own terminal as a public
// URL (domain.com/username) and manage that share, by driving the existing
// install.sh rather than reimplementing its logic.
//
// Config (env, or per-call args): OPENGENT_SERVER. install.sh self-provisions
// an account on first share (no token needed) unless OPENGENT_TOKEN is set.

import { McpServer } from '@modelcontextprotocol/server';
import { StdioServerTransport } from '@modelcontextprotocol/server/stdio';
import * as z from 'zod/v4';
import { execFile } from 'node:child_process';
import { readFile, readdir } from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const INSTALL_SH = path.join(__dirname, '..', 'install.sh');
const STATE_ROOT = process.env.OPENGENT_HOME || path.join(os.homedir(), '.opengent');

function runInstallSh(args, extraEnv) {
  return new Promise((resolve) => {
    execFile(
      'bash',
      [INSTALL_SH, ...args],
      { env: { ...process.env, ...extraEnv }, timeout: 60_000 },
      (err, stdout, stderr) => {
        resolve({ ok: !err, stdout: stdout || '', stderr: stderr || (err ? err.message : '') });
      }
    );
  });
}

function text(s) {
  return { content: [{ type: 'text', text: s }] };
}

const server = new McpServer({ name: 'opengent', version: '0.1.0' });

server.registerTool(
  'opengent_share',
  {
    description:
      'Share this machine\'s terminal as a public URL (https://SERVER/username/) via opengent. ' +
      'Starts ttyd + an frp tunnel locally and registers the slug with the relay. ' +
      'Returns two links by default: a public read-only one anyone can watch, and a second, ' +
      'unguessable one that\'s writable — no password, the URL itself is the credential. ' +
      'Pass writable:false to skip the writable link and share read-only only. ' +
      'Optionally pass `command` to share a specific thing (a build, a log tail, a long job) ' +
      'instead of a plain shell.',
    inputSchema: z.object({
      username: z.string().min(3).max(20).regex(/^[a-z0-9][a-z0-9-]*$/, 'lowercase letters/digits/hyphen'),
      command: z.string().min(1).optional().describe('the command to run and share instead of a plain shell, e.g. "tail -f build.log" or "npm run dev"'),
      server: z.string().optional().describe('opengent relay domain, overrides OPENGENT_SERVER env'),
      token: z.string().optional().describe('frp_token.account_token from an admin, overrides OPENGENT_TOKEN env — omit to self-provision an account automatically'),
      writable: z.boolean().optional().describe('also generate a second, unguessable link that anyone holding it can type into (no password — the URL is the credential). Default true; pass false for read-only only')
    })
  },
  async ({ username, command, server: srv, token, writable }) => {
    const OPENGENT_SERVER = srv || process.env.OPENGENT_SERVER;
    if (!OPENGENT_SERVER) return text('error: no server configured — pass `server` or set OPENGENT_SERVER');

    const extraEnv = { OPENGENT_SERVER };
    if (command) extraEnv.OPENGENT_SHELL = command;
    if (token || process.env.OPENGENT_TOKEN) extraEnv.OPENGENT_TOKEN = token || process.env.OPENGENT_TOKEN;
    if (writable !== undefined) extraEnv.OPENGENT_WRITABLE = writable ? '1' : '0';

    const { ok, stdout, stderr } = await runInstallSh([username], extraEnv);
    if (!ok) return text(`failed to start share: ${stderr || stdout}`);

    const urls = stdout.match(/https:\/\/\S+/g) || [];
    const readUrl = urls[0];
    const writeUrl = urls[1];
    if (!readUrl) return text(stdout);
    return text(
      writeUrl
        ? `Read-only: ${readUrl}\nWritable (keep secret): ${writeUrl}`
        : `Live at ${readUrl} (public, read-only)`
    );
  }
);

server.registerTool(
  'opengent_stop',
  {
    description: 'Stop sharing a terminal previously started with opengent_share and release its slug.',
    inputSchema: z.object({
      username: z.string(),
      server: z.string().optional().describe('opengent relay domain, overrides OPENGENT_SERVER env')
    })
  },
  async ({ username, server: srv }) => {
    const OPENGENT_SERVER = srv || process.env.OPENGENT_SERVER;
    if (!OPENGENT_SERVER) return text('error: no server configured — pass `server` or set OPENGENT_SERVER');
    const { ok, stdout, stderr } = await runInstallSh(['stop', username], { OPENGENT_SERVER });
    return text(ok ? stdout.trim() || 'stopped' : `failed to stop: ${stderr || stdout}`);
  }
);

server.registerTool(
  'opengent_list',
  {
    description: 'List terminal shares started on this machine (from ~/.opengent), with live/dead status.',
    inputSchema: z.object({})
  },
  async () => {
    let entries;
    try {
      entries = await readdir(STATE_ROOT, { withFileTypes: true });
    } catch {
      return text('no shares started on this machine yet.');
    }
    const rows = [];
    for (const e of entries) {
      if (!e.isDirectory() || e.name === 'bin' || e.name === 'tmp') continue;
      const dir = path.join(STATE_ROOT, e.name);
      let meta = {};
      try { meta = JSON.parse(await readFile(path.join(dir, 'meta.json'), 'utf8')); } catch { /* ignore */ }
      let pid;
      try { pid = (await readFile(path.join(dir, 'ttyd.pid'), 'utf8')).trim(); } catch { /* ignore */ }
      let alive = false;
      if (pid) {
        try { process.kill(Number(pid), 0); alive = true; } catch { alive = false; }
      }
      rows.push(`${e.name}  port=${meta.port ?? '?'}  ${alive ? 'running' : 'stopped'}`);
    }
    return text(rows.length ? rows.join('\n') : 'no shares started on this machine yet.');
  }
);

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
}

main();
