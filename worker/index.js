import { Vexora } from './durable.js';

export { Vexora };

// Dashboard API, auth, generated Lua and health go through the Durable Object.
// Everything else is a static asset from public/, with SPA fallback to index.html.
const API_PATH = /^\/(api|auth|raw)(\/|$)/;

export default {
  async fetch(request, env) {
    const { pathname } = new URL(request.url);

    // Templates live outside public/, but never let an old asset URL serve them.
    if (/^\/scripts\/.+\.lua$/i.test(pathname)) {
      return new Response('-- not found', { status: 404, headers: { 'content-type': 'text/plain' } });
    }

    if (pathname === '/health' || API_PATH.test(pathname)) {
      const id = env.VEXORA.idFromName('dashboard');
      return env.VEXORA.get(id).fetch(request);
    }

    return env.ASSETS.fetch(request);
  },
};
