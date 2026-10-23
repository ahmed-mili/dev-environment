#!/usr/bin/env python3
"""
shop_login.py — Capture UNE FOIS les cookies amazon.fr de Brave (session connectée d'Ahmed).

Même méthode que le skill x (x_login.py) : Brave chiffre ses cookies (app-bound), seule voie =
le protocole DevTools de Brave. Il faut donc FERMER Brave, le relancer avec un port de debug,
lire les cookies, puis le relancer normalement (--restore-last-session rouvre les onglets).
ATTENTION : cela ferme TOUS les Brave (y compris celui du MCP Playwright). Prévenir Ahmed et
obtenir son accord avant de lancer.

Écrit %LOCALAPPDATA%\\content-extractor\\amazon-cookies.json (hors repo). Ne jamais l'afficher.
Usage : python shop_login.py
"""
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

try:
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
except Exception:
    pass

PORT = 9334
COOKIE_PATH = (Path(os.environ.get("LOCALAPPDATA") or Path.home() / "AppData" / "Local")
               / "content-extractor" / "amazon-cookies.json")
NEEDED_ANY = ("at-acbfr", "x-acbfr", "sess-at-acbfr")


def find_brave():
    found = shutil.which("brave.exe") or shutil.which("brave")
    if found:
        return found
    for base in (os.environ.get("ProgramFiles"), os.environ.get("LOCALAPPDATA")):
        if base:
            p = os.path.join(base, "BraveSoftware", "Brave-Browser", "Application", "brave.exe")
            if os.path.exists(p):
                return p
    raise SystemExit("brave.exe introuvable.")


def brave_running():
    out = subprocess.run(["tasklist", "/FI", "IMAGENAME eq brave.exe", "/NH"], capture_output=True, text=True).stdout
    return "brave.exe" in out.lower()


def close_brave():
    subprocess.run(["taskkill", "/IM", "brave.exe"], capture_output=True)
    t0 = time.time()
    while brave_running() and time.time() - t0 < 20:
        time.sleep(0.3)
    if brave_running():
        time.sleep(3)
        subprocess.run(["taskkill", "/F", "/IM", "brave.exe"], capture_output=True)
        time.sleep(1)


def launch(brave, *args):
    subprocess.Popen([brave, *args], creationflags=subprocess.DETACHED_PROCESS | subprocess.CREATE_NEW_PROCESS_GROUP,
                     close_fds=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def wait_port():
    for _ in range(60):
        try:
            urllib.request.urlopen(f"http://127.0.0.1:{PORT}/json/version", timeout=2).read()
            return
        except Exception:
            time.sleep(0.5)
    raise RuntimeError(f"le port de debug {PORT} n'a jamais répondu")


def read_cookies():
    from playwright.sync_api import sync_playwright
    with sync_playwright() as p:
        b = p.chromium.connect_over_cdp(f"http://127.0.0.1:{PORT}")
        try:
            return b.contexts[0].cookies(["https://www.amazon.fr", "https://amazon.fr"])
        except Exception:
            return b.new_browser_cdp_session().send("Storage.getCookies").get("cookies", [])


def to_pw(c):
    same = c.get("sameSite")
    out = {"name": c["name"], "value": c["value"], "domain": c["domain"], "path": c.get("path") or "/",
           "httpOnly": bool(c.get("httpOnly")), "secure": bool(c.get("secure")),
           "sameSite": same if same in ("Strict", "Lax", "None") else "Lax"}
    if isinstance(c.get("expires"), (int, float)) and c["expires"] > 0:
        out["expires"] = c["expires"]
    return out


def main():
    brave = find_brave()
    was = brave_running()
    print("==> Fermeture de Brave...")
    close_brave()
    launch(brave, f"--remote-debugging-port={PORT}", "--disable-features=DevToolsDebuggingRestrictions",
           "--restore-last-session")
    try:
        wait_port()
        cookies = [to_pw(c) for c in read_cookies() if "amazon.fr" in (c.get("domain") or "")]
    finally:
        close_brave()
        if was:
            launch(brave, "--restore-last-session")
    if not {c["name"] for c in cookies} & set(NEEDED_ANY):
        raise SystemExit("Pas de session amazon.fr connectée dans Brave : connecte-toi sur amazon.fr puis relance.")
    COOKIE_PATH.parent.mkdir(parents=True, exist_ok=True)
    COOKIE_PATH.write_text(json.dumps(cookies, indent=1), encoding="utf-8")
    print(f"OK : {len(cookies)} cookies amazon.fr écrits dans {COOKIE_PATH}")


if __name__ == "__main__":
    main()
