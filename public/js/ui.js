const PATHS = {
  overview: '<rect x="3" y="3" width="7" height="9" rx="1.5"/><rect x="14" y="3" width="7" height="5" rx="1.5"/><rect x="14" y="12" width="7" height="9" rx="1.5"/><rect x="3" y="16" width="7" height="5" rx="1.5"/>',
  hits: '<path d="M3 12h3.6L9 6.2l4.2 11.6 2.3-5.3H21"/>',
  globe: '<circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3a15 15 0 0 1 0 18 15 15 0 0 1 0-18"/>',
  trophy: '<path d="M8 21h8M12 17v4M7 4h10v5a5 5 0 0 1-10 0z"/><path d="M17 6h3v2a3 3 0 0 1-3 3M7 6H4v2a3 3 0 0 0 3 3"/>',
  code: '<path d="M9 18l-6-6 6-6M15 6l6 6-6 6"/>',
  users: '<path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M22 21v-2a4 4 0 0 0-3-3.87M16 3.13a4 4 0 0 1 0 7.75"/>',
  shield: '<path d="M12 3l7.5 3v5.2c0 4.6-3.1 8.3-7.5 10.3-4.4-2-7.5-5.7-7.5-10.3V6L12 3z"/>',
  sliders: '<path d="M4 21v-7M4 10V3M12 21v-9M12 8V3M20 21v-5M20 12V3"/><path d="M1 14h6M9 8h6M17 16h6"/>',
  logout: '<path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4M16 17l5-5-5-5M21 12H9"/>',
  search: '<circle cx="11" cy="11" r="7"/><path d="M20 20l-3.5-3.5"/>',
  download: '<path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4M7 10l5 5 5-5M12 15V3"/>',
  refresh: '<path d="M21 12a9 9 0 1 1-3-6.7L21 8"/><path d="M21 3v5h-5"/>',
  copy: '<rect x="9" y="9" width="12" height="12" rx="2"/><path d="M5 15H4a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1h10a1 1 0 0 1 1 1v1"/>',
  check: '<path d="M20 6L9 17l-5-5"/>',
  x: '<path d="M18 6L6 18M6 6l12 12"/>',
  plus: '<path d="M12 5v14M5 12h14"/>',
  trash: '<path d="M3 6h18M8 6V4a1 1 0 0 1 1-1h6a1 1 0 0 1 1 1v2M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6"/>',
  ban: '<circle cx="12" cy="12" r="9"/><path d="M5.6 5.6l12.8 12.8"/>',
  menu: '<path d="M3 6h18M3 12h18M3 18h18"/>',
  arrowUp: '<path d="M12 19V5M5 12l7-7 7 7"/>',
  arrowDown: '<path d="M12 5v14M19 12l-7 7-7-7"/>',
  bolt: '<path d="M13 2L3 14h7l-1 8 10-12h-7l1-8z"/>',
  fire: '<path d="M12 3q1 4 4 6.5t3 5.5a1 1 0 0 1-14 0 5 5 0 0 1 1-3 1 1 0 0 0 5 0c0-2-1.5-3-1.5-5q0-2 2.5-4"/>',
  coin: '<circle cx="12" cy="12" r="9"/><path d="M15 9.5A3 3 0 0 0 12 8c-1.7 0-3 .9-3 2s1.3 2 3 2 3 .9 3 2-1.3 2-3 2a3 3 0 0 1-3-1.5"/>',
  radio: '<circle cx="12" cy="12" r="2"/><path d="M5 12a7 7 0 0 1 7-7M19 12a7 7 0 0 0-7-7M2 12a10 10 0 0 1 10-10M22 12a10 10 0 0 0-10-10"/>',
  external: '<path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6"/><path d="M15 3h6v6M10 14L21 3"/>',
  gamepad: '<path d="M6 12h4M8 10v4M15 11h.01M18 13h.01"/><rect x="2" y="6" width="20" height="12" rx="5"/>',
  cpu: '<rect x="4" y="4" width="16" height="16" rx="3"/><path d="M9 2v2M15 2v2M9 20v2M15 20v2M2 9h2M2 15h2M20 9h2M20 15h2"/>',
  user: '<circle cx="12" cy="8" r="4"/><path d="M4 21v-1a6 6 0 0 1 6-6h4a6 6 0 0 1 6 6v1"/>',
};

export const icon = (name, size = 16) =>
  `<svg width="${size}" height="${size}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${PATHS[name] ?? ''}</svg>`;

export const esc = (value) =>
  String(value ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

export const nf = (n) => new Intl.NumberFormat(undefined, { maximumFractionDigits: 0 }).format(Number(n) || 0);

export const money = (n) => {
  const v = Number(n) || 0;
  if (v >= 1_000_000) return `${(v / 1_000_000).toFixed(2)}M`;
  if (v >= 10_000) return `${(v / 1000).toFixed(1)}K`;
  return new Intl.NumberFormat(undefined, { maximumFractionDigits: 2 }).format(v);
};

export const timeAgo = (ts) => {
  const diff = Math.max(0, Date.now() - ts);
  const m = Math.floor(diff / 60000);
  if (m < 1) return 'now';
  if (m < 60) return `${m}m`;
  const h = Math.floor(m / 60);
  if (h < 24) return `${h}h`;
  const d = Math.floor(h / 24);
  return `${d}d`;
};

export const stamp = (ts) =>
  new Date(ts).toLocaleString(undefined, { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });

export const duration = (sec) => {
  const s = Math.floor(sec);
  const d = Math.floor(s / 86400);
  const h = Math.floor((s % 86400) / 3600);
  const m = Math.floor((s % 3600) / 60);
  if (d) return `${d}d ${h}h`;
  if (h) return `${h}h ${m}m`;
  return `${m}m ${s % 60}s`;
};

export const avatar = (user, size = 28) => {
  if (user?.avatar) return `<img src="${esc(user.avatar)}" alt="" width="${size}" height="${size}" style="border-radius:50%;object-fit:cover;flex:none" />`;
  const initial = String(user?.username ?? '?').charAt(0).toUpperCase();
  return `<span class="ava-fallback" style="width:${size}px;height:${size}px">${esc(initial)}</span>`;
};

/* ---------- toasts ---------- */
const toastHost = () => {
  let el = document.querySelector('.toasts');
  if (!el) {
    el = document.createElement('div');
    el.className = 'toasts';
    document.body.appendChild(el);
  }
  return el;
};

export const toast = (message, tone = 'success') => {
  const host = toastHost();
  const el = document.createElement('div');
  el.className = `toast ${tone}`;
  el.innerHTML = `<i></i><span>${esc(message)}</span>`;
  host.appendChild(el);
  setTimeout(() => {
    el.classList.add('leaving');
    setTimeout(() => el.remove(), 240);
  }, 3200);
};

/* ---------- modal ---------- */
export const modal = ({ title, description = '', body = '', confirmText = 'Confirm', cancelText = 'Cancel', tone = 'primary', onSubmit }) =>
  new Promise((resolve) => {
    const host = document.createElement('div');
    host.className = 'modal-backdrop';
    host.innerHTML = `
      <div class="modal" role="dialog" aria-modal="true">
        <div class="modal-head">
          <div>
            <h3>${esc(title)}</h3>
            ${description ? `<p>${esc(description)}</p>` : ''}
          </div>
          <button class="x" data-close aria-label="Close">${icon('x', 15)}</button>
        </div>
        <form>
          <div class="modal-body">${body}</div>
          <div class="modal-foot">
            <button type="button" class="btn btn-ghost" data-close>${esc(cancelText)}</button>
            <button type="submit" class="btn ${tone === 'danger' ? 'btn-danger' : 'btn-primary'}">${esc(confirmText)}</button>
          </div>
        </form>
      </div>`;

    const close = (value) => { host.remove(); document.removeEventListener('keydown', onKey); resolve(value); };
    const onKey = (e) => { if (e.key === 'Escape') close(null); };
    document.addEventListener('keydown', onKey);
    host.addEventListener('click', (e) => {
      if (e.target === host || e.target.closest('[data-close]')) close(null);
    });
    host.querySelector('form').addEventListener('submit', async (e) => {
      e.preventDefault();
      const data = Object.fromEntries(new FormData(e.target).entries());
      if (onSubmit) {
        const submitBtn = e.target.querySelector('button[type=submit]');
        submitBtn.disabled = true;
        const result = await onSubmit(data, { close });
        submitBtn.disabled = false;
        if (result === false) return;
      }
      close(data);
    });
    document.body.appendChild(host);
    host.querySelector('input,textarea,select')?.focus();
  });

export const copyText = async (text) => {
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch {
    const ta = document.createElement('textarea');
    ta.value = text;
    document.body.appendChild(ta);
    ta.select();
    const ok = document.execCommand('copy');
    ta.remove();
    return ok;
  }
};
