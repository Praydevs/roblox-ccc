#!/usr/bin/env python3
"""Vexora desktop agent.

The claimer Lua cannot open another Roblox game when the executor blocks the
shell, and Roblox refuses a cross-experience TeleportService call with 773. This
agent runs on the PC that is signed into the alt: it watches elow.cc for the
newest queued target, asks Roblox for that account's auth ticket, and opens the
roblox-player: URL for the exact place and server. The Lua claimer then trades.

    python vexora-agent.py --site https://elow.cc --key <claimer-api-key>

The cookie is read from alt-cookie.txt next to this file, or --cookie-file.
Nothing is uploaded except the API key, the target id and a heartbeat.
"""

from __future__ import annotations

import argparse
import http.cookiejar
import json
import os
import random
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

VERSION = "1.0"
AUTHENTICATED = "https://users.roblox.com/v1/users/authenticated"
AUTH_TICKET = "https://auth.roblox.com/v1/authentication-ticket"
PLACE_LAUNCHER = "https://assetgame.roblox.com/game/PlaceLauncher.ashx"
BROWSER_UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
              "(KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36")


def log(message: str) -> None:
    print(time.strftime("[%H:%M:%S] ") + message, flush=True)


def normalize_cookie(raw: str) -> str:
    value = "".join((raw or "").split())
    value = value.split(";", 1)[0].strip().strip('"').strip("'")
    if "%" in value:
        value = urllib.parse.unquote(value)
    if value.lower().startswith(".roblosecurity="):
        value = value.split("=", 1)[1]
    if value.startswith("WARNING"):
        value = "_|" + value
    return value


def _session(cookie: str):
    jar = http.cookiejar.CookieJar()
    jar.set_cookie(http.cookiejar.Cookie(
        version=0, name=".ROBLOSECURITY", value=cookie,
        port=None, port_specified=False,
        domain=".roblox.com", domain_specified=True, domain_initial_dot=True,
        path="/", path_specified=True, secure=True, expires=None, discard=False,
        comment=None, comment_url=None, rest={}, rfc2109=False,
    ))
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
    opener.addheaders = [("user-agent", BROWSER_UA), ("accept", "application/json")]
    return opener


def _body(err: urllib.error.HTTPError, limit: int = 240) -> str:
    try:
        return err.read().decode("utf-8", "replace").strip()[:limit]
    except Exception:
        return ""


def whoami(cookie: str) -> dict:
    try:
        with _session(cookie).open(AUTHENTICATED, timeout=20) as res:
            return json.loads(res.read().decode("utf-8", "replace") or "{}")
    except urllib.error.HTTPError as err:
        if err.code == 401:
            raise RuntimeError("Roblox rejected that cookie (401). Copy a fresh .ROBLOSECURITY.")
        raise RuntimeError(f"cookie check failed: HTTP {err.code} {_body(err)}")
    except urllib.error.URLError as err:
        raise RuntimeError(f"network error: {err.reason}")


def auth_ticket(cookie: str) -> str:
    opener = _session(cookie)

    def post(csrf: str | None):
        headers = {
            "content-type": "application/json",
            "origin": "https://www.roblox.com",
            "referer": "https://www.roblox.com/",
            "accept": "application/json",
        }
        if csrf:
            headers["x-csrf-token"] = csrf
        req = urllib.request.Request(AUTH_TICKET, data=b"{}", method="POST", headers=headers)
        return opener.open(req, timeout=20)

    try:
        with post(None) as res:
            ticket = res.headers.get("rbx-authentication-ticket")
            if ticket:
                return ticket
            raise RuntimeError("no authentication ticket in the response")
    except urllib.error.HTTPError as err:
        if err.code == 401:
            raise RuntimeError("cookie expired (401); sign in again and copy a new one")
        if err.code != 403:
            raise RuntimeError(f"auth ticket failed: HTTP {err.code} {_body(err)}")
        csrf = err.headers.get("x-csrf-token")
        if not csrf:
            raise RuntimeError("Roblox refused the auth ticket (403, no CSRF token)")
        try:
            with post(csrf) as res:
                ticket = res.headers.get("rbx-authentication-ticket")
                if not ticket:
                    raise RuntimeError("no authentication ticket after the CSRF retry")
                return ticket
        except urllib.error.HTTPError as retry:
            raise RuntimeError(f"auth ticket refused ({retry.code}): {_body(retry)}")


def launch_url(cookie: str, place_id: str, server_id: str) -> str:
    ticket = auth_ticket(cookie)
    tracker = str(random.randint(1_000_000_000, 9_999_999_999))
    params = {
        "browserTrackerId": tracker,
        "placeId": str(place_id),
        "isPlayTogetherGame": "false",
        "request": "RequestGameJob",
        "gameId": str(server_id),
    }
    launcher = f"{PLACE_LAUNCHER}?{urllib.parse.urlencode(params)}"
    return (
        "roblox-player:1+launchmode:play"
        f"+gameinfo:{ticket}"
        f"+launchtime:{int(time.time() * 1000)}"
        f"+placelauncherurl:{urllib.parse.quote(launcher, safe='')}"
        f"+browsertrackerid:{tracker}"
        "+robloxLocale:en_us+gameLocale:en_us+channel:+LaunchExp:InApp"
    )


def open_protocol(url: str, dry_run: bool = False) -> None:
    if dry_run:
        log(f"would open: {url[:110]}...")
        return
    if sys.platform.startswith("win"):
        os.startfile(url)  # type: ignore[attr-defined]
    elif sys.platform == "darwin":
        subprocess.Popen(["open", url])
    else:
        subprocess.Popen(["xdg-open", url])


def api(site: str, key: str, path: str, body: dict | None = None, timeout: int = 20) -> dict:
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(
        site.rstrip("/") + path,
        data=data,
        method="POST" if body is not None else "GET",
        headers={
            "x-api-key": key,
            "content-type": "application/json",
            "accept": "application/json",
            "user-agent": f"VexoraAgent/{VERSION}",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as res:
            raw = res.read().decode("utf-8", "replace")
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as err:
        detail = _body(err)
        if err.code in (401, 403):
            raise RuntimeError("the dashboard rejected the API key")
        raise RuntimeError(f"dashboard HTTP {err.code}: {detail}")
    except urllib.error.URLError as err:
        raise RuntimeError(f"dashboard unreachable: {err.reason}")


def write_autoexec(folder: str, script_url: str) -> None:
    if not folder or not script_url:
        return
    target = Path(folder)
    if not target.is_dir():
        log(f"autoexec folder does not exist: {folder}")
        return
    try:
        req = urllib.request.Request(script_url, headers={"user-agent": f"VexoraAgent/{VERSION}"})
        with urllib.request.urlopen(req, timeout=20) as res:
            source = res.read()
        (target / "vexora-claimer.lua").write_bytes(source)
        log(f"autoexec refreshed: {target / 'vexora-claimer.lua'}")
    except Exception as err:  # noqa: BLE001 - a missing autoexec must not stop launching
        log(f"could not refresh autoexec: {err}")


def read_cookie(args) -> str:
    if args.cookie:
        return normalize_cookie(args.cookie)
    path = Path(args.cookie_file)
    if not path.is_file():
        raise RuntimeError(f"no cookie: create {path} with the alt's .ROBLOSECURITY value")
    return normalize_cookie(path.read_text(encoding="utf-8"))


def main() -> int:
    parser = argparse.ArgumentParser(description="Watch elow.cc and open the target server with the alt.")
    parser.add_argument("--site", default="https://elow.cc", help="dashboard origin")
    parser.add_argument("--key", default=os.environ.get("VEXORA_API_KEY", ""), help="claimer API key")
    parser.add_argument("--cookie-file", default="alt-cookie.txt", help="file containing the alt's .ROBLOSECURITY")
    parser.add_argument("--cookie", default="", help="cookie value instead of a file")
    parser.add_argument("--autoexec", default="", help="executor autoexec folder to seed")
    parser.add_argument("--script-url", default="", help="claimer loadstring URL to seed autoexec")
    parser.add_argument("--interval", type=float, default=4.0, help="seconds between polls")
    parser.add_argument("--name", default="desktop", help="label shown on the dashboard")
    parser.add_argument("--dry-run", action="store_true", help="print the launch without opening Roblox")
    args = parser.parse_args()

    if not args.key:
        log("missing --key: copy the claimer API key from the My script page")
        return 2
    try:
        cookie = read_cookie(args)
    except RuntimeError as err:
        log(str(err))
        return 2
    if not cookie.startswith("_|"):
        log("that cookie does not start with _| - paste the full .ROBLOSECURITY value")
        return 2

    try:
        profile = whoami(cookie)
    except RuntimeError as err:
        log(str(err))
        return 1
    account = str(profile.get("name") or "alt")
    log(f"alt: {account} ({profile.get('displayName', account)})")
    log(f"watching {args.site} every {args.interval:g}s")

    write_autoexec(args.autoexec, args.script_url)

    launched: dict[str, float] = {}
    last_heartbeat = 0.0
    last_error = ""

    while True:
        try:
            now = time.time()
            if now - last_heartbeat >= 15:
                api(args.site, args.key, "/api/claimer/launcher", {
                    "account": account,
                    "version": VERSION,
                    "name": args.name,
                })
                last_heartbeat = now

            data = api(args.site, args.key, "/api/claimer/target?watch=1&account=" + urllib.parse.quote(account))
            if data.get("paused"):
                if last_error != "paused":
                    log("joiner is off on the dashboard; waiting")
                    last_error = "paused"
                time.sleep(max(1.0, args.interval))
                continue
            last_error = ""

            target = data.get("target")
            if not target:
                time.sleep(max(1.0, args.interval))
                continue

            status = str(target.get("status") or "")
            target_id = str(target.get("id") or "")
            place_id = str(target.get("place_id") or "")
            server_id = str(target.get("server_id") or "")
            if not target_id or not place_id or not server_id or status not in ("queued", "joining"):
                time.sleep(max(1.0, args.interval))
                continue

            seen_at = launched.get(target_id)
            if seen_at and now - seen_at < 90:
                time.sleep(max(1.0, args.interval))
                continue

            log(f"target {target_id[:8]} · place {place_id} · server {server_id[:8]} · launching")
            write_autoexec(args.autoexec, args.script_url)
            url = launch_url(cookie, place_id, server_id)
            open_protocol(url, dry_run=args.dry_run)
            launched[target_id] = now
            if not args.dry_run:
                api(args.site, args.key, f"/api/claimer/target/{urllib.parse.quote(target_id)}/launched", {
                    "account": account,
                    "launcher": args.name,
                    "version": VERSION,
                })
            log("sent the launch; the Lua claimer should take over on arrival")

            # keep only recent ids
            launched = {k: v for k, v in launched.items() if now - v < 3600}
        except KeyboardInterrupt:
            log("stopped")
            return 0
        except Exception as err:  # noqa: BLE001 - keep watching through a bad poll
            message = str(err)
            if message != last_error:
                log(message)
                last_error = message
        time.sleep(max(1.0, args.interval))


if __name__ == "__main__":
    raise SystemExit(main())
