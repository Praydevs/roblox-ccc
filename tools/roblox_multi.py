#!/usr/bin/env python3
"""Vexora multi-client launcher.

Open one or more Roblox clients, each signed in as a different account, optionally
into the same server (game.JobId) so two accounts can trade with each other.

    python tools/roblox_multi.py                 # GUI
    python tools/roblox_multi.py --cli --list
    python tools/roblox_multi.py --cli --add main --cookie "_|WARNING..."
    python tools/roblox_multi.py --cli --launch --accounts main,alt --job <jobId>

How it works: for each account it uses the .ROBLOSECURITY cookie to get an
authentication ticket, resolves the join through PlaceLauncher.ashx, and opens the
roblox-player: protocol URL. Nothing is patched and no client files are touched.

Roblox on Windows normally allows one client per user session. If a second launch
just focuses the first window, sign the second account in under a separate Windows
user (or a separate VM) instead of patching the client. Cookies live in
tools/accounts.json, which is git-ignored; treat that file like a password.
"""

from __future__ import annotations

import argparse
import json
import os
import random
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
DEFAULT_PLACE = "142823291"          # Murder Mystery 2
ACCOUNTS_FILE = Path(__file__).resolve().with_name("accounts.json")


# ---------- cookies ----------
def normalize_cookie(raw: str) -> str:
    value = (raw or "").strip()
    if value.lower().startswith(".roblosecurity="):
        value = value.split("=", 1)[1].strip()
    value = value.strip('"')
    if value.startswith("WARNING"):
        value = "_|" + value
    return value


def cookie_ok(cookie: str) -> bool:
    return cookie.startswith("_|") and len(cookie) >= 80


# ---------- http ----------
def _request(url: str, *, method: str = "GET", cookie: str | None = None,
             headers: dict | None = None, data: bytes | None = None, timeout: int = 20):
    merged = {"user-agent": UA, "accept": "application/json"}
    if cookie:
        merged["cookie"] = f".ROBLOSECURITY={cookie}"
    if headers:
        merged.update(headers)
    req = urllib.request.Request(url, data=data, method=method, headers=merged)
    return urllib.request.urlopen(req, timeout=timeout)


def _json(response):
    raw = response.read().decode("utf-8", "replace")
    return json.loads(raw) if raw else {}


def whoami(cookie: str) -> dict:
    """Return {id, name, displayName} or raise RuntimeError with a readable message."""
    try:
        with _request(AUTHENTICATED, headers={"accept": "application/json"}) as res:
            return _json(res)
    except urllib.error.HTTPError as err:
        if err.code == 401:
            raise RuntimeError("Roblox rejected that cookie (401). Sign in again and copy a fresh one.")
        raise RuntimeError(f"Roblox returned HTTP {err.code} while checking the cookie.")
    except urllib.error.URLError as err:
        raise RuntimeError(f"Network error: {err.reason}")


def auth_ticket(cookie: str) -> str:
    def post(csrf: str):
        return _request(
            AUTH_TICKET, method="POST", cookie=cookie, data=b"{}",
            headers={"content-type": "application/json", "x-csrf-token": csrf},
        )

    try:
        with post("") as res:
            ticket = res.headers.get("rbx-authentication-ticket")
            if ticket:
                return ticket
            raise RuntimeError("No authentication ticket in the response.")
    except urllib.error.HTTPError as err:
        if err.code == 401:
            raise RuntimeError("Cookie expired (401). Sign in again and paste a new one.")
        if err.code != 403:
            raise RuntimeError(f"Auth ticket failed: HTTP {err.code}")
        csrf = err.headers.get("x-csrf-token")
        if not csrf:
            raise RuntimeError("Roblox refused the auth ticket (403, no CSRF token).")
        with post(csrf) as res:
            ticket = res.headers.get("rbx-authentication-ticket")
            if not ticket:
                raise RuntimeError("No authentication ticket after the CSRF retry.")
            return ticket


def launch_url(cookie: str, place_id: str, job_id: str | None = None) -> str:
    ticket = auth_ticket(cookie)
    tracker = str(random.randint(1_000_000_000, 9_999_999_999))
    params = {
        "browserTrackerId": tracker,
        "placeId": str(place_id),
        "isPlayTogetherGame": "false",
    }
    if job_id:
        params["request"] = "RequestGameJob"
        params["gameId"] = job_id
    else:
        params["request"] = "RequestGame"

    url = f"{PLACE_LAUNCHER}?{urllib.parse.urlencode(params)}"
    try:
        with _request(url, cookie=cookie, headers={"AuthenticationTicket": ticket}) as res:
            data = _json(res)
    except urllib.error.HTTPError as err:
        if err.code == 401:
            raise RuntimeError("Cookie expired while resolving the server.")
        raise RuntimeError(f"Join request failed: HTTP {err.code}")

    if data.get("status") != 2 or not data.get("joinScriptUrl"):
        message = str(data.get("message") or "").strip()
        if "full" in message.lower():
            raise RuntimeError("That server is full.")
        raise RuntimeError(message or f"Server not joinable (status {data.get('status')}).")

    join_ticket = data.get("authenticationTicket") or ticket
    return (
        "roblox-player:1+launchmode:play"
        f"+gameinfo:{join_ticket}"
        f"+launchtime:{int(time.time() * 1000)}"
        f"+placelauncherurl:{urllib.parse.quote(str(data['joinScriptUrl']), safe='')}"
        f"+browsertrackerid:{tracker}"
        "+robloxLocale:en_us+gameLocale:en_us+channel:+LaunchExp:InApp"
    )


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
                url = launch_url(account["cookie"], args.place, args.job)
                open_protocol(url, dry_run=args.dry_run)
                print(f"launched {account['label']} ({account.get('username') or 'unknown'})"
                      f" into place {args.place}{' job ' + args.job if args.job else ''}")
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

        ttk.Button(right, text="Launch selected", command=self.launch_selected).grid(
            row=5, column=0, columnspan=2, sticky="ew", pady=(6, 10))

        self.log = tk.Text(right, height=12, wrap="word", state="disabled", relief="flat", bg="#111", fg="#ddd")
        self.log.grid(row=6, column=0, columnspan=2, sticky="nsew")
        right.rowconfigure(6, weight=1)

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

        def work() -> None:
            for index, account in enumerate(chosen):
                label = account["label"]
                try:
                    self.after(0, lambda l=label: self.write_log(f"{l}: requesting ticket..."))
                    url = launch_url(account["cookie"], place, job)
                    open_protocol(url, dry_run=dry)
                    self.after(0, lambda l=label: self.write_log(f"{l}: launched"))
                except RuntimeError as err:
                    self.after(0, lambda l=label, e=err: self.write_log(f"{l}: {e}"))
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
    parser.add_argument("--launch", action="store_true")
    parser.add_argument("--accounts", help="comma separated labels (default: all)")
    parser.add_argument("--place", default=DEFAULT_PLACE)
    parser.add_argument("--job", help="game.JobId to land every account in the same server")
    parser.add_argument("--delay", type=float, default=8.0)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)

    if args.cli:
        return cli(args)

    app = LauncherApp()
    app.mainloop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
