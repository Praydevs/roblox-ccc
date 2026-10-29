import { api } from './api.js';
import { icon, esc, avatar, toast, money } from './ui.js';
import * as pages from './pages.js';
import * as admin from './admin.js';
import { settings } from './settings.js';

const NAV = [
  { group: 'Main' },
  { path: '/overview', label: 'Overview', icon: 'overview', render: pages.overview },
  { path: '/hits', label: 'Hits', icon: 'hits', render: pages.hits },
  { path: '/public-hits', label: 'Public hits', icon: 'globe', render: pages.publicHits, adminOnly: true },
  { path: '/servers', label: 'Servers', icon: 'radio', render: pages.servers },
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
      <div class="brand-mark">SYN</div>
      <div class="brand-text"><strong>Syn Scripts</strong><span>Dashboard</span></div>
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
        <div class="crumb">Syn Scripts <b>/ ${esc(TITLES[path] ?? 'Overview')}</b></div>
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

const loginScreen = (message = '') => `
  <div class="aurora"></div>
  <div class="login-wrap">
    <div class="login-card">
      <div class="mark">SYN</div>
      <h1>Welcome to Syn</h1>
      <p>Sign in to track your hits, manage receivers and climb the network.</p>
      ${message ? `<div class="badge missed" style="margin-bottom:14px;display:inline-flex">${esc(message)}</div>` : ''}
      <a class="btn btn-discord" href="/auth/discord" style="width:100%;padding:10px">Continue with Discord</a>
      <div class="divider">or local demo</div>
      <form class="login-form" id="dev-form">
        <div class="field">
          <label for="dev-name">Username</label>
          <input class="input" id="dev-name" name="username" placeholder="e.g. onyx" autocomplete="username" required minlength="2" />
        </div>
        <button class="btn btn-primary" type="submit" style="margin-top:4px">Continue</button>
      </form>
      <p class="login-note">Discord OAuth needs DISCORD_CLIENT_ID and DISCORD_CLIENT_SECRET. Without them the dashboard runs in demo mode with local accounts.</p>
    </div>
  </div>`;

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
        <div class="login-wrap">
          <div class="login-card">
            <div class="mark">${icon('ban', 20)}</div>
            <h1>You have been banned from Syn Scripts.</h1>
            <p>${esc(user.ban_reason ?? 'Contact an administrator for details.')}</p>
          </div>
        </div>`;
      hideBoot();
      return;
    }
  } catch (err) {
    if (err.status === 401) {
      if (soft) return;
      root.innerHTML = loginScreen();
      root.querySelector('#dev-form')?.addEventListener('submit', async (e) => {
        e.preventDefault();
        const username = new FormData(e.target).get('username');
        try {
          await api.devLogin(username);
          boot();
        } catch (loginErr) {
          toast(loginErr.message, 'error');
        }
      });
      hideBoot();
      return;
    }
    root.innerHTML = loginScreen(err.message);
    hideBoot();
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
