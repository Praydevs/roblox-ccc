#!/usr/bin/env python3
"""Vexora multi-client launcher.

Open one or more Roblox clients, each signed in as a different account, optionally
into the same server (game.JobId) so two accounts can trade with each other.

    python tools/roblox_multi.py                 # GUI
    python tools/roblox_multi.py --cli --list
    python tools/roblox_multi.py --cli --add main --cookie "_|WARNING..."
    python tools/roblox_multi.py --cli --launch --accounts main,alt --job <jobId>

How it works: for each account it uses the .ROBLOSECURITY cookie to get an
authentication ticket and opens the roblox-player: protocol URL pointing at
PlaceLauncher.ashx. Nothing is patched and no client files are touched.

Windows lets Roblox open one client per session because the client grabs a named
mutex (ROBLOX_singletonMutex) on startup. This tool takes that mutex first and holds
it while launching, so a second client starts as its own window - the same trick the
C++ multi-instance launchers use. If Roblox ever ignores it, enabling multi-instance
in the tool still does no harm: the launch is retried without the lock and the log
says so.

Cookies live in tools/accounts.json, which is git-ignored; treat it like a password.
"""

from __future__ import annotations

import argparse
import ctypes
import http.cookiejar
import json
import os
import random
import re
import subprocess
import sys
import threading
import time
import tkinter as tk
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from tkinter import messagebox, ttk

AUTHENTICATED = "https://users.roblox.com/v1/users/authenticated"
AUTH_TICKET = "https://auth.roblox.com/v1/authentication-ticket"
PLACE_LAUNCHER = "https://assetgame.roblox.com/game/PlaceLauncher.ashx"
UA = "Roblox/WinInet"
BROWSER_UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
              "(KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36")
DEFAULT_PLACE = "142823291"          # Murder Mystery 2
ACCOUNTS_FILE = Path(__file__).resolve().with_name("accounts.json")


# ---------- cookies ----------
def normalize_cookie(raw: str) -> str:
    value = "".join((raw or "").split())          # pasted values sometimes wrap
    value = value.split(";", 1)[0]                 # full Cookie header pasted
    value = value.strip('"').strip("'")
    if "%" in value:                               # DevTools sometimes copies encoded
        value = urllib.parse.unquote(value)
    if value.lower().startswith(".roblosecurity="):
        value = value.split("=", 1)[1]
    if value.startswith("WARNING"):
        value = "_|" + value
    return value


def cookie_ok(cookie: str) -> bool:
    return cookie.startswith("_|") and len(cookie) >= 80


# ---------- http ----------
def _request(url: str, *, method: str = "GET", cookie: str | None = None,
             headers: dict | None = None, data: bytes | None = None,
             timeout: int = 20, opener=None):
    merged = {"user-agent": BROWSER_UA, "accept": "application/json"}
    if cookie:
        merged["cookie"] = f".ROBLOSECURITY={cookie}"
    if headers:
        merged.update(headers)
    req = urllib.request.Request(url, data=data, method=method, headers=merged)
    if opener is not None:
        return opener.open(req, timeout=timeout)
    return urllib.request.urlopen(req, timeout=timeout)


def make_session(cookie: str):
    """Opener with a cookie jar seeded with .ROBLOSECURITY.

    Roblox may rotate or add cookies on the first (CSRF) response and the token is
    bound to that session, so both requests have to share the jar.
    """
    jar = http.cookiejar.CookieJar()
    jar.set_cookie(http.cookiejar.Cookie(
        version=0, name=".ROBLOSECURITY", value=cookie,
        port=None, port_specified=False,
        domain=".roblox.com", domain_specified=True, domain_initial_dot=True,
        path="/", path_specified=True,
        secure=True, expires=None, discard=False,
        comment=None, comment_url=None, rest={}, rfc2109=False,
    ))
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
    opener.addheaders = [("user-agent", BROWSER_UA), ("accept", "application/json")]
    return opener


def _json(response):
    raw = response.read().decode("utf-8", "replace")
    return json.loads(raw) if raw else {}


def _body(err: urllib.error.HTTPError, limit: int = 240) -> str:
    try:
        return err.read().decode("utf-8", "replace").strip()[:limit]
    except Exception:
        return ""


def whoami(cookie: str) -> dict:
    """Return {id, name, displayName} or raise RuntimeError with a readable message."""
    try:
        with _request(
            AUTHENTICATED,
            opener=make_session(cookie),
            headers={
                "accept": "application/json",
                "accept-language": "en-US,en;q=0.9",
                "referer": "https://www.roblox.com/",
            },
        ) as res:
            return _json(res)
    except urllib.error.HTTPError as err:
        body = _body(err)
        if err.code == 401:
            raise RuntimeError(
                "Roblox rejected that cookie (401). If you signed in again after copying, the "
                "cookie rotated - copy the current .ROBLOSECURITY from the open session."
            )
        raise RuntimeError(f"Roblox returned HTTP {err.code} while checking the cookie: {body}")
    except urllib.error.URLError as err:
        raise RuntimeError(f"Network error: {err.reason}")


def auth_ticket(cookie: str, opener=None) -> str:
    opener = opener or make_session(cookie)

    def post(csrf: str | None):
        headers = {
            "content-type": "application/json",
            "origin": "https://www.roblox.com",
            "referer": "https://www.roblox.com/",
            "accept": "application/json",
        }
        if csrf is not None:
            headers["x-csrf-token"] = csrf
        return _request(AUTH_TICKET, method="POST", opener=opener, data=b"{}", headers=headers)

    try:
        with post(None) as res:
            ticket = res.headers.get("rbx-authentication-ticket")
            if ticket:
                return ticket
            raise RuntimeError("No authentication ticket in the response.")
    except urllib.error.HTTPError as err:
        if err.code == 401:
            raise RuntimeError("Cookie expired (401). Sign in again and paste a new one.")
        if err.code != 403:
            raise RuntimeError(f"Auth ticket failed: HTTP {err.code} {_body(err)}")
        csrf = err.headers.get("x-csrf-token")
        first_body = _body(err)
        if not csrf:
            raise RuntimeError(f"Roblox refused the auth ticket (403, no CSRF token): {first_body}")

        try:
            with post(csrf) as res:
                ticket = res.headers.get("rbx-authentication-ticket")
                if not ticket:
                    raise RuntimeError("No authentication ticket after the CSRF retry.")
                return ticket
        except urllib.error.HTTPError as retry:
            raise RuntimeError(
                f"Auth ticket refused ({retry.code}) after CSRF: {_body(retry)} | first: {first_body}"
            )


def parse_job(text: str | None) -> str | None:
    """Accept a raw job id or a copied server link and return the id."""
    value = (text or "").strip()
    if not value:
        return None
    match = re.search(r"gameInstanceId=([0-9a-fA-F-]{8,40})", value)
    if match:
        value = match.group(1)
    value = value.strip("/ ")
    if re.fullmatch(r"[0-9a-fA-F]{32}", value):
        return f"{value[:8]}-{value[8:12]}-{value[12:16]}-{value[16:20]}-{value[20:]}"
    if re.fullmatch(r"[0-9a-fA-F-]{16,40}", value):
        return value
    raise RuntimeError(f"'{value}' is not a job id or a server link.")


def launch_url(cookie: str, place_id: str, job_id: str | None = None) -> str:
    """Build the roblox-player: URL the website hands to the client.

    PlaceLauncher is only *inside* the URL - the client calls it itself. Asking it
    here as a pre-check failed on healthy servers (status None), so there is no
    pre-check any more.
    """
    ticket = auth_ticket(cookie)
    job = parse_job(job_id)
    tracker = str(random.randint(1_000_000_000, 9_999_999_999))
    params = {
        "browserTrackerId": tracker,
        "placeId": str(place_id),
        "isPlayTogetherGame": "false",
    }
    if job:
        params["request"] = "RequestGameJob"
        params["gameId"] = job
    else:
        params["request"] = "RequestGame"

    launcher = f"{PLACE_LAUNCHER}?{urllib.parse.urlencode(params)}"
    return (
        "roblox-player:1+launchmode:play"
        f"+gameinfo:{ticket}"
        f"+launchtime:{int(time.time() * 1000)}"
        f"+placelauncherurl:{urllib.parse.quote(launcher, safe='')}"
        f"+browsertrackerid:{tracker}"
        "+robloxLocale:en_us+gameLocale:en_us+channel:+LaunchExp:InApp"
    )


# ---------- multiple windows ----------
SINGLETON_MUTEX = "ROBLOX_singletonMutex"
SINGLETON_EVENT = "ROBLOX_singletonEvent"


class MultiInstance:
    """Hold Roblox's single-instance objects so a second client can start.

    The client opens a named mutex/event at startup and quits if it cannot. Owning
    them here first is what every multi-instance launcher does; handles are closed
    when the block exits or the process ends.
    """

    def __init__(self) -> None:
        self.handles: list[int] = []

    def __enter__(self) -> "MultiInstance":
        if not sys.platform.startswith("win"):
            return self
        try:
            kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
            kernel32.CreateMutexW.restype = ctypes.c_void_p
            kernel32.CreateMutexW.argtypes = [ctypes.c_void_p, ctypes.c_bool, ctypes.c_wchar_p]
            kernel32.CreateEventW.restype = ctypes.c_void_p
            kernel32.CreateEventW.argtypes = [ctypes.c_void_p, ctypes.c_bool, ctypes.c_bool, ctypes.c_wchar_p]
            mutex = kernel32.CreateMutexW(None, True, SINGLETON_MUTEX)
            event = kernel32.CreateEventW(None, True, True, SINGLETON_EVENT)
            self.handles = [h for h in (mutex, event) if h]
        except Exception:  # noqa: BLE001 - never block a launch over this
            self.handles = []
        return self

    def __exit__(self, *exc) -> None:
        for handle in self.handles:
            try:
                ctypes.WinDLL("kernel32").CloseHandle(ctypes.c_void_p(handle))
            except Exception:  # noqa: BLE001
                pass
        self.handles = []


def client_count() -> int:
    """How many RobloxPlayerBeta.exe processes are running."""
    if not sys.platform.startswith("win"):
        return 0
    try:
        out = subprocess.run(
            ["tasklist", "/fi", "IMAGENAME eq RobloxPlayerBeta.exe", "/fo", "csv", "/nh"],
            capture_output=True, text=True, timeout=15,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return 0
    return out.lower().count("robloxplayerbeta.exe")


def wait_for_client(before: int, seconds: float) -> bool:
    deadline = time.time() + seconds
    while time.time() < deadline:
        if client_count() > before:
            return True
        time.sleep(0.5)
    return client_count() > before


def launch_client(cookie: str, place: str, job: str | None = None, *, dry_run: bool = False,
                  multi: bool = True, log=print) -> str:
    """Resolve a ticket and start one client. Returns the protocol URL."""
    before = client_count()
    url = launch_url(cookie, place, job)
    if dry_run:
        log(f"would launch: {url[:120]}...")
        return url

    if multi:
        with MultiInstance():
            open_protocol(url)
            if wait_for_client(before, 12):
                return url
        log("no new window with the instance lock held - retrying without it")

    open_protocol(url)
    if not wait_for_client(before, 20):
        log("Roblox accepted the launch but no new RobloxPlayerBeta.exe appeared; "
            "if a window only got focused, enable multi-instance or run the Store version")
    return url


def open_protocol(url: str, dry_run: bool = False) -> None:
    if dry_run:
        print(f"[dry-run] {url[:180]}...")
        return
    if sys.platform.startswith("win"):
        os.startfile(url)  # type: ignore[attr-defined]
    elif sys.platform == "darwin":
        subprocess.Popen(["open", url])
    else:
        subprocess.Popen(["xdg-open", url])


# ---------- storage ----------
def load_accounts() -> list[dict]:
    if not ACCOUNTS_FILE.exists():
        return []
    try:
        data = json.loads(ACCOUNTS_FILE.read_text("utf-8"))
    except (OSError, json.JSONDecodeError):
        return []
    accounts = data if isinstance(data, list) else data.get("accounts", [])
    return [a for a in accounts if isinstance(a, dict) and a.get("cookie")]


def save_accounts(accounts: list[dict]) -> None:
    payload = json.dumps(accounts, indent=2)
    ACCOUNTS_FILE.write_text(payload, "utf-8")
    try:
        os.chmod(ACCOUNTS_FILE, 0o600)
    except OSError:
        pass


def upsert_account(label: str, cookie: str, profile: dict | None = None) -> list[dict]:
    accounts = load_accounts()
    existing = next((a for a in accounts if a.get("label") == label), None)
    record = existing or {"label": label}
    record["cookie"] = cookie
    if profile:
        record["user_id"] = profile.get("id")
        record["username"] = profile.get("name") or record.get("username")
        record["checked_at"] = int(time.time())
    if existing is None:
        accounts.append(record)
    save_accounts(accounts)
    return accounts


# ---------- CLI ----------
def cli(args) -> int:
    if args.list:
        accounts = load_accounts()
        if not accounts:
            print("no accounts saved")
        for account in accounts:
            print(f"{account.get('label', '?'):20} {account.get('username') or '-':20} "
                  f"{'verified' if account.get('checked_at') else 'unverified'}")
        return 0

    if args.add:
        cookie = normalize_cookie(args.cookie or "")
        if not cookie_ok(cookie):
            print("cookie does not look like a .ROBLOSECURITY value", file=sys.stderr)
            return 2
        profile = None
        try:
            profile = whoami(cookie)
            print(f"verified as {profile.get('name')} ({profile.get('id')})")
        except RuntimeError as err:
            print(f"warning: {err}", file=sys.stderr)
        upsert_account(args.add, cookie, profile)
        print(f"saved {args.add}")
        return 0

    if args.remove:
        accounts = [a for a in load_accounts() if a.get("label") != args.remove]
        save_accounts(accounts)
        print(f"removed {args.remove}")
        return 0

    if args.check:
        cookie = normalize_cookie(args.cookie or "")
        print(f"length={len(cookie)} prefix={cookie[:12]!r} suffix={cookie[-6:]!r}")
        if not cookie_ok(cookie):
            print("does not look like a .ROBLOSECURITY value", file=sys.stderr)
            return 2
        try:
            profile = whoami(cookie)
        except RuntimeError as err:
            print(f"invalid: {err}", file=sys.stderr)
            return 1
        print(f"valid: {profile.get('name')} ({profile.get('id')})")
        try:
            ticket = auth_ticket(cookie)
            print(f"auth ticket: ok ({len(ticket)} chars)")
        except RuntimeError as err:
            print(f"auth ticket: failed - {err}", file=sys.stderr)
            return 1
        return 0

    if args.verify:
        accounts = load_accounts()
        failed = 0
        for account in accounts:
            try:
                profile = whoami(account["cookie"])
                account["username"] = profile.get("name")
                account["user_id"] = profile.get("id")
                account["checked_at"] = int(time.time())
                print(f"ok      {account['label']} -> {profile.get('name')}")
            except RuntimeError as err:
                failed += 1
                print(f"failed  {account['label']} -> {err}")
        save_accounts(accounts)
        return 1 if failed else 0

    if args.launch:
        accounts = load_accounts()
        if not accounts:
            print("no accounts saved", file=sys.stderr)
            return 2
        wanted = [s.strip() for s in (args.accounts or "").split(",") if s.strip()]
        chosen = [a for a in accounts if not wanted or a.get("label") in wanted]
        if not chosen:
            print("none of those labels exist", file=sys.stderr)
            return 2
        for index, account in enumerate(chosen):
            try:
                launch_client(account["cookie"], args.place, args.job,
                              dry_run=args.dry_run, multi=args.multi,
                              log=lambda m: print(f"  {m}"))
                if not args.dry_run:
                    print(f"opened {account['label']} ({account.get('username') or 'unknown'})"
                          f" in place {args.place}{' job ' + args.job if args.job else ' (any server)'}")
            except RuntimeError as err:
                print(f"failed {account['label']}: {err}", file=sys.stderr)
            if index < len(chosen) - 1 and args.delay:
                time.sleep(args.delay)
        return 0

    print("nothing to do; try --list, --add, --verify or --launch", file=sys.stderr)
    return 2


# ---------- GUI ----------
class LauncherApp(tk.Tk):
    def __init__(self) -> None:
        super().__init__()
        self.title("Vexora multi-client launcher")
        self.geometry("860x560")
        self.minsize(760, 480)
        self.accounts = load_accounts()
        self._build()
        self.refresh()

    # -- layout
    def _build(self) -> None:
        style = ttk.Style(self)
        style.configure("Treeview", rowheight=26)
        self.columnconfigure(0, weight=1)
        self.rowconfigure(1, weight=1)

        top = ttk.Frame(self, padding=(12, 12, 12, 6))
        top.grid(row=0, column=0, sticky="ew")
        top.columnconfigure(0, weight=1)
        ttk.Label(top, text="Accounts", font=("Segoe UI", 12, "bold")).grid(row=0, column=0, sticky="w")
        ttk.Label(top, text="Cookies stay in tools/accounts.json on this PC.",
                  foreground="#666").grid(row=1, column=0, sticky="w", pady=(2, 0))

        body = ttk.Frame(self, padding=(12, 0, 12, 0))
        body.grid(row=1, column=0, sticky="nsew")
        body.columnconfigure(0, weight=3)
        body.columnconfigure(1, weight=2)
        body.rowconfigure(0, weight=1)

        left = ttk.Frame(body)
        left.grid(row=0, column=0, sticky="nsew", padx=(0, 10))
        left.rowconfigure(0, weight=1)
        left.columnconfigure(0, weight=1)

        self.tree = ttk.Treeview(left, columns=("user", "state"), show="tree headings", selectmode="extended")
        self.tree.heading("#0", text="Label")
        self.tree.heading("user", text="Roblox user")
        self.tree.heading("state", text="Status")
        self.tree.column("#0", width=180)
        self.tree.column("user", width=150)
        self.tree.column("state", width=110)
        self.tree.grid(row=0, column=0, sticky="nsew")

        buttons = ttk.Frame(left)
        buttons.grid(row=1, column=0, sticky="ew", pady=8)
        ttk.Button(buttons, text="Add account", command=self.add_account).pack(side="left")
        ttk.Button(buttons, text="Verify", command=self.verify_selected).pack(side="left", padx=6)
        ttk.Button(buttons, text="Remove", command=self.remove_selected).pack(side="left")
        ttk.Button(buttons, text="Select all", command=lambda: self.tree.selection_set(self.tree.get_children())).pack(side="right")

        right = ttk.LabelFrame(body, text="Launch", padding=12)
        right.grid(row=0, column=1, sticky="nsew")
        right.columnconfigure(1, weight=1)

        ttk.Label(right, text="Place ID").grid(row=0, column=0, sticky="w", pady=4)
        self.place = ttk.Entry(right)
        self.place.insert(0, DEFAULT_PLACE)
        self.place.grid(row=0, column=1, sticky="ew", pady=4)

        ttk.Label(right, text="Job ID (optional)").grid(row=1, column=0, sticky="w", pady=4)
        self.job = ttk.Entry(right)
        self.job.grid(row=1, column=1, sticky="ew", pady=4)
        ttk.Label(right, text="Same Job ID on both accounts = same server.",
                  foreground="#666", wraplength=280).grid(row=2, column=0, columnspan=2, sticky="w")

        ttk.Label(right, text="Delay between (s)").grid(row=3, column=0, sticky="w", pady=(10, 4))
        self.delay = ttk.Spinbox(right, from_=0, to=120, width=6)
        self.delay.set(8)
        self.delay.grid(row=3, column=1, sticky="w", pady=(10, 4))

        self.dry = tk.BooleanVar(value=False)
        ttk.Checkbutton(right, text="Dry run (print, don't launch)", variable=self.dry).grid(
            row=4, column=0, columnspan=2, sticky="w", pady=6)

        self.multi = tk.BooleanVar(value=True)
        ttk.Checkbutton(right, text="Multi-instance lock (allows a 2nd window)",
                        variable=self.multi).grid(row=5, column=0, columnspan=2, sticky="w")

        ttk.Button(right, text="Launch selected", command=self.launch_selected).grid(
            row=6, column=0, columnspan=2, sticky="ew", pady=(6, 10))

        self.log = tk.Text(right, height=12, wrap="word", state="disabled", relief="flat", bg="#111", fg="#ddd")
        self.log.grid(row=7, column=0, columnspan=2, sticky="nsew")
        right.rowconfigure(7, weight=1)

        self.status = ttk.Label(self, text="Ready", padding=(12, 6))
        self.status.grid(row=2, column=0, sticky="ew")

    # -- helpers
    def write_log(self, message: str) -> None:
        stamp = time.strftime("%H:%M:%S")
        self.log.configure(state="normal")
        self.log.insert("end", f"[{stamp}] {message}\n")
        self.log.see("end")
        self.log.configure(state="disabled")

    def refresh(self) -> None:
        selected = set(self.tree.selection())
        self.tree.delete(*self.tree.get_children())
        for account in self.accounts:
            label = account.get("label", "?")
            state = "verified" if account.get("checked_at") else "unverified"
            self.tree.insert("", "end", iid=label, text=label,
                             values=(account.get("username") or "-", state))
        for label in selected:
            if self.tree.exists(label):
                self.tree.selection_add(label)

    def selected_accounts(self) -> list[dict]:
        labels = set(self.tree.selection())
        return [a for a in self.accounts if a.get("label") in labels]

    # -- actions
    def add_account(self) -> None:
        dialog = tk.Toplevel(self)
        dialog.title("Add account")
        dialog.geometry("560x300")
        dialog.transient(self)
        dialog.grab_set()

        frame = ttk.Frame(dialog, padding=12)
        frame.pack(fill="both", expand=True)
        frame.columnconfigure(1, weight=1)
        frame.rowconfigure(3, weight=1)

        ttk.Label(frame, text="Label").grid(row=0, column=0, sticky="w")
        label = ttk.Entry(frame)
        label.grid(row=0, column=1, sticky="ew", pady=4)

        ttk.Label(frame, text=".ROBLOSECURITY").grid(row=1, column=0, sticky="nw", pady=4)
        cookie_box = tk.Text(frame, height=5, wrap="char")
        cookie_box.grid(row=1, column=1, sticky="nsew", pady=4)
        frame.rowconfigure(1, weight=1)

        ttk.Label(frame, text="Paste the whole value, starting with _|. It is stored locally only.",
                  foreground="#666").grid(row=2, column=0, columnspan=2, sticky="w")

        def submit() -> None:
            name = label.get().strip()
            cookie = normalize_cookie(cookie_box.get("1.0", "end"))
            if not name:
                messagebox.showerror("Add account", "Give it a label.", parent=dialog)
                return
            if not cookie_ok(cookie):
                messagebox.showerror("Add account", "That does not look like a .ROBLOSECURITY value.", parent=dialog)
                return
            if any(a.get("label") == name for a in load_accounts()):
                messagebox.showerror("Add account", f"'{name}' already exists.", parent=dialog)
                return
            upsert_account(name, cookie)
            self.accounts = load_accounts()
            self.refresh()
            self.write_log(f"added {name} (unverified)")
            dialog.destroy()
            self.verify_labels([name])

        ttk.Button(frame, text="Save", command=submit).grid(row=4, column=1, sticky="e", pady=(8, 0))
        label.focus_set()

    def verify_labels(self, labels: list[str]) -> None:
        def work() -> None:
            accounts = load_accounts()
            for account in accounts:
                if account.get("label") not in labels:
                    continue
                try:
                    profile = whoami(account["cookie"])
                    account["username"] = profile.get("name")
                    account["user_id"] = profile.get("id")
                    account["checked_at"] = int(time.time())
                    self.write_log(f"{account['label']} verified as {profile.get('name')}")
                except RuntimeError as err:
                    account["checked_at"] = None
                    self.write_log(f"{account['label']} failed: {err}")
            save_accounts(accounts)
            self.accounts = accounts
            self.after(0, self.refresh)
            self.after(0, lambda: self.status.configure(text="Verification finished"))

        self.status.configure(text="Verifying...")
        threading.Thread(target=work, daemon=True).start()

    def verify_selected(self) -> None:
        chosen = self.selected_accounts()
        if not chosen:
            messagebox.showinfo("Verify", "Select one or more accounts first.")
            return
        self.verify_labels([a["label"] for a in chosen])

    def remove_selected(self) -> None:
        chosen = self.selected_accounts()
        if not chosen:
            return
        if not messagebox.askyesno("Remove", f"Remove {len(chosen)} account(s) from this PC?"):
            return
        labels = {a["label"] for a in chosen}
        save_accounts([a for a in load_accounts() if a.get("label") not in labels])
        self.accounts = load_accounts()
        self.refresh()
        self.write_log(f"removed {', '.join(sorted(labels))}")

    def launch_selected(self) -> None:
        chosen = self.selected_accounts()
        if not chosen:
            messagebox.showinfo("Launch", "Select one or more accounts first.")
            return
        place = self.place.get().strip()
        job = self.job.get().strip() or None
        if not place.isdigit():
            messagebox.showerror("Launch", "Place ID must be numbers.")
            return
        try:
            delay = max(0, float(self.delay.get()))
        except ValueError:
            delay = 8
        dry = bool(self.dry.get())
        multi = bool(self.multi.get())

        def work() -> None:
            for index, account in enumerate(chosen):
                label = account["label"]
                say = lambda m, l=label: self.after(0, lambda: self.write_log(f"{l}: {m}"))
                try:
                    say("requesting ticket...")
                    launch_client(account["cookie"], place, job, dry_run=dry,
                                  multi=multi, log=say)
                    say("launched" if not dry else "dry run ok")
                except Exception as err:  # noqa: BLE001 - surface anything to the log
                    say(str(err))
                if index < len(chosen) - 1 and delay:
                    time.sleep(delay)
            self.after(0, lambda: self.status.configure(text="Launch run finished"))

        self.status.configure(text="Launching...")
        threading.Thread(target=work, daemon=True).start()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Open multiple Roblox clients, one per account.")
    parser.add_argument("--cli", action="store_true", help="run without the GUI")
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--add", metavar="LABEL")
    parser.add_argument("--cookie")
    parser.add_argument("--remove", metavar="LABEL")
    parser.add_argument("--verify", action="store_true")
    parser.add_argument("--check", action="store_true", help="test one cookie without saving it")
    parser.add_argument("--launch", action="store_true")
    parser.add_argument("--accounts", help="comma separated labels (default: all)")
    parser.add_argument("--place", default=DEFAULT_PLACE)
    parser.add_argument("--job", help="game.JobId to land every account in the same server")
    parser.add_argument("--delay", type=float, default=8.0)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--no-multi", dest="multi", action="store_false",
                        help="launch without holding Roblox's single-instance lock")
    parser.set_defaults(multi=True)
    args = parser.parse_args(argv)

    if args.cli:
        return cli(args)

    app = LauncherApp()
    app.mainloop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
