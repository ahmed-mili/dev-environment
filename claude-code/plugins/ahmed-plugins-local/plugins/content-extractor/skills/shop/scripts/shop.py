#!/usr/bin/env python3
"""
shop.py — Fiche produit complète d'un marchand français (Amazon.fr, LDLC, Cdiscount, TopAchat).

Fiche  : python shop.py <url> [--outdir DIR] [--headed] [--negative] [--recent] [--max-reviews N]
                              [--pages N] [--no-reviews] [--no-cookies]
Recherche : python shop.py --search "<requête>" --site ldlc|cdiscount|topachat [--headed]

Sortie : <outdir>/<site>_<id>/ product.json, product.md, reviews.json, reviews.md, qa.md (si Q&A).
Codes de sortie : 0 ok, 2 usage, 3 bloqué (captcha / anti-bot / connexion), 4 page non reconnue.
Aucune image n'est téléchargée.
"""
import argparse
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from shop_common import (Blocked, Browser, EXIT_BLOCKED, EXIT_NOT_PRODUCT, ensure_deps, eprint, now_iso)  # noqa: E402
import shop_sites as S  # noqa: E402

COOKIE_PATH = (Path(os.environ.get("LOCALAPPDATA") or Path.home() / "AppData" / "Local")
               / "content-extractor" / "amazon-cookies.json")


def load_amazon_cookies():
    try:
        c = json.loads(COOKIE_PATH.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []
    names = {x.get("name") for x in c}
    return c if ("at-acbfr" in names or "x-acbfr" in names or "sess-at-acbfr" in names) else []


def norm5(r):
    if r.get("rating") is None:
        return None
    return r["rating"] * 5.0 / (r.get("scale") or 5)


def order_reviews(revs, negative, recent, limit):
    if negative:
        revs = [r for r in revs if norm5(r) is not None and norm5(r) <= 3.0]
        revs.sort(key=lambda r: (r.get("date") or ""), reverse=True)
    elif recent:
        revs.sort(key=lambda r: (r.get("date") or ""), reverse=True)
    return revs[:limit]


def fmt(v, suffix=""):
    return f"{v}{suffix}" if v not in (None, "", []) else "n/d"


def money(x):
    return f"{x:.2f}".replace(".", ",") + " €" if isinstance(x, (int, float)) else "n/d"


def write_product_md(p, path):
    L = [f"# {p['title']}", "", f"Relevé le {p['scraped_at']} · [{p['site']}]({p['canonical']})", "",
         "| Champ | Valeur |", "|---|---|"]
    rows = [("Marque", p["brand"]), ("Référence", p["reference"]), ("Identifiant", p["id"]), ("GTIN/EAN", p["gtin"]),
            ("Prix actuel", money(p["price"])), ("Prix barré", money(p["old_price"]) if p["old_price"] else None),
            ("Disponibilité", p["availability"]), ("Livraison", p["delivery"]), ("Vendu par", p["seller"]),
            ("Expédié par", p["shipped_by"]),
            ("Note", f"{p['rating']}/{int(p['rating_scale'])}" if p["rating"] is not None else None),
            ("Nombre d'avis", p["review_count"]), ("URL canonique", p["canonical"])]
    for k, v in rows:
        L.append(f"| {k} | {str(fmt(v)).replace('|', '/')} |")
    if p.get("histogram"):
        L += ["", "Répartition des notes : " + ", ".join(f"{k} étoiles {v} %" for k, v in sorted(p["histogram"].items(), reverse=True))]
    if p["bullets"]:
        L += ["", "## Points forts", ""] + [f"- {b}" for b in p["bullets"]]
    if p["description"]:
        L += ["", "## Description", "", p["description"]]
    if p["specs"]:
        L += ["", "## Caractéristiques techniques", "", "| Groupe | Caractéristique | Valeur |", "|---|---|---|"]
        for g, k, v in p["specs"]:
            L.append(f"| {g} | {k.replace('|', '/')} | {v.replace('|', '/')} |")
    if p["notes"]:
        L += ["", "## Remarques d'extraction", ""] + [f"- {n}" for n in p["notes"]]
    Path(path).write_text("\n".join(L) + "\n", encoding="utf-8")


def write_reviews_md(p, revs, path, negative, total_seen):
    mode = "négatifs (1 à 3 étoiles sur 5) d'abord, récents en tête" if negative else "tels que fournis par le site"
    L = [f"# Avis : {p['title']}", "",
         f"{len(revs)} avis affichés sur {total_seen} récupérés ({p['review_count'] or 'n/d'} annoncés au total). Mode : {mode}.", ""]
    for r in revs:
        sc = r.get("scale") or 5
        stars = f"{r['rating']:g}/{sc}" if r.get("rating") is not None else "?"
        flag = " · achat vérifié" if r.get("verified") else ""
        L += [f"## {stars} · {r.get('title') or '(sans titre)'}", "",
              f"{r.get('author') or 'Anonyme'} · {r.get('date') or r.get('date_text') or 'date n/d'}{flag}"
              + (f" · {r['helpful']} utile(s)" if r.get("helpful") else "")
              + (f" · {r['extra']}" if r.get("extra") else ""), "", r.get("text") or "", ""]
    Path(path).write_text("\n".join(L), encoding="utf-8")


def write_qa_md(p, qa, path):
    L = [f"# Questions et réponses : {p['title']}", ""]
    for q in qa:
        L += [f"## {q['question']}", ""] + [f"- {a}" for a in q["answers"]] + [""]
    Path(path).write_text("\n".join(L), encoding="utf-8")


def run_fiche(a):
    site = S.detect(a.url)
    if not site:
        eprint("Site non géré (Amazon.fr, LDLC, Cdiscount, TopAchat). Pour le reste : skill webpage.")
        return 2
    cookies = load_amazon_cookies() if (site == "amazon" and not a.no_cookies) else []
    o = {"negative": a.negative, "recent": a.recent, "pages": a.pages, "no_reviews": a.no_reviews}
    try:
        with Browser(headed=a.headed, cookies=cookies) as br:
            p, revs, qa = S.FETCHERS[site](br, a.url, o)
    except Blocked as e:
        eprint(f"BLOQUÉ ({site}) : {e}. Relancer avec --headed ; sinon MCP Playwright (Brave) ou claude-in-chrome.")
        return EXIT_BLOCKED
    except S.NotProduct as e:
        eprint(f"Page non reconnue comme fiche produit ({site}) : {e}")
        return EXIT_NOT_PRODUCT
    p["scraped_at"] = now_iso()
    out = Path(a.outdir).resolve() / f"{site}_{p['id']}"
    out.mkdir(parents=True, exist_ok=True)
    (out / "product.json").write_text(json.dumps(p, ensure_ascii=False, indent=1), encoding="utf-8")
    write_product_md(p, out / "product.md")
    shown = order_reviews(list(revs), a.negative, a.recent, a.max_reviews)
    files = ["product.json", "product.md"]
    if not a.no_reviews:
        (out / "reviews.json").write_text(json.dumps(shown, ensure_ascii=False, indent=1), encoding="utf-8")
        write_reviews_md(p, shown, out / "reviews.md", a.negative, len(revs))
        files += ["reviews.json", "reviews.md"]
    if qa:
        write_qa_md(p, qa, out / "qa.md")
        files.append("qa.md")
    print(f"OK {site} {p['id']} : {p['title']}")
    print(f"  prix {money(p['price'])} · note {fmt(p['rating'])}/{int(p['rating_scale'])} · {fmt(p['review_count'])} avis annoncés · "
          f"{len(shown)} avis écrits · {len(qa)} Q&A · stock : {fmt(p['availability'])}")
    for n in p["notes"]:
        print(f"  note : {n}")
    print(f"  dossier : {out}")
    for f in files:
        print(f"  - {out / f}")
    return 0


def run_search(a):
    if a.site not in ("ldlc", "cdiscount", "topachat", "amazon"):
        eprint("--site attendu : ldlc, cdiscount ou topachat")
        return 2
    try:
        with Browser(headed=a.headed) as br:
            res = S.search(br, a.site, a.search)
    except Blocked as e:
        eprint(f"BLOQUÉ ({a.site}) : {e}. Relancer avec --headed.")
        return EXIT_BLOCKED
    except S.NotProduct as e:
        eprint(str(e))
        return EXIT_NOT_PRODUCT
    if not res:
        eprint("Aucun résultat exploitable.")
        return EXIT_NOT_PRODUCT
    for i, r in enumerate(res, 1):
        print(f"{i}. {r['title']} | {r.get('price') or 'prix n/d'} | {r.get('rating') or '-'}\n   {r['url']}")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("url", nargs="?")
    ap.add_argument("--search")
    ap.add_argument("--site")
    ap.add_argument("--outdir", default="shop_extract")
    ap.add_argument("--headed", action="store_true", help="fenêtre visible (si le headless est bloqué)")
    ap.add_argument("--negative", action="store_true", help="avis 1 à 3 étoiles d'abord, plus récents en tête")
    ap.add_argument("--recent", action="store_true", help="avis triés du plus récent au plus ancien")
    ap.add_argument("--max-reviews", type=int, default=40)
    ap.add_argument("--pages", type=int, default=3, help="pages d'avis Amazon (session connectée), 10 avis par page")
    ap.add_argument("--no-reviews", action="store_true")
    ap.add_argument("--no-cookies", action="store_true", help="Amazon : ignorer la session Brave")
    a = ap.parse_args()
    if not a.url and not a.search:
        ap.print_usage()
        return 2
    ensure_deps()
    return run_search(a) if a.search else run_fiche(a)


if __name__ == "__main__":
    sys.exit(main())
