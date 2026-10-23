#!/usr/bin/env python3
"""
prices.py - Offres et historique de prix de LeDénicheur (ledenicheur.fr) et idealo (idealo.fr).

Les deux sites bloquent le headless (Cloudflare pour LeDénicheur, 503 pour idealo) :
le script pilote Brave AVEC fenêtre (profil temporaire jetable, fenêtre minimisée
via CDP pour ne jamais voler le focus) et ferme toujours le navigateur.

Usage :
  python prices.py "<url produit>" [--outdir DIR] [--no-history] [--no-series] [--resolve-links]
  python prices.py --find "<nom produit>" [--site ledenicheur|idealo|both] [--limit N] [--outdir DIR]

Sortie produit : <outdir>/<site>_<id>/offers.json, offers.md, history.json, history.md
Sortie --find  : <outdir>/find_<slug>.json + liste imprimée.
Codes de sortie : 0 ok, 2 blocage anti-bot / captcha, 3 page disparue, 1 autre erreur.
Aucune image téléchargée. Dépendance (auto-installée) : playwright.
"""
import argparse
import datetime as dt
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unicodedata
import urllib.parse

os.environ.setdefault("PYTHONIOENCODING", "utf-8")
try:
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
except Exception:
    pass

BROWSERS = [
    "C:/Program Files/BraveSoftware/Brave-Browser/Application/brave.exe",
    "C:/Program Files (x86)/BraveSoftware/Brave-Browser/Application/brave.exe",
    "C:/Program Files/Google/Chrome/Application/chrome.exe",
    "C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe",
]
ARGS = ["--disable-backgrounding-occluded-windows", "--disable-renderer-backgrounding",
        "--disable-background-timer-throttling",
        "--disable-features=CalculateNativeWinOcclusion"]
IDEALO_SITE_ID = 4  # idealo.fr


class Blocked(Exception):
    pass


class Gone(Exception):
    pass


def eprint(*a):
    print(*a, file=sys.stderr)


def ensure_deps():
    try:
        import playwright  # noqa: F401
    except ImportError:
        eprint("[deps] installation de playwright")
        subprocess.run([sys.executable, "-m", "pip", "install", "-U", "-q", "playwright"], check=True)


# ---------- utilitaires ----------
def norm(s):
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode().lower()
    s = re.sub(r"(\d)\s*(to|tb)\b", r"\1to", s)
    s = re.sub(r"(\d)\s*(go|gb)\b", r"\1go", s)
    return s


def tokens(s):
    return [t for t in re.split(r"[^a-z0-9]+", norm(s)) if t]


def parse_price(s):
    if s is None:
        return None
    m = re.search(r"(\d[\d\s\u00a0\u202f.]*(?:,\d{1,2})?)", str(s))
    if not m:
        return None
    t = re.sub(r"[\s\u00a0\u202f]", "", m.group(1))
    if "," in t:
        t = t.replace(".", "").replace(",", ".")
    try:
        return float(t)
    except ValueError:
        return None


MONTHS = [("janv", 1), ("jan", 1), ("fev", 2), ("mars", 3), ("mar", 3), ("avr", 4), ("mai", 5),
          ("juin", 6), ("juil", 7), ("aou", 8), ("sep", 9), ("oct", 10), ("nov", 11), ("dec", 12)]


def parse_fr_date(s):
    m = re.search(r"(\d{1,2})\s+([^\W\d_]+)\.?\s+(\d{4})", s or "")
    if not m:
        return None
    mon = norm(m.group(2))
    for pre, n in MONTHS:
        if mon.startswith(pre):
            return f"{m.group(3)}-{n:02d}-{int(m.group(1)):02d}"
    return None


def now_iso():
    return dt.datetime.now().astimezone().isoformat(timespec="seconds")


def slug(s, n=60):
    return (re.sub(r"[^0-9A-Za-z_-]+", "_", norm(s)).strip("_") or "x")[:n]


def fmt(p):
    return "n/d" if p is None else f"{p:.2f} €".replace(".", ",")


# ---------- navigateur ----------
class Browser:
    def __init__(self):
        from playwright.sync_api import sync_playwright
        self.pw = sync_playwright().start()
        exe = next((b for b in BROWSERS if os.path.exists(b)), None)
        if not exe:
            raise SystemExit("Aucun Brave/Chrome/Edge trouvé (headless bloqué par les deux sites).")
        self.tmp = tempfile.mkdtemp(prefix="prices_profile_")
        self.ctx = self.pw.chromium.launch_persistent_context(
            self.tmp, executable_path=exe, headless=False, locale="fr-FR", args=ARGS,
            viewport={"width": 1300, "height": 1000})
        self.page = self.new_page()

    def new_page(self):
        pg = self.ctx.new_page()
        try:  # minimise la fenêtre : le focus revient à l'utilisateur, la page reste "visible"
            s = self.ctx.new_cdp_session(pg)
            w = s.send("Browser.getWindowForTarget")
            s.send("Browser.setWindowBounds", {"windowId": w["windowId"], "bounds": {"windowState": "minimized"}})
        except Exception as e:
            eprint(f"[warn] minimisation impossible : {e}")
        return pg

    def close(self):
        try:
            self.ctx.close()
        except Exception:
            pass
        try:
            self.pw.stop()
        except Exception:
            pass
        shutil.rmtree(self.tmp, ignore_errors=True)

    def goto(self, url, settle=6000):
        pg = self.page
        r = pg.goto(url, wait_until="domcontentloaded", timeout=60000)
        pg.wait_for_timeout(settle)
        # défi Cloudflare ("Un instant...") : attendre qu'il se résolve
        for _ in range(6):
            t = (pg.title() or "").lower()
            if "un instant" in t or "just a moment" in t:
                pg.wait_for_timeout(5000)
            else:
                break
        t = (pg.title() or "")
        body = ""
        try:
            body = pg.inner_text("body")[:2000].lower()
        except Exception:
            pass
        status = r.status if r else None
        if "un instant" in t.lower() or "just a moment" in t.lower():
            raise Blocked("défi Cloudflare non résolu")
        if status in (403, 429, 503) or re.search(r"captcha|vérification de sécurité|access denied|are you human", body[:600]):
            raise Blocked(f"anti-bot (HTTP {status})")
        if status == 404 or re.search(r"cette page a disparu|page introuvable|n'existe plus", t.lower() + " " + body[:300]):
            raise Gone(f"page disparue (HTTP {status})")
        return status

    def cookies(self):
        for t in ("Tout accepter", "Accepter et fermer", "Accepter"):
            try:
                self.page.get_by_role("button", name=re.compile(t, re.I)).first.click(timeout=1200)
                return
            except Exception:
                pass


def site_of(url):
    h = urllib.parse.urlparse(url).netloc.lower()
    if "ledenicheur" in h:
        return "ledenicheur"
    if "idealo" in h:
        return "idealo"
    raise SystemExit("URL non reconnue (attendu : ledenicheur.fr ou idealo.fr)")


def product_id(url, site):
    if site == "ledenicheur":
        m = re.search(r"[?&]p=(\d+)", url) or re.search(r"-p(\d+)(?:[/?#]|$)", url)
    else:
        m = re.search(r"/prix/(\d+)/", url)
    if not m:
        raise SystemExit("Pas une page produit : LeDénicheur = product.php?p=NNN, idealo = /prix/NNN/nom.html")
    return m.group(1)


def stats(points):
    vals = [p["price"] for p in points if p.get("price") is not None]
    if not vals:
        return {}
    return {"min": min(vals), "max": max(vals), "current": vals[-1], "first": vals[0], "n": len(vals)}


# ---------- LeDénicheur ----------
JS_LD_OFFERS = r"""() => {
  const items = [...document.querySelectorAll('[data-test=OfferListItem]')];
  return items.map(it => {
    const a = it.querySelector('a[data-test=OfferClickoutButton]');
    const t = e => e ? e.innerText.replace(/\s+/g,' ').trim() : null;
    const img = it.querySelector('img');
    return {merchant: img ? img.alt : null, title: t(it.querySelector('p')),
            price_text: t(it.querySelector('h4')),
            link: a ? a.href : null, text: t(it)};
  });
}"""


def ld_expand(b):
    """Déplie la liste complète : clique jusqu'à ce que le nombre d'offres cesse de croître."""
    pg = b.page
    try:
        pg.wait_for_selector("[data-test=OfferListItem]", timeout=15000)
    except Exception:
        return
    for pat in (r"Voir toutes les offres", r"^Afficher \d+$"):
        for _ in range(3):
            before = pg.locator("[data-test=OfferListItem]").count()
            try:
                loc = pg.get_by_role("button", name=re.compile(pat)).first
                loc.scroll_into_view_if_needed(timeout=8000)
                loc.click(timeout=8000)
                pg.wait_for_function(
                    "n => document.querySelectorAll('[data-test=OfferListItem]').length > n", arg=before, timeout=8000)
            except Exception:
                break


def ld_offers(b):
    pg = b.page
    try:
        name = pg.locator("h1").first.inner_text(timeout=3000).strip()
    except Exception:
        name = re.sub(r"\s+au meilleur prix.*$", "", pg.title() or "")
    body = pg.inner_text("body")
    empty = "Aucun magasin ne vend ce produit" in body
    ld_expand(b)
    raw = pg.evaluate(JS_LD_OFFERS)
    offers = []
    for o in raw:
        if not o["link"]:
            continue
        txt = o["text"] or ""
        stock = "En stock" if "En stock" in txt else ("Rupture" if re.search(r"rupture|indisponible|épuisé", txt, re.I) else None)
        offers.append({"merchant": o["merchant"], "title": o["title"], "price": parse_price(o["price_text"]),
                       "shipping": None, "price_with_shipping": None, "stock": stock, "link": o["link"]})
    # frais de port : bascule "Prix livraison incluse" (meilleur effort)
    try:
        tgl = pg.get_by_text("Prix livraison incluse").first
        tgl.scroll_into_view_if_needed(timeout=5000)
        tgl.click(timeout=5000)
        pg.wait_for_timeout(1500)
        by = {o["link"]: parse_price(o["price_text"]) for o in pg.evaluate(JS_LD_OFFERS) if o["link"]}
        for o in offers:
            p2 = by.get(o["link"])
            if p2 is not None and o["price"] is not None and p2 >= o["price"]:
                o["price_with_shipping"] = p2
                o["shipping"] = round(p2 - o["price"], 2)
        tgl.click(timeout=5000)
    except Exception:
        pass
    m = re.search(r"Nous avons trouvé ce produit dans (\d+) boutiques?, dont (\d+)", body)
    extra = {"shops_total": int(m.group(1)) if m else None, "shops_partner": int(m.group(2)) if m else None}
    m2 = re.search(r"Offres sans lien direct\s*\n+\s*Dès\s*\n+\s*([\d\s\u00a0,]+)\s*€", body)
    extra["unlinked_group_from_price"] = parse_price(m2.group(1)) if m2 else None
    return name, offers, empty, extra


JS_LD_SERIES = r"""async () => {
  const w = document.querySelector('.recharts-wrapper'); const r = w.getBoundingClientRect();
  const d = document.querySelector('path.recharts-area-curve').getAttribute('d');
  const xs = [...d.matchAll(/[ML]\s*(-?[\d.]+),/g)].map(m => parseFloat(m[1]));
  const out = [];
  for (const x of xs) {
    w.dispatchEvent(new MouseEvent('mousemove', {bubbles: true, clientX: r.left + x, clientY: r.top + r.height / 2}));
    await new Promise(res => setTimeout(res, 15));
    const t = document.querySelector('.recharts-tooltip-wrapper'); out.push(t ? t.innerText : '');
  }
  return out;
}"""


def ld_history(b, series=True):
    pg = b.page
    out = {}
    try:
        pg.locator(".recharts-responsive-container").first.scroll_into_view_if_needed(timeout=4000)
    except Exception:
        return {"error": "graphique d'historique introuvable"}
    pg.wait_for_timeout(800)
    for label, key in (("3 mois", "3m"), ("6 mois", "6m"), ("1 année", "1y")):
        prev_d = pg.evaluate("(document.querySelector('path.recharts-area-curve') || {getAttribute: () => null}).getAttribute('d')") if key != "3m" else None
        try:
            pg.get_by_role("button", name=label, exact=True).click(timeout=8000)
        except Exception:
            continue
        try:
            pg.wait_for_function(
                "o => { const e = document.querySelector('path.recharts-area-curve'); return e && e.getAttribute('d') !== o; }",
                arg=prev_d, timeout=8000)
        except Exception:
            if prev_d is not None:  # clic sans effet : une seconde tentative
                pg.get_by_role("button", name=label, exact=True).click(timeout=8000)
                pg.wait_for_timeout(3000)
        pg.wait_for_timeout(800)
        body = pg.inner_text("body")
        cur = re.search(r"Prix neuf le plus bas actuel\s*\n+\s*([^\n]+)", body)
        mm = re.search(r"Min:\s*([^|\n]+?)\s*\|\s*Max:\s*([^\n]+)", body)
        tr = re.search(r"Tendance de prix[^\n]*\n+\s*([^\n]+)", body)
        entry = {"current_text": cur.group(1).strip() if cur else None,
                 "current": parse_price(cur.group(1)) if cur and "€" in cur.group(1) else None,
                 "min_text": parse_price(mm.group(1)) if mm else None,
                 "max_text": parse_price(mm.group(2)) if mm else None,
                 "trend": tr.group(1).strip() if tr else None}
        if series:
            pts = {}
            try:  # événements mousemove synthétiques dans la page : 1 an en ~6 s (la vraie souris : 1 s par point)
                raw = pg.evaluate(JS_LD_SERIES)
                for tip in raw:
                    day = parse_fr_date(tip)
                    pr = parse_price(tip.split(chr(10))[0]) if tip else None
                    if day and pr is not None:
                        pts[day] = pr
            except Exception as e:
                entry["series_error"] = str(e)[:120]
            entry["points"] = [{"date": k, "price": v} for k, v in sorted(pts.items())]
            if entry["points"]:
                entry.update({"series_" + k: v for k, v in stats(entry["points"]).items()})
        out[key] = entry
    return out


# ---------- idealo ----------
JS_ID_OFFERS = r"""() => {
  const items = [...document.querySelectorAll('li.productOffers-listItem')];
  const t = e => e ? e.innerText.replace(/\s+/g,' ').trim() : null;
  return items.map(it => {
    const cta = it.querySelector('a.productOffers-listItemOfferCtaLeadout');
    return {merchant: cta ? cta.getAttribute('data-shop-name') : null,
            title: t(it.querySelector('.productOffers-listItemTitle')),
            price_text: t(it.querySelector('.productOffers-listItemOfferPrice')),
            link: cta ? cta.href : null, text: t(it)};
  });
}"""


def id_offers(b, resolve=False):
    pg = b.page
    try:
        name = pg.locator("h1").first.inner_text(timeout=3000).strip()
    except Exception:
        name = re.sub(r"\s+au meilleur prix.*$", "", pg.title() or "")
    for _ in range(4):  # offres supplémentaires si un bouton existe
        try:
            btn = pg.get_by_text(re.compile(r"Afficher plus d.offres", re.I)).first
            btn.scroll_into_view_if_needed(timeout=8000)
            btn.click(timeout=8000)
            pg.wait_for_timeout(2500)
        except Exception as e:
            if "Timeout" not in str(e):
                eprint(f"[warn] offres supplémentaires : {str(e)[:100]}")
            break
    raw = pg.evaluate(JS_ID_OFFERS)
    offers = []
    for o in raw:
        price = parse_price(o["price_text"])
        txt = o["text"] or ""
        m = re.search(r"([\d\s\u00a0\u202f.,]+)\s*€\s*livraison incl", txt)
        pws = parse_price(m.group(1)) if m else None
        ship = round(pws - price, 2) if (pws is not None and price is not None and pws >= price) else None
        dm = re.search(r"Livraison\s*:\s*(jusqu'à [^ ]+ [\d.]+)", txt)
        offers.append({"merchant": o["merchant"], "title": o["title"], "price": price, "shipping": ship,
                       "price_with_shipping": pws, "stock": "En stock (offre listée)",
                       "delivery": dm.group(1) if dm else None, "link": o["link"]})
    if resolve:
        for o in offers:
            if o["link"]:
                try:
                    r = b.ctx.request.get(o["link"], max_redirects=0, timeout=15000)
                    loc = r.headers.get("location")
                    if loc:
                        o["merchant_url"] = loc
                except Exception:
                    pass
    extra = {}
    try:
        for s in pg.eval_on_selector_all("script[type='application/ld+json']", "e=>e.map(x=>x.textContent)"):
            j = json.loads(s)
            ao = j.get("offers") if isinstance(j, dict) else None
            if isinstance(ao, dict) and ao.get("@type") == "AggregateOffer":
                extra = {"jsonld_low": ao.get("lowPrice"), "jsonld_high": ao.get("highPrice"),
                         "jsonld_offer_count": ao.get("offerCount")}
    except Exception:
        pass
    return name, offers, extra


def id_history(b, pid):
    out = {}
    for per, key in (("3M", "3m"), ("6M", "6m"), ("1Y", "1y")):
        try:
            r = b.page.evaluate(
                "async (u)=>{const r=await fetch(u);return [r.status, await r.text()]}",
                f"/price-chart/sites/{IDEALO_SITE_ID}/products/{pid}/history?period={per}")
            if r[0] != 200:
                out[key] = {"error": f"HTTP {r[0]}"}
                continue
            j = json.loads(r[1])
            pts = [{"date": d["x"], "price": d["y"] / 100.0} for d in j.get("data", []) if d.get("y") is not None]
            s = stats(pts)
            out[key] = {"start": j.get("startDate"), "points": pts, "min": s.get("min"), "max": s.get("max"),
                        "current": s.get("current"), "first": s.get("first"), "n": s.get("n")}
        except Exception as ex:
            out[key] = {"error": str(ex)[:120]}
    return out


# ---------- sorties ----------
def lowest(offers):
    ps = [o["price"] for o in offers if o["price"] is not None and o.get("stock") != "Rupture"]
    return min(ps) if ps else None


def write_offers(d, site, pid, url, name, offers, extra, empty, warnings):
    low = lowest(offers)
    data = {"site": site, "product_id": pid, "url": url, "name": name, "scraped_at": now_iso(),
            "offer_count": len(offers), "lowest_price": low, "no_offers_listed": empty,
            "warnings": warnings, **extra, "offers": offers}
    with open(os.path.join(d, "offers.json"), "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    L = [f"# {name}", "", f"- Source : {site} ({url})", f"- Relevé : {data['scraped_at']}",
         f"- Nombre d'offres : {len(offers)}", f"- Prix le plus bas : {fmt(low)}"]
    for k, v in extra.items():
        if v is not None:
            L.append(f"- {k} : {v}")
    for w in warnings:
        L.append(f"- ATTENTION : {w}")
    L += ["", "| Marchand | Prix | Frais de port | Total livré | Stock | Lien |", "|---|---|---|---|---|---|"]
    for o in offers:
        L.append(f"| {o['merchant'] or '?'} | {fmt(o['price'])} | {fmt(o['shipping'])} | {fmt(o['price_with_shipping'])} | "
                 f"{o.get('stock') or 'n/d'} | {o.get('merchant_url') or o['link'] or 'sans lien direct'} |")
    with open(os.path.join(d, "offers.md"), "w", encoding="utf-8") as f:
        f.write("\n".join(L) + "\n")
    return data


def mm_of(e):
    return (e.get("series_min", e.get("min", e.get("min_text"))),
            e.get("series_max", e.get("max", e.get("max_text"))))


def write_history(d, site, pid, name, hist):
    data = {"site": site, "product_id": pid, "name": name, "scraped_at": now_iso(), "periods": hist}
    with open(os.path.join(d, "history.json"), "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    L = [f"# Historique des prix : {name}", "", f"Relevé : {data['scraped_at']} ({site})", "",
         "| Période | Actuel | Min | Max | Tendance | Points |", "|---|---|---|---|---|---|"]
    for k, e in hist.items():
        if "error" in e and "points" not in e:
            L.append(f"| {k} | erreur : {e['error']} | | | | |")
            continue
        mn, mx = mm_of(e)
        L.append(f"| {k} | {fmt(e.get('current', e.get('series_current')))} | {fmt(mn)} | {fmt(mx)} | "
                 f"{e.get('trend') or ''} | {len(e.get('points', []))} |")
    with open(os.path.join(d, "history.md"), "w", encoding="utf-8") as f:
        f.write("\n".join(L) + "\n")


def run_product(url, args):
    site = site_of(url)
    pid = product_id(url, site)
    d = os.path.abspath(os.path.join(args.outdir, f"{site}_{pid}"))
    os.makedirs(d, exist_ok=True)
    b = Browser()
    try:
        b.goto(url)
        if site == "ledenicheur":
            b.cookies()
            name, offers, empty, extra = ld_offers(b)
        else:
            name, offers, extra = id_offers(b, args.resolve_links)
            empty = not offers
        warnings = []
        if empty or not offers:
            warnings.append("aucune offre listée sur la page (produit indisponible chez tous les marchands ?)")
        if site == "idealo" and extra.get("jsonld_low") and offers and lowest(offers) is not None:
            if abs(lowest(offers) - extra["jsonld_low"]) > 0.01:
                warnings.append(f"prix bas des offres ({fmt(lowest(offers))}) différent du JSON-LD ({extra['jsonld_low']}) : variantes ?")
        data = write_offers(d, site, pid, url, name, offers, extra, empty, warnings)
        files = [os.path.join(d, "offers.json"), os.path.join(d, "offers.md")]
        hist = None
        if not args.no_history:
            hist = ld_history(b, not args.no_series) if site == "ledenicheur" else id_history(b, pid)
            if hist and "error" not in hist:
                write_history(d, site, pid, name, hist)
                files += [os.path.join(d, "history.json"), os.path.join(d, "history.md")]
            else:
                warnings.append(f"historique indisponible : {hist}")
        print(f"Produit : {name}\nSite : {site}  (id {pid})\nOffres : {len(offers)}  |  prix le plus bas : {fmt(data['lowest_price'])}")
        if hist and "error" not in hist:
            for k, e in hist.items():
                mn, mx = mm_of(e)
                print(f"Historique {k} : actuel {fmt(e.get('current'))}, min {fmt(mn)}, max {fmt(mx)}, {len(e.get('points', []))} points")
        for w in warnings:
            print("ATTENTION :", w)
        for f in files:
            print("Fichier :", f)
    finally:
        b.close()


def candidates_ld(b, query):
    b.goto("https://www.ledenicheur.fr/search?query=" + urllib.parse.quote(query), 7000)
    b.cookies()
    rows = b.page.evaluate(r"""() => [...document.querySelectorAll('a[href*="product.php?p="]')].map(a => ({
        url: a.href, name: a.innerText.replace(/\s+/g,' ').trim()})).filter(r => r.name)""")
    seen, out = set(), []
    for r in rows:
        if r["url"] not in seen:
            seen.add(r["url"])
            out.append(r)
    return out


def candidates_id(b, query):
    b.goto("https://www.idealo.fr/prechcat.html?q=" + urllib.parse.quote_plus(query), 6000)
    rows = b.page.evaluate(r"""() => [...document.querySelectorAll('a[href*="/prix/"]')].map(a => ({
        url: a.href, name: (a.innerText || a.title || '').replace(/\s+/g,' ').trim()})).filter(r => r.name)""")
    best = {}
    for r in rows:
        if not re.search(r"/prix/\d+/", r["url"]):
            continue
        r["name"] = re.sub(r"\s+-\s+dans\s+.*$", "", r["name"])
        if r["url"] not in best or len(r["name"]) < len(best[r["url"]]["name"]):
            best[r["url"]] = r
    return list(best.values())


def run_find(query, args):
    qt = tokens(query)
    b = Browser()
    res = {}
    try:
        for site in (["ledenicheur", "idealo"] if args.site == "both" else [args.site]):
            try:
                cands = candidates_ld(b, query) if site == "ledenicheur" else candidates_id(b, query)
            except (Blocked, Gone) as e:
                print(f"[{site}] BLOQUÉ : {e}")
                res[site] = {"error": str(e)}
                continue
            for c in cands:
                ct = set(tokens(c["name"]))
                c["match"] = all(t in ct for t in qt)
            good = [c for c in cands if c["match"]][: args.limit]
            for c in good:  # vérification au contenu sur la page produit elle-même
                try:
                    b.goto(c["url"], 4000)
                    title = (b.page.title() or "") + " " + b.page.locator("h1").first.inner_text(timeout=2500)
                    c["verified"] = all(t in set(tokens(title)) for t in qt)
                    c["page_title"] = b.page.title()
                except Exception as e:
                    c["verified"] = False
                    c["verify_error"] = str(e)[:100]
            res[site] = {"candidates_total": len(cands), "matches": good}
            print(f"\n== {site} : {len(cands)} résultats, {len(good)} correspondent à tous les mots de « {query} »")
            for c in good:
                print(f"  [{'OK vérifié' if c.get('verified') else 'non vérifié'}] {c['name']} {c.get('price') or ''}\n     {c['url']}")
            if not good:
                print("  aucune page produit ne contient tous les mots : ne rien deviner, essayer le MCP brave-search")
    finally:
        b.close()
    os.makedirs(args.outdir, exist_ok=True)
    f = os.path.abspath(os.path.join(args.outdir, f"find_{slug(query)}.json"))
    with open(f, "w", encoding="utf-8") as fh:
        json.dump({"query": query, "at": now_iso(), "results": res}, fh, ensure_ascii=False, indent=2)
    print("\nFichier :", f)
    if all("error" in v for v in res.values()):
        sys.exit(2)


def main():
    ap = argparse.ArgumentParser(description="Offres et historique de prix LeDénicheur / idealo.")
    ap.add_argument("url", nargs="?")
    ap.add_argument("--find", metavar="NOM")
    ap.add_argument("--site", choices=["ledenicheur", "idealo", "both"], default="both")
    ap.add_argument("--limit", type=int, default=3)
    ap.add_argument("--outdir", default="prices_out")
    ap.add_argument("--no-history", action="store_true")
    ap.add_argument("--no-series", action="store_true", help="LeDénicheur : ne pas survoler le graphique (min/max texte seulement)")
    ap.add_argument("--resolve-links", action="store_true", help="idealo : résoudre la redirection clickout vers l'URL marchand")
    a = ap.parse_args()
    if not a.url and not a.find:
        ap.error("URL produit ou --find requis")
    ensure_deps()
    try:
        if a.find:
            run_find(a.find, a)
        else:
            run_product(a.url, a)
    except Blocked as e:
        eprint(f"ECHEC anti-bot : {e}. Aucune donnée écrite comme valide.")
        sys.exit(2)
    except Gone as e:
        eprint(f"ECHEC : {e}")
        sys.exit(3)


if __name__ == "__main__":
    main()
