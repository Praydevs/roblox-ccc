import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { existsSync, readFileSync } from 'node:fs';
import { extname, join, normalize, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { networkInterfaces } from 'node:os';
import { createStore, GAMES, gameName, hashPassword, verifyPassword } from './db.js';
import { createClaimer, normalizeCookie, cookieValid, verifyCookie } from './claimer.js';
import handle, { initApp, startClaimer } from './app.js';

const ROOT = dirname(dirname(fileURLToPath(import.meta.url)));
const PUBLIC = join(ROOT, 'public');

// optional .env so `npm start` picks up deploy settings without a dependency
const ENV_FILE = join(ROOT, '.env');
if (existsSync(ENV_FILE)) {
  for (const line of readFileSync(ENV_FILE, 'utf8').split(/\r?\n/)) {
    if (!line.trim() || line.trim().startsWith('#')) continue;
    const match = line.match(/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$/);
    if (!match) continue;
    const value = match[2].replace(/^["']|["']$/g, '');
    if (!(match[1] in process.env)) process.env[match[1]] = value;
  }
}

const PORT = Number(process.env.PORT) || 5175;
const HOST = process.env.HOST || '127.0.0.1';
const DISCORD_ID = process.env.DISCORD_CLIENT_ID ?? '';
const DISCORD_SECRET = process.env.DISCORD_CLIENT_SECRET ?? '';

const firstLanIp = Object.values(networkInterfaces())
  .flat()
  .find((info) => info && info.family === 'IPv4' && !info.internal)?.address ?? '127.0.0.1';
const BASE_URL = process.env.PUBLIC_URL ?? `http://${HOST === '0.0.0.0' ? firstLanIp : HOST}:${PORT}`;

const lanUrls = () => Object.values(networkInterfaces())
  .flat()
  .filter((info) => info && info.family === 'IPv4' && !info.internal)
  .map((info) => `http://${info.address}:${PORT}`);

const store = createStore();
const startedAt = Date.now();

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.lua': 'text/plain; charset=utf-8',
  '.woff2': 'font/woff2',
};

const serveStatic = async (res, pathname) => {
  const safe = normalize(pathname).replace(/^(\.\.[/\\])+/, '');
  let filePath = join(PUBLIC, safe === '/' ? 'index.html' : safe);
  if (!filePath.startsWith(PUBLIC)) filePath = join(PUBLIC, 'index.html');
  if (!existsSync(filePath)) filePath = join(PUBLIC, 'index.html');
  try {
    const data = await readFile(filePath);
    res.writeHead(200, {
      'content-type': MIME[extname(filePath)] ?? 'application/octet-stream',
      'cache-control': 'no-cache',
      'x-content-type-options': 'nosniff',
      'x-frame-options': 'DENY',
    });
    res.end(data);
  } catch {
    res.writeHead(404, { 'content-type': 'text/plain' });
    res.end('not found');
  }
};

initApp({
  store,
  createClaimer,
  GAMES,
  gameName,
  hashPassword,
  verifyPassword,
  normalizeCookie,
  cookieValid,
  verifyCookie,
  BASE_URL,
  HOST,
  PORT,
  DISCORD_ID,
  DISCORD_SECRET,
  lanUrls,
  serveStatic,
  runtimeName: `node ${process.version}`,
  startedAt,
  CLIENT_LUA: readFileSync(join(PUBLIC, 'scripts/vexora-client.lua'), 'utf8'),
  CLAIMER_LUA: readFileSync(join(PUBLIC, 'scripts/vexora-claimer.lua'), 'utf8'),
});

const server = createServer(handle);
startClaimer();

server.listen(PORT, HOST, () => {
  console.log(`[vexora] listening on http://${HOST}:${PORT}`);
  console.log(`[vexora] claimer engine started (${process.platform})`);
  console.log(`[vexora] auth: username + password${DISCORD_ID && DISCORD_SECRET ? ' (discord oauth on)' : ''}`);
  console.log(`[vexora] ${store.raw().users.length} members, ${store.raw().hits.length} hits`);
});

for (const sig of ['SIGINT', 'SIGTERM']) {
  process.on(sig, () => {
    store.flush();
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(0), 500);
  });
}
