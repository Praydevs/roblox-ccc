// Minimal Node-flavoured req/res over a Workers Request, enough for the router
// in server/app.js (headers, socket, data/end events, writeHead/write/end).

const HOP_BY_HOP = new Set(['connection', 'keep-alive', 'transfer-encoding', 'upgrade']);

export const makeReq = (request, body) => {
  const url = new URL(request.url);
  const headers = {};
  for (const [key, value] of request.headers) headers[key.toLowerCase()] = value;

  const handlers = { data: [], end: [], close: [], aborted: [], error: [] };
  const req = {
    url: `${url.pathname}${url.search}`,
    method: request.method,
    headers,
    socket: { remoteAddress: headers['cf-connecting-ip'] ?? '127.0.0.1', encrypted: url.protocol === 'https:' },
    on(event, fn) {
      (handlers[event] ??= []).push(fn);
      if (event === 'data' && body) fn(toBytes(body));
      if (event === 'end') queueMicrotask(fn);
      return req;
    },
  };

  request.signal?.addEventListener?.('abort', () => {
    for (const fn of handlers.close) fn();
    for (const fn of handlers.aborted) fn();
  });

  return req;
};

const toBytes = (chunk) => (typeof chunk === 'string' ? new TextEncoder().encode(chunk) : chunk);

export const makeRes = (request) => {
  let status = 200;
  let headers = {};
  let ended = false;
  let live = false;
  let controller = null;
  const chunks = [];

  const enqueue = (chunk) => {
    const bytes = toBytes(chunk);
    if (live) {
      try { controller?.enqueue(bytes); } catch { /* client gone */ }
    } else {
      chunks.push(bytes);
    }
  };

  const res = {
    writeHead(code, nextHeaders = {}) {
      status = code;
      headers = { ...headers, ...nextHeaders };
      return res;
    },
    write(chunk) { enqueue(chunk); return true; },
    end(chunk) {
      if (chunk !== undefined) enqueue(chunk);
      ended = true;
      if (live) {
        try { controller?.close(); } catch { /* already closed */ }
      }
    },
    closeStream() {
      ended = true;
      if (live) {
        try { controller?.close(); } catch { /* already closed */ }
      }
    },
    finish() {
      const clean = {};
      for (const [key, value] of Object.entries(headers)) {
        if (HOP_BY_HOP.has(key.toLowerCase())) continue;
        clean[key] = String(value);
      }
      if (ended) {
        const size = chunks.reduce((n, c) => n + c.length, 0);
        const merged = new Uint8Array(size);
        let at = 0;
        for (const c of chunks) { merged.set(c, at); at += c.length; }
        const bodyOut = request.method === 'HEAD' || status === 204 || status === 304 ? null : merged;
        return new Response(bodyOut, { status, headers: clean });
      }

      const stream = new ReadableStream({
        start(c) {
          controller = c;
          for (const chunk of chunks) c.enqueue(chunk);
          chunks.length = 0;
          live = true;
        },
        cancel() { ended = true; },
      });
      request.signal?.addEventListener?.('abort', () => res.closeStream());
      return new Response(stream, { status, headers: clean });
    },
  };

  return res;
};
