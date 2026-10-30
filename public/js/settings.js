import { api, downloadCsv } from './api.js';
import { icon, esc, nf, money, stamp, toast, modal, copyText } from './ui.js';

export async function settings(root, ctx) {
  const [cfg, stats] = await Promise.all([api.config(), api.stats()]);

  root.innerHTML = `
    <div class="page-head">
      <div class="titles">
        <div class="eyebrow">Account</div>
        <h1>Settings</h1>
        <p>Your identity, keys and data. Everything here is scoped to this account only.</p>
      </div>
    </div>

    <div class="stack">
      <div class="grid-2">
        <div class="card">
          <div class="card-head"><div><h2>Profile</h2><p>Who this dashboard is signed in as.</p></div></div>
          <div class="card-body">
            <div class="kv">
              <div><span>Username</span><b>${esc(ctx.user.username)}</b></div>
              <div><span>Role</span><b>${esc(ctx.user.role)}</b></div>
              <div><span>Password</span><b>${ctx.user.password_set ? 'set' : 'not set'}</b></div>
              <div><span>Joined</span><b>${esc(stamp(ctx.user.created_at))}</b></div>
              <div><span>Hits</span><b>${nf(stats.mine.hits)}</b></div>
              <div><span>Value</span><b>${money(stats.mine.value)}</b></div>
              <div><span>Servers</span><b>${nf(stats.mine.servers)}</b></div>
            </div>
          </div>
        </div>

        <div class="card">
          <div class="card-head"><div><h2>API key</h2><p>Send it as a Bearer token from your own tooling.</p></div></div>
          <div class="card-body">
            <div style="display:flex;gap:6px">
              <input class="input mono" value="${esc(cfg.api_key)}" readonly />
              <button class="btn btn-icon" id="copy-key" title="Copy key">${icon('copy', 15)}</button>
            </div>
            <p class="hint" style="margin-top:10px">Webhook token and loadstring live on the script page.</p>
            <a class="btn" href="/script" data-link style="margin-top:12px;width:100%">Open script config</a>
          </div>
        </div>
      </div>

      <div class="card">
        <div class="card-head"><div><h2>Your data</h2><p>Export or wipe the hits tied to this account.</p></div></div>
        <div class="card-body">
          <div class="kv">
            <div><span>Total hits</span><b>${nf(stats.mine.hits)}</b></div>
            <div><span>Today</span><b>${nf(stats.mine.today)}</b></div>
            <div><span>Tracked value</span><b>${money(stats.mine.value)}</b></div>
            <div><span>Receivers</span><b>${nf(stats.mine.receivers)}</b></div>
          </div>
          <div style="display:flex;gap:8px;margin-top:16px;flex-wrap:wrap">
            <button class="btn" id="export">${icon('download', 13)} Export CSV</button>
            <button class="btn btn-danger" id="clear">${icon('trash', 13)} Clear my hits</button>
          </div>
          <p class="hint" style="margin-top:10px">Clearing removes every hit owned by this account. Other accounts are untouched.</p>
        </div>
      </div>
    </div>`;

  root.querySelector('#copy-key').addEventListener('click', async () => {
    const ok = await copyText(cfg.api_key);
    toast(ok ? 'API key copied' : 'Copy failed', ok ? 'success' : 'error');
  });

  root.querySelector('#export').addEventListener('click', downloadCsv);

  root.querySelector('#clear').addEventListener('click', async () => {
    const result = await modal({
      title: 'Clear your hits?',
      description: `${nf(stats.mine.hits)} hits will be permanently removed from this account.`,
      tone: 'danger',
      confirmText: 'Delete my hits',
      body: '<p class="hint">This cannot be undone. Your config, receivers and API key stay untouched.</p>',
      onSubmit: async () => {
        const res = await api.clearHits();
        toast(`Removed ${nf(res.removed)} hits`);
      },
    });
    if (result) ctx.navigate('/settings', { push: false });
  });

  return () => {};
}
