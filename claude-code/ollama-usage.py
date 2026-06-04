#!/usr/bin/env python3
"""Récupère l'usage Ollama Cloud (Session + Weekly) et le met en cache pour la statusline.

Pourquoi ce helper existe — et pourquoi il scrape une page web au lieu d'appeler une API :
  Ollama Cloud n'expose AUCUNE API d'usage (vérifié : /api/usage, /api/account/usage,
  /api/me/usage… → 404 ; /api/me signé → renvoie le plan mais pas les %; les réponses
  d'inférence /v1/messages ne portent aucun header rate-limit). Les chiffres
  Session/Weekly ne vivent QUE sur la page authentifiée https://ollama.com/settings,
  rendue côté serveur. Le seul moyen de les obtenir par programme est donc de charger
  cette page avec le cookie de session du navigateur.

Cookie : on lit le cookie `__Secure-session` directement dans le `cookies.sqlite` de
  Firefox (NON chiffré, contrairement à Chrome/Edge/Brave qui chiffrent via DPAPI).
  On balaie tous les profils Firefox, Windows (via /mnt/c) comme Linux natif — aucun
  nom d'utilisateur en dur.

Sortie : ~/.claude/ollama-usage-cache.json (écriture atomique) :
  {"session":{"utilization":19.6,"reset":"6m"},
   "weekly": {"utilization":3.5, "reset":"3j"},
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
CACHE = os.path.join(os.path.expanduser("~"), ".claude", "ollama-usage-cache.json")


def firefox_cookie_dbs():
    """Tous les cookies.sqlite Firefox plausibles, Windows (drvfs) + Linux natif.

    Globs sur `*` pour l'utilisateur et le profil : zéro valeur perso en dur (le repo
    est partageable). Trié pour un ordre déterministe.
    """
    pats = [
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
    On ne garde que les cookies envoyés à ollama.com (host `ollama.com` / `.ollama.com`)
    et on exige `__Secure-session` (le cookie d'auth) — sinon le profil n'est pas connecté.
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
    # Cookie périmé → redirige vers la page de connexion : on rejette.
    if code != "200" or "signin" in final_url or "Cloud usage" not in html:
        return None
    return html


def parse_window(html, label, end):
    """Extrait (pct float, pct_str, reset) pour la section 'Session usage'/'Weekly usage'.

    On ancre sur le libellé puis on prend, dans [label:end], le 1er '% used' et le 1er
    'Resets in …'. La borne `end` (libellé suivant) évite de mordre sur la section d'à
    côté ; la fenêtre doit rester généreuse car les boutons de segments par modèle
    repoussent le 'Resets in' à ~2,1k caractères après le libellé.

    On conserve la chaîne brute du pourcentage (`pct_str`, ex. "3.5") et le libellé de
    reset tel qu'Ollama l'écrit (`reset`, ex. "in 3 days") pour un affichage identique
    à ollama.com/settings. La valeur float (`pct`) sert au remplissage de la barre.
    """
    i = html.find(label)
    if i == -1:
        return None
    window = html[i:end]
    pm = re.search(r"([\d.]+)\s*%\s*used", window)
    if not pm:
        return None
    pct_str = pm.group(1)
    rm = re.search(r"Resets (in [^<.]+)", window)
    reset = rm.group(1).strip() if rm else None
    return float(pct_str), pct_str, reset


def main():
    cookie = None
    for db in firefox_cookie_dbs():
        cookie = read_ollama_cookies(db)
        if cookie:
            break
    if not cookie:
        print("ollama-usage: aucun cookie ollama.com trouvé (connecte-toi sur Firefox)", file=sys.stderr)
        return 1

    html = fetch_settings(cookie)
    if not html:
        print("ollama-usage: échec du chargement de /settings (cookie périmé ?)", file=sys.stderr)
        return 2

    si = html.find("Session usage")
    wi = html.find("Weekly usage")
    # Borne la session au libellé Weekly (sinon +4000) ; Weekly sur +4000.
    session = parse_window(html, "Session usage", wi if (si != -1 and wi > si) else (si + 4000))
    weekly = parse_window(html, "Weekly usage", (wi + 4000) if wi != -1 else 0)
    if not session and not weekly:
        print("ollama-usage: parsing impossible (page modifiée ?)", file=sys.stderr)
        return 3

    data = {"fetched_at": int(time.time())}
    if session:
        data["session"] = {"utilization": session[0], "pct": session[1], "reset": session[2]}
    if weekly:
        data["weekly"] = {"utilization": weekly[0], "pct": weekly[1], "reset": weekly[2]}

    os.makedirs(os.path.dirname(CACHE), exist_ok=True)
    tmp = CACHE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f)
    os.replace(tmp, CACHE)  # atomique
    print(f"ollama-usage: {json.dumps(data)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
