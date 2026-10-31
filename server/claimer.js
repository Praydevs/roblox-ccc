import { spawn } from 'node:child_process';
import { existsSync, mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';

const AUTHENTICATED = 'https://users.roblox.com/v1/users/authenticated';
const AUTH_TICKET = 'https://auth.roblox.com/v1/authentication-ticket';
const PLACE_LAUNCHER = 'https://assetgame.roblox.com/game/PlaceLauncher.ashx';
const UA = 'Roblox/WinInet';

const JOIN_GAP_MS = 25_000;
const JOB_TTL_MS = 8 * 60_000;
const LEASE_MS = 90_000;
const MAX_ACCOUNTS = 5;
const MAX_JOBS = 60;
const AUTOEXEC_FILE = 'vexora-claimer.lua';

// ---------- cookie helpers ----------
export const normalizeCookie = (raw) => {
  const c = String(raw ?? '').trim().replace(/^\.?ROBLOSECURITY=/i, '').trim().replace(/^"|"$/g, '');
  if (!c) return '';
  if (c.startsWith('_|')) return c;
  if (c.startsWith('WARNING')) return `_|${c}`;
  return c;
};

export const cookieValid = (c) => typeof c === 'string' && c.startsWith('_|') && c.length >= 80;

export const maskCookie = (c) => (c ? `_|••••${c.slice(-6)}` : null);

const clean = (v, n) => String(v ?? '').replace(/[<>\r\n]/g, '').trim().slice(0, n);

const peerDryRun = () => process.env.VEXORA_CLAIM_DRY === '1';

// ---------- roblox ----------
const fetchJson = async (url, options = {}) => {
  const res = await fetch(url, { signal: AbortSignal.timeout(15_000), ...options });
  const text = await res.text();
  let body = null;
  try { body = text ? JSON.parse(text) : null; } catch { body = null; }
  return { res, body, text };
};

export async function verifyCookie(cookie) {
  if (peerDryRun()) return { ok: true, username: 'dry-run', id: 0 };
  const { res, body } = await fetchJson(AUTHENTICATED, {
    headers: { cookie: `.ROBLOSECURITY=${cookie}`, 'user-agent': UA },
  }).catch((err) => ({ res: { ok: false, status: 0 }, body: { message: err.message } }));

  if (!res.ok) {
    const reason = body?.errors?.[0]?.message ?? body?.message ?? `HTTP ${res.status || 'error'}`;
    return { ok: false, error: res.status === 401 ? 'Roblox rejected this cookie.' : reason };
  }
  return { ok: true, username: body?.name ?? 'unknown', display: body?.displayName ?? body?.name, id: body?.id };
}

async function authTicket(cookie) {
  const post = (csrf) => fetch(AUTH_TICKET, {
    method: 'POST',
    headers: {
      cookie: `.ROBLOSECURITY=${cookie}`,
      'content-type': 'application/json',
      'user-agent': UA,
      'x-csrf-token': csrf ?? '',
    },
    body: '{}',
    signal: AbortSignal.timeout(15_000),
  });

  let res = await post();
  if (res.status === 403) {
    const csrf = res.headers.get('x-csrf-token');
    if (!csrf) throw new Error('Roblox refused the auth ticket (403, no csrf token)');
    res = await post(csrf);
  }
  if (res.status === 401) throw new Error('cookie expired - sign into Roblox again and paste a fresh one');
  if (!res.ok) throw new Error(`auth ticket failed (${res.status})`);

  const ticket = res.headers.get('rbx-authentication-ticket');
  if (!ticket) throw new Error('no authentication ticket returned');
  return ticket;
}

const trackerId = () => String(Math.floor(1e9 + Math.random() * 9e9));

export function buildLauncherUrl({ placeId, serverId, tracker = trackerId() }) {
  const url = new URL(PLACE_LAUNCHER);
  url.searchParams.set('request', 'RequestGameJob');
  url.searchParams.set('browserTrackerId', tracker);
  url.searchParams.set('placeId', String(placeId));
  url.searchParams.set('gameId', String(serverId));
  url.searchParams.set('isPlayTogetherGame', 'false');
  return url;
}

export function buildLaunchUrl({ ticket, launcher, tracker }) {
  return 'roblox-player:1'
    + '+launchmode:play'
    + `+gameinfo:${ticket}`
    + `+launchtime:${Date.now()}`
    + `+placelauncherurl:${encodeURIComponent(String(launcher))}`
    + `+browsertrackerid:${tracker}`
    + '+robloxLocale:en_us'
    + '+gameLocale:en_us'
    + '+channel:'
    + '+LaunchExp:InApp';
}

async function requestJoin({ cookie, placeId, serverId, ticket }) {
  const tracker = trackerId();
  const launcher = buildLauncherUrl({ placeId, serverId, tracker });
  const { res, body } = await fetchJson(launcher, {
    headers: {
      cookie: `.ROBLOSECURITY=${cookie}`,
      AuthenticationTicket: ticket,
      'user-agent': UA,
    },
  });

  if (!res.ok) {
    if (res.status === 401) throw new Error('cookie expired - sign into Roblox again');
    throw new Error(body?.message ?? `join request failed (${res.status})`);
  }
  if (body?.status !== 2 || !body?.joinScriptUrl) {
    const msg = body?.message ?? `server not joinable (status ${body?.status ?? '?'})`;
    throw new Error(/full/i.test(msg) ? 'that server is full' : msg);
  }
  return { tracker, launcher: launcher.toString(), ticket: body.authenticationTicket ?? ticket };
}

export function launchProtocol(url) {
  if (process.env.VEXORA_CLAIM_DRY === '1') return { ok: true, dry: true };

  const [cmd, args] = process.platform === 'win32'
    ? ['cmd.exe', ['/c', 'start', '', url]]
    : process.platform === 'darwin'
      ? ['open', [url]]
      : ['xdg-open', [url]];

  return new Promise((resolve, reject) => {
    let child;
    try {
      child = spawn(cmd, args, { detached: true, stdio: 'ignore', windowsHide: true });
    } catch (err) {
      reject(err);
      return;
    }
    child.once('error', reject);
    child.once('spawn', () => {
      child.unref();
      resolve({ ok: true });
    });
  });
}

// ---------- autoexec ----------
export function autoexecCandidates() {
  const out = [];
  if (process.env.VEXORA_CLAIM_AUTOEXEC) out.push(process.env.VEXORA_CLAIM_AUTOEXEC);
  const local = process.env.LOCALAPPDATA;
  if (local) {
    const executors = ['Wave', 'Delta', 'Solara', 'Fluxus', 'Electron', 'Valyse', 'Nihon', 'AWP',
      'Swift', 'Synapse', 'Xeno', 'Sirhurt', 'Krnl', 'Azure', 'Cryptic', 'Codex', 'Velocity'];
    for (const name of executors) {
      for (const folder of ['autoexec', 'AutoExec', 'auto execute', 'Auto Execute']) {
        out.push(join(local, name, folder));
      }
    }
  }
  return [...new Set(out)];
}

export const detectedAutoexecDirs = () => autoexecCandidates().filter((dir) => existsSync(dir));

// ---------- engine ----------
export function createClaimer({
  store,
  scriptUrlFor = () => null,
  apiInfoFor = () => null,
  runtimeFor = () => null,
  hitsFor = () => [],
  log = console,
}) {
  const state = {
    running: false,
    busy: false,
    lastTick: null,
    lastJoin: null,
    lastError: null,
    nextAllowedAt: 0,
  };

  const accountsOf = (user) => user.claimer?.accounts ?? [];

  const accountReady = (account) => account && account.status !== 'invalid' && cookieValid(account.cookie);

  // drop targets whose server window passed and hand stuck leases back to the queue
  const expire = (user) => {
    const now = Date.now();
    const cutoff = now - JOB_TTL_MS;
    const lease = now - LEASE_MS;
    for (const job of store.claims(user.id)) {
      if (job.status === 'queued' && job.created_at < cutoff) {
        store.updateClaim(job.id, { status: 'expired', finished_at: now, error: 'server window elapsed' });
      } else if (job.status === 'joining' && (job.assigned_at ?? job.started_at ?? job.created_at) < lease) {
        store.updateClaim(job.id, { status: 'queued', account_id: null, account_name: null, assigned_at: null });
      }
    }
  };

  // newest first: the freshest hit is the one whose server is still live
  const nextJob = (user) => store.claims(user.id)
    .filter((j) => j.status === 'queued' && j.created_at > Date.now() - JOB_TTL_MS)
    .sort((a, b) => b.created_at - a.created_at)[0] ?? null;

  const pickAccount = (user) => accountsOf(user)
    .filter(accountReady)
    .sort((a, b) => (a.last_join ?? 0) - (b.last_join ?? 0))[0] ?? null;

  function writeAutoexec(user) {
    const cfg = user.claimer ?? {};
    if (!cfg.autoexec) return { path: null, skipped: true };
    const dir = cfg.autoexec_path && cfg.autoexec_path.trim()
      ? cfg.autoexec_path.trim()
      : detectedAutoexecDirs()[0];
    if (!dir) return { error: 'no executor autoexec folder found - set the path by hand' };
    const url = scriptUrlFor(user);
    if (!url) return { error: 'no claimer loadstring available' };
    try {
      mkdirSync(dir, { recursive: true });
      const file = join(dir, AUTOEXEC_FILE);
      const line = `loadstring(game:HttpGet("${url}"))()`;
      writeFileSync(file, `${line}\n`, 'utf8');
      return { path: file };
    } catch (err) {
      return { error: `could not write autoexec: ${err.message}` };
    }
  }

  async function joinWith(user, account, job) {
    const dry = peerDryRun();
    if (!dry) {
      const ticket = await authTicket(account.cookie);
      const join = await requestJoin({
        cookie: account.cookie,
        placeId: job.place_id,
        serverId: job.server_id,
        ticket,
      });
      const launchUrl = buildLaunchUrl({ ticket: join.ticket, launcher: join.launcher, tracker: join.tracker });
      await launchProtocol(launchUrl);
      log.log(`[vexora] claimer joined ${job.server_id.slice(0, 8)}… on ${account.username}`);
    } else {
      log.log(`[vexora] claimer dry-run join ${job.server_id} on ${account.username}`);
    }
    return { dry };
  }

  async function runJob(user, job, account, { manual = false } = {}) {
    if (state.busy) return { ok: false, error: 'another join is already in flight' };
    state.busy = true;
    job.status = 'joining';
    job.attempts = (job.attempts ?? 0) + 1;
    job.account_id = account.id;
    job.account_name = account.username;
    job.started_at = Date.now();
    store.updateClaim(job.id, job);

    try {
      const seed = writeAutoexec(user);
      if (seed.path) job.autoexec_path = seed.path;
      if (seed.error) job.autoexec_error = seed.error;

      await joinWith(user, account, job);

      store.updateClaim(job.id, {
        ...job,
        status: 'joined',
        finished_at: Date.now(),
        error: null,
      });
      account.last_join = Date.now();
      account.last_error = null;
      account.status = 'ready';
      user.last_seen = Date.now();
      store.saveUser(user);
      state.lastJoin = { at: Date.now(), server_id: job.server_id, account: account.username, manual };
      state.lastError = null;
      state.nextAllowedAt = Date.now() + JOIN_GAP_MS;
      return { ok: true };
    } catch (err) {
      const message = String(err.message ?? err);
      job.status = 'failed';
      job.finished_at = Date.now();
      job.error = message;
      store.updateClaim(job.id, job);
      account.last_error = message;
      if (/cookie|expired|rejected|401/i.test(message)) account.status = 'invalid';
      store.saveUser(user);
      state.lastError = { at: Date.now(), message };
      state.nextAllowedAt = Date.now() + Math.min(JOIN_GAP_MS, 8_000);
      log.warn(`[vexora] claimer join failed: ${message}`);
      return { ok: false, error: message };
    } finally {
      state.busy = false;
      state.lastTick = Date.now();
    }
  }

  async function tick() {
    state.lastTick = Date.now();
    if (state.busy) return;
    if (Date.now() < state.nextAllowedAt) return;

    for (const user of store.raw().users) {
      if (user.role !== 'admin') continue;   // the engine launches clients on this host
      const cfg = user.claimer;
      if (!cfg?.engine_enabled) continue;    // separate from the lua joiner switch
      expire(user);
      if (state.busy || Date.now() < state.nextAllowedAt) return;
      const job = nextJob(user);
      if (!job) continue;
      if (!job.presence && (job.value ?? 0) < (cfg.min_value ?? 0)) {
        store.updateClaim(job.id, { status: 'skipped', finished_at: Date.now(), error: 'below claimer min value' });
        continue;
      }
      const account = pickAccount(user);
      if (!account) {
        if (state.lastError?.message !== 'no usable claimer account') {
          state.lastError = { at: Date.now(), message: 'no usable claimer account' };
        }
        return;
      }
      await runJob(user, job, account);
      return;
    }
  }

  async function joinNow(user, jobId) {
    const job = store.claims(user.id).find((j) => j.id === jobId);
    if (!job) return { ok: false, error: 'That target is gone.' };
    if (job.status === 'joined') return { ok: false, error: 'Already joined that server.' };
    const account = pickAccount(user);
    if (!account) return { ok: false, error: 'No usable claimer account - add one first.' };
    if (state.busy) return { ok: false, error: 'A join is already in flight.' };
    job.status = 'queued';
    return runJob(user, job, account, { manual: true });
  }

  function status(user) {
    const cfg = user.claimer ?? {};
    const jobs = store.claims(user.id).slice(0, 25);
    const today = new Date().setHours(0, 0, 0, 0);
    return {
      enabled: Boolean(cfg.enabled),
      auto_join: cfg.auto_join !== false,
      auto_arm: cfg.auto_arm === true,
      engine_enabled: cfg.engine_enabled === true,
      script: {
        url: scriptUrlFor(user),
        loadstring: scriptUrlFor(user) ? `loadstring(game:HttpGet("${scriptUrlFor(user)}"))()` : null,
      },
      api: apiInfoFor(user),
      runtime: runtimeFor(user),
      last_presence: user.last_presence ?? null,
      hits: hitsFor(user),
      autoexec: cfg.autoexec !== false,
      autoexec_path: cfg.autoexec_path ?? null,
      detected_paths: detectedAutoexecDirs(),
      min_value: Number(cfg.min_value) || 0,
      trades: (user.trades ?? []).slice(0, 20),
      claimed: (user.claimed ?? []).slice(0, 30),
      claimed_total: (user.claimed ?? []).length,
      claimed_value: (user.claimed ?? []).reduce((sum, row) => sum + (Number(row.value) || 0), 0),
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
        running: state.running,
        busy: state.busy,
        dry_run: peerDryRun(),
        platform: process.platform,
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
      id: randomUUID(),
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
    // auto_join keeps the queue warm even while the joiner is off, so arming it
    // later can send an alt into the newest hit immediately. a manual join
    // always queues, whatever the toggles say.
    const cfg = user.claimer ?? {};
    if (!force && !cfg.enabled && cfg.auto_join === false && !(cfg.accounts?.length ?? 0)) return null;
    const recent = store.claims(user.id).find((j) => j.server_id === job.server_id
      && j.place_id === job.place_id
      && j.created_at > Date.now() - 5 * 60_000
      && ['queued', 'joining', 'joined'].includes(j.status));
    if (recent) return null;
    if (store.claims(user.id).length >= MAX_JOBS) store.trimClaims(user.id, MAX_JOBS);

    const claim = {
      id: randomUUID(),
      user_id: user.id,
      game: job.game,
      item: job.item,
      victim: job.victim,
      value: job.value,
      place_id: job.place_id,
      server_id: job.server_id,
      requester: job.roblox_user ?? null,
      executor: job.executor ?? null,
      presence: job.presence === true,
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

  function start() {
    if (state.running) return;
    state.running = true;
    const loop = async () => {
      try { await tick(); } catch (err) { log.error('[vexora] claimer tick', err); }
      if (state.running) setTimeout(loop, 2_500).unref?.();
    };
    loop();
  }

  function stop() {
    state.running = false;
  }

  return {
    start, stop, tick, joinNow, status, addAccount, queueClaim, reap: expire,
    maxAccounts: MAX_ACCOUNTS, leaseMs: LEASE_MS,
  };
}
