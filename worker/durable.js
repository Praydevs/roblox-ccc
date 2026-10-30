import handle, { initApp, setBaseUrl } from '../server/app.js';
import { createStore, GAMES, gameName } from './store.js';
import { createClaimer, normalizeCookie, cookieValid, verifyCookie } from './claimer.js';
import { hashPassword, verifyPassword } from './passwords.js';
import { makeReq, makeRes } from './shim.js';
import CLIENT_LUA from '../server/scripts/vexora-client.lua';
import CLAIMER_LUA from '../server/scripts/vexora-claimer.lua';

// One object holds the whole dashboard, which also makes every read and write
// serialized and consistent. Storage is SQLite, so the document survives
// eviction and redeploys.
export class Vexora {
  constructor(ctx, env) {
    this.ctx = ctx;
    this.env = env;
    this.store = createStore({ sql: ctx.storage.sql });

    initApp({
      store: this.store,
      createClaimer,
      GAMES,
      gameName,
      hashPassword,
      verifyPassword,
      normalizeCookie,
      cookieValid,
      verifyCookie,
      BASE_URL: env.PUBLIC_URL ?? 'http://localhost',
      SCRIPT_SECRET: env.SCRIPT_SECRET ?? env.PUBLIC_URL ?? 'vexora',
      HOST: 'cloudflare',
      PORT: 443,
      DISCORD_ID: env.DISCORD_CLIENT_ID ?? '',
      DISCORD_SECRET: env.DISCORD_CLIENT_SECRET ?? '',
      ACCOUNT_API_URL: env.ACCOUNT_API_URL ?? undefined,
      ACCOUNT_API_KEY: env.ACCOUNT_API_KEY ?? '',
      lanUrls: () => [],
      runtimeName: 'workerd',
      startedAt: Date.now(),
      CLIENT_LUA,
      CLAIMER_LUA,
    });
  }

  async fetch(request) {
    const url = new URL(request.url);
    const body = request.method === 'GET' || request.method === 'HEAD' ? '' : await request.text();
    const req = makeReq(request, body);
    const res = makeRes(request);

    setBaseUrl(this.env.PUBLIC_URL ?? url.origin);

    try {
      await handle(req, res);
    } catch (err) {
      console.error('[vexora]', err);
      res.writeHead(500, { 'content-type': 'application/json; charset=utf-8' });
      res.end(JSON.stringify({ error: 'Internal server error' }));
    }

    this.store.flush();
    return res.finish();
  }
}
