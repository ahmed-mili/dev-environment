#!/usr/bin/env python3
"""
x_cookies.py — Emplacement et format des cookies x.com d'Ahmed.

Les cookies vivent HORS de tout repo (~/.claude est versionné) :
%LOCALAPPDATA%\\content-extractor\\x-cookies.json, au format Playwright.
Seuls les cookies du domaine x.com (et sous-domaines) y entrent.
"""
import json
import os
import time
from pathlib import Path

COOKIE_PATH = (Path(os.environ.get("LOCALAPPDATA") or Path.home() / "AppData" / "Local")
               / "content-extractor" / "x-cookies.json")
REQUIRED = ("auth_token", "ct0")


def _is_x_domain(domain):
    d = (domain or "").lstrip(".").lower()
    return d == "x.com" or d.endswith(".x.com")


def _to_playwright(c):
    same = c.get("sameSite")
    out = {
        "name": c["name"], "value": c["value"], "domain": c["domain"],
        "path": c.get("path") or "/", "httpOnly": bool(c.get("httpOnly")),
        "secure": bool(c.get("secure")),
        "sameSite": same if same in ("Strict", "Lax", "None") else "Lax",
    }
    exp = c.get("expires")
    if isinstance(exp, (int, float)) and exp > 0:
        out["expires"] = exp
    return out


def filter_x(cookies):
    return [_to_playwright(c) for c in cookies if _is_x_domain(c.get("domain"))]


def missing_required(cookies):
    names = {c.get("name") for c in cookies}
    return [n for n in REQUIRED if n not in names]


def save_cookies(cookies, path=COOKIE_PATH):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(cookies, indent=1), encoding="utf-8")


def load_cookies(path=COOKIE_PATH, now=None):
    path = Path(path)
    try:
        cookies = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if not isinstance(cookies, list) or missing_required(cookies):
        return None
    now = time.time() if now is None else now
    auth = next(c for c in cookies if c.get("name") == "auth_token")
    if "expires" in auth and auth["expires"] < now:
        return None
    return cookies
