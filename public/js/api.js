const request = async (path, options = {}) => {
  const res = await fetch(path, {
    credentials: 'same-origin',
    headers: options.body ? { 'content-type': 'application/json' } : undefined,
    ...options,
  });
  const text = await res.text();
  let data = null;
  try { data = text ? JSON.parse(text) : null; } catch { data = null; }
  if (!res.ok) {
    const err = new Error(data?.error ?? `Request failed (${res.status})`);
    err.status = res.status;
    err.data = data;
    throw err;
  }
  return data;
};

export const api = {
  me: () => request('/api/me'),
  config: () => request('/api/config'),
  saveConfig: (body) => request('/api/config', { method: 'PUT', body: JSON.stringify(body) }),
  testDelivery: () => request('/api/config/test', { method: 'POST', body: JSON.stringify({}) }),
  clearHits: () => request('/api/hits/clear', { method: 'POST', body: JSON.stringify({}) }),
  stats: () => request('/api/stats'),
  publicStats: () => request('/api/public/stats'),
  hits: (params) => request(`/api/hits?${new URLSearchParams(params)}`),
  publicHits: (params = {}) => request(`/api/hits/public?${new URLSearchParams(params)}`),
  leaderboard: (params) => request(`/api/leaderboard?${new URLSearchParams(params)}`),
  servers: (params = {}) => request(`/api/servers?${new URLSearchParams(params)}`),
  robloxSearch: (keyword) => request(`/api/roblox/search?keyword=${encodeURIComponent(keyword)}`),

  adminUsers: (params) => request(`/api/admin/users?${new URLSearchParams(params)}`),
  adminUpdateUser: (id, body) => request(`/api/admin/users/${encodeURIComponent(id)}`, { method: 'PUT', body: JSON.stringify(body) }),
  adminHits: (params) => request(`/api/admin/hits?${new URLSearchParams(params)}`),
  adminDeleteHit: (id) => request(`/api/admin/hits/${encodeURIComponent(id)}`, { method: 'DELETE' }),
  adminBlacklist: (params) => request(`/api/admin/blacklist?${new URLSearchParams(params)}`),
  adminAddBlacklist: (body) => request('/api/admin/blacklist', { method: 'POST', body: JSON.stringify(body) }),
  adminRemoveBlacklist: (id) => request(`/api/admin/blacklist/${encodeURIComponent(id)}`, { method: 'DELETE' }),
  adminSystem: () => request('/api/admin/system'),

  devLogin: (username) => request('/auth/dev', { method: 'POST', body: JSON.stringify({ username }) }),
  logout: () => request('/auth/logout', { method: 'POST' }),
};

export const downloadCsv = () => {
  const a = document.createElement('a');
  a.href = '/api/hits/export.csv';
  a.download = 'syn-hits.csv';
  document.body.appendChild(a);
  a.click();
  a.remove();
};
