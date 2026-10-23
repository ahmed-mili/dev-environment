#!/usr/bin/env python3
"""shop_common.py — navigateur Playwright, consentement cookies, détection de blocage, utilitaires."""
import json
import os
import re
import subprocess
import sys
from datetime import datetime

os.environ.setdefault("PYTHONIOENCODING", "utf-8")
for _s in (sys.stdout, sys.stderr):
    try:
        _s.reconfigure(encoding="utf-8")
    except Exception:
        pass

UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36")

EXIT_BLOCKED = 3      # captcha / mur anti-bot / connexion exigée
EXIT_NOT_PRODUCT = 4  # page chargée mais ce n'est pas une fiche reconnue


def eprint(*a):
    print(*a, file=sys.stderr)


def ensure_deps():
    need = []
    for mod, pip in [("playwright", "playwright"), ("bs4", "beautifulsoup4"), ("lxml", "lxml")]:
        try:
            __import__(mod)
        except ImportError:
            need.append(pip)
    if need:
        eprint("[deps] Installation de : " + ", ".join(need))
        subprocess.run([sys.executable, "-m", "pip", "install", "-U", "-q", *need], check=True)
    from playwright.sync_api import sync_playwright
    try:
        with sync_playwright() as p:
            p.chromium.launch(headless=True).close()
            return
    except Exception:
        pass
    eprint("[deps] Installation de Chromium pour Playwright...")
    subprocess.run([sys.executable, "-m", "playwright", "install", "chromium"], check=True)


class Blocked(Exception):
    pass


BLOCK_PATTERNS = [
    (r"geo\.captcha-delivery\.com|datadome", "DataDome (anti-bot)"),
    (r"Saisissez les caract.res que vous voyez|api-services-support@amazon|Toutes nos excuses", "captcha Amazon"),
    (r"Just a moment\.\.\.|cf-challenge|Checking your browser", "Cloudflare"),
    (r"Access Denied|Request unsuccessful\. Incapsula", "accès refusé"),
    (r"V.rification de s.curit.|Are you a robot|Êtes-vous un robot", "vérification robot"),
]


def check_blocked(page, html):
    title = ""
    try:
        title = page.title()
    except Exception:
        pass
    visible = re.sub(r"<[^>]+>", " ", re.sub(r"(?is)<(script|style)\b.*?</\1>", "", html))
    sample = title + " " + html[:200000]
    for pat, name in BLOCK_PATTERNS:
        if re.search(pat, sample, re.I) and len(clean(visible)) < 3000:
            raise Blocked(name)
    if "/ap/signin" in page.url:
        raise Blocked("connexion exigée (redirigé vers /ap/signin)")


CONSENT_JS = """() => {
  const re = /^(tout refuser|refuser|refuser tout|continuer sans accepter|reject all|decline)$/i;
  const ids = ['sp-cc-rejectall-link','cookieConsentRefuseButton','didomi-notice-disagree-button','onetrust-reject-all-handler'];
  for (const id of ids) { const e = document.getElementById(id); if (e) { e.click(); return id; } }
  for (const e of document.querySelectorAll('button,a,input[type=submit]')) {
    const t = (e.innerText || e.value || '').trim();
    if (re.test(t)) { e.click(); return t; }
  }
  return null;
}"""


class Browser:
    def __init__(self, headed=False, cookies=None):
        self.headed = headed
        self.cookies = cookies or []

    def __enter__(self):
        from playwright.sync_api import sync_playwright
        self._pw = sync_playwright().start()
        args = ["--disable-backgrounding-occluded-windows", "--disable-renderer-backgrounding",
                "--disable-background-timer-throttling", "--disable-features=CalculateNativeWinOcclusion"]
        self.browser = self._pw.chromium.launch(headless=not self.headed, args=args if self.headed else [])
        self.ctx = self.browser.new_context(locale="fr-FR", user_agent=UA,
                                            viewport={"width": 1366, "height": 900})
        if self.cookies:
            self.ctx.add_cookies(self.cookies)
        self.page = self.ctx.new_page()
        if self.headed:
            # fenêtre minimisée : le focus revient à Ahmed, la page reste "visible" pour le JS
            try:
                s = self.ctx.new_cdp_session(self.page)
                w = s.send("Browser.getWindowForTarget")
                s.send("Browser.setWindowBounds", {"windowId": w["windowId"], "bounds": {"windowState": "minimized"}})
            except Exception as e:
                eprint(f"[headed] minimisation impossible : {e}")
        return self

    def __exit__(self, *a):
        try:
            self.browser.close()
        finally:
            self._pw.stop()

    def get(self, url, wait=2500, scroll=False):
        pg = self.page
        pg.goto(url, wait_until="domcontentloaded", timeout=60000)
        pg.wait_for_timeout(wait)
        try:
            pg.evaluate(CONSENT_JS)
        except Exception:
            pass
        if scroll:
            for _ in range(6):
                pg.mouse.wheel(0, 2500)
                pg.wait_for_timeout(400)
        html = pg.content()
        check_blocked(pg, html)
        return html


def soup(html):
    from bs4 import BeautifulSoup
    return BeautifulSoup(html, "lxml")


def clean(s):
    return re.sub(r"\s+", " ", (s or "").replace("\xa0", " ")).strip()


def num(s):
    """'1 299,90 €' / '279€ 95' / 4,7 -> float."""
    if s is None:
        return None
    if isinstance(s, (int, float)):
        return float(s)
    t = clean(str(s))
    m = re.search(r"(\d[\d ]*)\s*(?:€|EUR)\s*(\d{2})\b", t)  # 279€ 95
    if m:
        return float(m.group(1).replace(" ", "") + "." + m.group(2))
    m = re.search(r"\d[\d ]*(?:[.,]\d+)?", t)
    return float(m.group(0).replace(" ", "").replace(",", ".")) if m else None


MONTHS = {"janvier": 1, "février": 2, "fevrier": 2, "mars": 3, "avril": 4, "mai": 5, "juin": 6,
          "juillet": 7, "août": 8, "aout": 8, "septembre": 9, "octobre": 10, "novembre": 11, "décembre": 12, "decembre": 12}


def parse_date(s):
    """Renvoie 'AAAA-MM-JJ' ou None."""
    t = clean(s).lower()
    m = re.search(r"(\d{4})-(\d{2})-(\d{2})", t)
    if m:
        return m.group(0)
    m = re.search(r"(\d{1,2})/(\d{1,2})/(\d{4})", t)
    if m:
        return f"{m.group(3)}-{int(m.group(2)):02d}-{int(m.group(1)):02d}"
    m = re.search(r"(\d{1,2})(?:er)? ([a-zéûè]+) (\d{4})", t)
    if m and m.group(2) in MONTHS:
        return f"{m.group(3)}-{MONTHS[m.group(2)]:02d}-{int(m.group(1)):02d}"
    return None


def jsonld_product(sp):
    """Premier objet schema.org Product (gère @graph, listes, type en minuscule)."""
    def walk(o):
        if isinstance(o, list):
            for x in o:
                r = walk(x)
                if r:
                    return r
        elif isinstance(o, dict):
            t = o.get("@type")
            ts = t if isinstance(t, list) else [t]
            if any(str(x).lower() == "product" for x in ts):
                return o
            return walk(o.get("@graph"))
    for b in sp.select('script[type="application/ld+json"]'):
        try:
            r = walk(json.loads(b.string or ""))
        except ValueError:
            continue
        if r:
            return r
    return None


AVAIL = {"InStock": "En stock", "OutOfStock": "Rupture de stock", "LimitedAvailability": "Stock limité",
         "PreOrder": "Précommande", "BackOrder": "Sur commande", "SoldOut": "Épuisé", "Discontinued": "Arrêté"}


def avail_text(v):
    return AVAIL.get(str(v or "").rsplit("/", 1)[-1], str(v) if v else None)


def jsonld_reviews(prod):
    out = []
    revs = (prod or {}).get("review") or []
    if isinstance(revs, dict):
        revs = [revs]
    for r in revs:
        rr = r.get("reviewRating") or {}
        a = r.get("author")
        out.append({
            "author": (a.get("name") if isinstance(a, dict) else a),
            "rating": num(rr.get("ratingValue")), "scale": num(rr.get("bestRating")) or 5,
            "date": parse_date(r.get("datePublished") or r.get("dateCreated")),
            "title": clean(r.get("name")), "text": clean(r.get("reviewBody") or r.get("description")),
            "verified": None, "helpful": None,
        })
    return out


def now_iso():
    return datetime.now().astimezone().isoformat(timespec="seconds")
