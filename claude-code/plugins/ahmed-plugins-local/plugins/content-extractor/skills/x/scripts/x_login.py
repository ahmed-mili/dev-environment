#!/usr/bin/env python3
"""
x_login.py — Capture UNE FOIS les cookies x.com de Brave (session connectée).

Brave chiffre ses cookies (app-bound v20, lié au chemin du profil) : ni la base
SQLite ni une copie du profil ne sont lisibles. Seule voie utilisateur : le
protocole DevTools de Brave lui-même.
  1. fermer Brave proprement (session sauvegardée) ;
  2. le relancer sur son vrai profil avec un port de debug ; Chromium >= 136 le
     refuse sur le profil par défaut sans --disable-features=DevToolsDebuggingRestrictions ;
  3. lire les cookies x.com par CDP (Playwright connect_over_cdp) ;
  4. relancer Brave normalement (le port de debug ne reste pas ouvert).
Les onglets reviennent via --restore-last-session.

Usage : python x_login.py
"""
import os
import shutil
import subprocess
import sys
import time
import urllib.request

from x_cookies import COOKIE_PATH, filter_x, missing_required, save_cookies

try:
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
except Exception:
    pass

PORT = 9333


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
    out = subprocess.run(["tasklist", "/FI", "IMAGENAME eq brave.exe", "/NH"],
                         capture_output=True, text=True).stdout
    return "brave.exe" in out.lower()


def close_brave():
    subprocess.run(["taskkill", "/IM", "brave.exe"], capture_output=True)  # WM_CLOSE, session sauvegardée
    t0 = time.time()
    while brave_running() and time.time() - t0 < 20:
        time.sleep(0.3)
    if brave_running():
        time.sleep(3)
        subprocess.run(["taskkill", "/F", "/IM", "brave.exe"], capture_output=True)
        time.sleep(1)


def launch_brave(brave, *args):
    flags = subprocess.DETACHED_PROCESS | subprocess.CREATE_NEW_PROCESS_GROUP
    subprocess.Popen([brave, *args], creationflags=flags, close_fds=True,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


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
        browser = p.chromium.connect_over_cdp(f"http://127.0.0.1:{PORT}")
        try:
            return browser.contexts[0].cookies(["https://x.com"])
        except Exception:
            cdp = browser.new_browser_cdp_session()
            return cdp.send("Storage.getCookies").get("cookies", [])


def main():
    brave = find_brave()
    was_running = brave_running()
    print("==> Fermeture de Brave...")
    close_brave()
    print(f"==> Relance de Brave avec le port de debug ({PORT})...")
    launch_brave(brave, f"--remote-debugging-port={PORT}",
                 "--disable-features=DevToolsDebuggingRestrictions", "--restore-last-session")
    try:
        wait_port()
        cookies = filter_x(read_cookies())
    finally:
        close_brave()
        if was_running:
            print("==> Relance de Brave sans port de debug...")
            launch_brave(brave, "--restore-last-session")
    missing = missing_required(cookies)
    if missing:
        raise SystemExit(f"Cookies manquants ({', '.join(missing)}) : connecte-toi à x.com dans Brave, puis relance.")
    save_cookies(cookies)
    print(f"OK : {len(cookies)} cookies x.com écrits dans {COOKIE_PATH}")
    print("Noms : " + ", ".join(sorted(c["name"] for c in cookies)))


if __name__ == "__main__":
    main()
