#!/usr/bin/env python3
"""Récupère l'usage Ollama Cloud et le met en cache pour la statusline.

Pourquoi ce helper existe — et pourquoi il scrape une page web au lieu d'appeler une API :
  Ollama Cloud n'expose AUCUNE API d'usage (vérifié : /api/usage, /api/account/usage,
  /api/me/usage… → 404 ; /api/me signé → renvoie le plan mais pas les chiffres ; les
  réponses d'inférence /v1/messages ne portent aucun header rate-limit). Les chiffres
  ne vivent QUE sur la page authentifiée https://ollama.com/settings, rendue côté
  serveur. Le seul moyen de les obtenir par programme est donc de charger cette page
  avec le cookie de session du navigateur.

Deux modèles de quota coexistent selon le plan (2026-09) :
  - « Included usage » (Pro) : un budget mensuel en dollars, « $0.97 of $60 used »,
    « Resets in 4 weeks ». Section `monthly` du cache.
  - « Cloud usage » (historique / autres plans) : « Session usage » (5 h) et
    « Weekly usage » (7 j) en « xx.x% used ». Sections `session` / `weekly`.
  On écrit ce que la page expose ; la statusline rend les sections présentes.

Cookie, par ordre de priorité :
  1. ~/.claude/ollama-cookie.local : la valeur du cookie `__Secure-session` collée à
     la main depuis les DevTools du navigateur (Brave/Chrome/Edge chiffrent leurs
     cookies en app-bound, illisibles sans privilèges ; c'est la seule voie fiable).
     Le fichier peut aussi contenir un header Cookie complet (`a=1; b=2`).
  2. `cookies.sqlite` de Firefox (NON chiffré), balayé sur tous les profils
     plausibles — aucun nom d'utilisateur en dur, le repo reste partageable.

Sortie : ~/.claude/ollama-usage-cache.json (écriture atomique) :
  {"monthly":{"utilization":1.6,"used":"0.97","limit":"60","reset":"in 4 weeks"},
   "fetched_at": 1790000000}
  ou, sur un plan à fenêtres :
  {"session":{"utilization":19.6,"pct":"19.6","reset":"in 6 minutes"},
   "weekly": {"utilization":3.5, "pct":"3.5", "reset":"in 3 days"},
   "fetched_at": 1780531200}

Lancé en arrière-plan (détaché) par le binaire statusline quand le cache a > 60 s ET
qu'on est en mode Ollama. Best-effort : en cas d'échec (pas de cookie, hors-ligne,
page modifiée) on ne touche pas au cache existant — la dernière valeur connue persiste.
"""

import glob
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

SETTINGS_URL = "https://ollama.com/settings"
CLAUDE_DIR = os.path.join(os.path.expanduser("~"), ".claude")
CACHE = os.path.join(CLAUDE_DIR, "ollama-usage-cache.json")
COOKIE_FILE = os.path.join(CLAUDE_DIR, "ollama-cookie.local")


def read_cookie_file(path=COOKIE_FILE):
    """Header Cookie depuis le fichier collé à la main, ou None s'il est absent/vide.

    Une valeur nue (sans `=`) est la valeur de `__Secure-session` ; sinon on prend
    la ligne telle quelle comme header complet.
    """
    try:
        with open(path, encoding="utf-8") as f:
            raw = f.read().strip()
    except OSError:
        return None
    if not raw:
        return None
    if "=" not in raw:
        return f"__Secure-session={raw}"
    return raw


def firefox_cookie_dbs():
    """Tous les cookies.sqlite Firefox plausibles : Windows natif, drvfs, Linux."""
    pats = [
        os.path.expanduser("~/AppData/Roaming/Mozilla/Firefox/Profiles/*/cookies.sqlite"),
        "/mnt/*/Users/*/AppData/Roaming/Mozilla/Firefox/Profiles/*/cookies.sqlite",
        os.path.expanduser("~/.mozilla/firefox/*/cookies.sqlite"),
        os.path.expanduser("~/snap/firefox/common/.mozilla/firefox/*/cookies.sqlite"),
        os.path.expanduser(
            "~/.var/app/org.mozilla.firefox/.mozilla/firefox/*/cookies.sqlite"
        ),
    ]
    out = []
    for p in pats:
        out.extend(sorted(glob.glob(p)))
    return out


def read_ollama_cookies(db):
    """Renvoie le header Cookie pour ollama.com depuis un cookies.sqlite, ou None.

    On copie le fichier (+ -wal/-shm) avant lecture : Firefox peut le tenir ouvert en
    mode WAL, une lecture directe verrouillerait ou raterait les écritures récentes.
    On ne garde que les cookies envoyés à ollama.com et on exige `__Secure-session`
    (le cookie d'auth) — sinon le profil n'est pas connecté.
    """
    import sqlite3

    tmp = tempfile.mktemp(suffix=".sqlite")
    try:
        for ext in ("", "-wal", "-shm"):
            if os.path.exists(db + ext):
                shutil.copy(db + ext, tmp + ext)
        con = sqlite3.connect(tmp)
        try:
            rows = con.execute(
                "SELECT name, value FROM moz_cookies "
                "WHERE host IN ('ollama.com', '.ollama.com')"
            ).fetchall()
        finally:
            con.close()
    except Exception:
        return None
    finally:
        for ext in ("", "-wal", "-shm"):
            try:
                os.remove(tmp + ext)
            except OSError:
                pass

    names = {n for n, _ in rows}
    if "__Secure-session" not in names:
        return None
    return "; ".join(f"{n}={v}" for n, v in rows)


def find_cookie():
    cookie = read_cookie_file()
    if cookie:
        return cookie
    for db in firefox_cookie_dbs():
        cookie = read_ollama_cookies(db)
        if cookie:
            return cookie
    return None


def fetch_settings(cookie):
    """GET /settings avec le cookie. curl gère HTTP/2 + décompression. None si KO/redirigé."""
    try:
        out = subprocess.run(
            [
                "curl", "-sL", "-m", "20", SETTINGS_URL,
                "-H", f"Cookie: {cookie}",
                "-H", "User-Agent: Mozilla/5.0",
                "-w", "\n%{http_code}\n%{url_effective}",
            ],
            capture_output=True, text=True, timeout=25,
        ).stdout
    except Exception:
        return None
    parts = out.rsplit("\n", 2)
    if len(parts) != 3:
        return None
    html, code, final_url = parts
    # Cookie périmé → redirige vers la page de connexion : on rejette. Le titre de
    # section varie selon le plan (« Cloud usage », « Included usage ») : on exige
    # juste qu'une section d'usage existe.
    if code != "200" or "signin" in final_url or " usage" not in html:
        return None
    return html


def _window_text(html, label, end):
    """Texte brut (balises retirées, espaces normalisés) de [label:end], ou None."""
    i = html.find(label)
    if i == -1:
        return None
    window = html[i:end if end > i else i + 4000]
    text = re.sub(r"<[^>]+>", " ", window)
    return re.sub(r"\s+", " ", text)


def _reset(text):
    rm = re.search(r"Resets (in [^.]+?)\s*\.", text)
    return rm.group(1).strip() if rm else None


def parse_window(html, label, end):
    """(pct float, pct_str, reset) pour 'Session usage' / 'Weekly usage', ou None.

    On conserve la chaîne brute du pourcentage (`pct_str`, ex. "3.5") et le libellé de
    reset tel qu'Ollama l'écrit (`reset`, ex. "in 3 days") pour un affichage identique
    à ollama.com/settings. Le float sert au remplissage de la barre.
    """
    text = _window_text(html, label, end)
    if text is None:
        return None
    pm = re.search(r"([\d.]+)\s*%\s*used", text)
    if not pm:
        return None
    pct_str = pm.group(1)
    return float(pct_str), pct_str, _reset(text)


def parse_monthly(html):
    """{'utilization', 'used', 'limit', 'reset'} pour 'Monthly usage', ou None.

    Format Pro 2026-09 : « $0.97 of $60 used » puis « Resets in 4 weeks. ». Les
    montants gardent la chaîne d'Ollama (`used`/`limit`) ; `utilization` est le
    ratio en % pour la barre.
    """
    text = _window_text(html, "Monthly usage", -1)
    if text is None:
        return None
    m = re.search(r"\$\s*([\d,]+(?:\.\d+)?)\s*of\s*\$\s*([\d,]+(?:\.\d+)?)\s*used", text)
    if not m:
        return None
    used_s, limit_s = m.group(1), m.group(2)
    used, limit = float(used_s.replace(",", "")), float(limit_s.replace(",", ""))
    if limit <= 0:
        return None
    return {
        "utilization": round(used / limit * 100, 1),
        "used": used_s,
        "limit": limit_s,
        "reset": _reset(text),
    }


def parse_page(html):
    """Dict des sections trouvées (monthly / session / weekly), sans fetched_at."""
    data = {}
    monthly = parse_monthly(html)
    if monthly:
        data["monthly"] = monthly

    si = html.find("Session usage")
    wi = html.find("Weekly usage")
    session = parse_window(html, "Session usage", wi if (si != -1 and wi > si) else -1)
    weekly = parse_window(html, "Weekly usage", -1)
    if session:
        data["session"] = {"utilization": session[0], "pct": session[1], "reset": session[2]}
    if weekly:
        data["weekly"] = {"utilization": weekly[0], "pct": weekly[1], "reset": weekly[2]}
    return data


def main():
    cookie = find_cookie()
    if not cookie:
        print(
            f"ollama-usage: aucun cookie ollama.com (colle __Secure-session dans {COOKIE_FILE})",
            file=sys.stderr,
        )
        return 1

    html = fetch_settings(cookie)
    if not html:
        print("ollama-usage: échec du chargement de /settings (cookie périmé ?)", file=sys.stderr)
        return 2

    data = parse_page(html)
    if not data:
        print("ollama-usage: parsing impossible (page modifiée ?)", file=sys.stderr)
        return 3
    data["fetched_at"] = int(time.time())

    os.makedirs(os.path.dirname(CACHE), exist_ok=True)
    tmp = CACHE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f)
    os.replace(tmp, CACHE)  # atomique
    print(f"ollama-usage: {json.dumps(data)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
