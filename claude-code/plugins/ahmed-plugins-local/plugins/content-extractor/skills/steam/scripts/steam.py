#!/usr/bin/env python3
"""
steam.py — Infos, avis et actualités Steam via les API publiques (sans cookie ni clé).

Endpoints : store.steampowered.com/api/storesearch | /api/appdetails | /appreviews/<appid>
            api.steampowered.com/ISteamNews/GetNewsForApp/v2

Usage :
  python steam.py "Counter-Strike 2" --info --reviews --news --keyword snap --since 2024-08-01
  python steam.py 730 --news --keyword "Snap Tap" --since 2024-08-01 --until 2024-09-01
  python steam.py 730 --reviews --lang french --negative --recent --pages 2
  python steam.py "Elden Ring" --info

Sortie : <outdir>/<appid>/{app.json, reviews.md, reviews.json, news.md, news.json} + résumé stdout.
Sans --info/--reviews/--news : les trois.
"""
import argparse
import html
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

os.environ.setdefault("PYTHONIOENCODING", "utf-8")
try:
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
except Exception:
    pass

UA = {"User-Agent": "Mozilla/5.0 (steam.py)"}


def eprint(*a):
    print(*a, file=sys.stderr)


def get_json(url, retries=4):
    """GET JSON avec nouvel essai (429 / 5xx) à attente croissante."""
    wait = 5
    for i in range(retries):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=30) as r:
                return json.loads(r.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            if e.code in (429, 500, 502, 503) and i < retries - 1:
                eprint(f"HTTP {e.code}, nouvel essai dans {wait}s")
                time.sleep(wait)
                wait *= 3
                continue
            raise
    return {}


def fmt_ts(ts):
    return datetime.fromtimestamp(ts, timezone.utc).strftime("%Y-%m-%d")


def to_ts(s, end=False):
    d = datetime.strptime(s, "%Y-%m-%d").replace(tzinfo=timezone.utc)
    return int(d.timestamp()) + (86399 if end else 0)


def resolve(term, cc):
    if term.isdigit():
        return int(term)
    q = urllib.parse.urlencode({"term": term, "cc": cc, "l": "french"})
    d = get_json(f"https://store.steampowered.com/api/storesearch/?{q}")
    items = [i for i in d.get("items", []) if i.get("type") == "app"]
    if not items:
        sys.exit(f"Aucun résultat Steam pour « {term} »")
    for i in items:
        if i["name"].lower() == term.lower():
            return i["id"]
    eprint("Pas de correspondance exacte, candidats : " + "; ".join(f"{i['name']} ({i['id']})" for i in items[:5]))
    return items[0]["id"]


def clean(text):
    """BBCode Steam + HTML -> texte lisible."""
    t = text or ""
    t = re.sub(r"\[img\][^\[]*\[/img\]", "", t, flags=re.I)
    t = re.sub(r"\{STEAM_CLAN_IMAGE\}\S+", "", t)
    t = re.sub(r"\[url=([^\]]+)\](.*?)\[/url\]", r"\2 (\1)", t, flags=re.I | re.S)
    t = re.sub(r"\[h(\d)\](.*?)\[/h\1\]", lambda m: "\n" + "#" * int(m[1]) + " " + m[2] + "\n", t, flags=re.I | re.S)
    t = re.sub(r"\[\*\]", "\n- ", t)
    t = re.sub(r"\[/?(?:list|olist|b|i|u|strike|spoiler|quote|code|p|hr|table|tr|td|th|previewyoutube|carousel|expand|noparse)[^\]]*\]", "", t, flags=re.I)
    t = re.sub(r"<br\s*/?>", "\n", t, flags=re.I)
    t = re.sub(r"<img[^>]*>", "", t, flags=re.I)
    t = re.sub(r"<a [^>]*href=\"([^\"]+)\"[^>]*>(.*?)</a>", r"\2 (\1)", t, flags=re.I | re.S)
    t = re.sub(r"</?(?:p|li|ul|ol|div|h\d)[^>]*>", "\n", t, flags=re.I)
    t = re.sub(r"<[^>]+>", "", t)
    t = html.unescape(t)
    return re.sub(r"\n{3,}", "\n\n", t).strip()


def do_info(appid, cc, out):
    d = get_json(f"https://store.steampowered.com/api/appdetails?appids={appid}&cc={cc}&l=french")
    node = d.get(str(appid), {})
    if not node.get("success"):
        return "Infos : indisponibles (appdetails success=false : jeu retiré ou restreint)"
    a = node["data"]
    with open(os.path.join(out, "app.json"), "w", encoding="utf-8") as f:
        json.dump(a, f, ensure_ascii=False, indent=2)
    p = a.get("price_overview")
    if a.get("is_free"):
        prix = "Gratuit"
    elif p:
        prix = p["final_formatted"] + (f" (-{p['discount_percent']} %, base {p['initial_formatted']})" if p["discount_percent"] else "")
    else:
        prix = "non communiqué (pas de price_overview : pas encore sorti ou hors vente)"
    plat = ", ".join(k for k, v in a.get("platforms", {}).items() if v)
    genres = ", ".join(g["description"] for g in a.get("genres", []))
    pc = a.get("pc_requirements")
    req = clean(pc.get("minimum", "")) if isinstance(pc, dict) else ""
    return (f"Jeu : {a['name']} (appid {appid})\nPrix {cc} : {prix}\n"
            f"Éditeur : {', '.join(a.get('publishers', []))} | Développeur : {', '.join(a.get('developers', []))}\n"
            f"Sortie : {a.get('release_date', {}).get('date', '?')} | Genres : {genres} | Plateformes : {plat}\n"
            f"Config min (PC) : {req[:300].replace(chr(10), ' ')}")


def do_reviews(appid, a, out):
    params = {"json": 1, "language": a.lang, "filter": "all" if a.helpful else "recent",
              "review_type": "negative" if a.negative else "positive" if a.positive else "all",
              "purchase_type": a.purchase, "num_per_page": min(a.num, 100), "day_range": a.days}
    cursor, revs = "*", []
    # Les totaux ne sont renvoyés que si review_type=all : appel dédié (0 avis).
    st = dict(params, review_type="all", num_per_page=0, cursor="*")
    summary = get_json(f"https://store.steampowered.com/appreviews/{appid}?{urllib.parse.urlencode(st)}").get("query_summary", {})
    for _ in range(a.pages):
        params["cursor"] = cursor
        d = get_json(f"https://store.steampowered.com/appreviews/{appid}?{urllib.parse.urlencode(params)}")
        got = d.get("reviews", [])
        revs += got
        new = d.get("cursor")
        if not got or not new or new == cursor:
            break
        cursor = new
        time.sleep(1.5)
    with open(os.path.join(out, "reviews.json"), "w", encoding="utf-8") as f:
        json.dump({"summary": summary, "reviews": revs}, f, ensure_ascii=False, indent=2)
    tp, tn = summary.get("total_positive", 0), summary.get("total_negative", 0)
    pct = f"{100 * tp / (tp + tn):.1f} %" if tp + tn else "?"
    L = [f"# Avis Steam {appid}", "",
         f"Score global (langue `{a.lang}`) : {summary.get('review_score_desc', '?')} | {pct} positifs | {summary.get('total_reviews', '?')} avis ({tp} positifs, {tn} négatifs)",
         f"Filtres : {'plus utiles' if a.helpful else 'plus récents'}, type={params['review_type']}, achat={a.purchase}. Récupérés : {len(revs)}", ""]
    for r in revs:
        au = r.get("author", {})
        h = au.get("playtime_at_review", au.get("playtime_forever", 0)) / 60
        L += [f"## {fmt_ts(r['timestamp_created'])} | {'POSITIF' if r['voted_up'] else 'NÉGATIF'} | {h:.0f} h jouées | utile {r.get('votes_up', 0)}",
              "", clean(r.get("review", "")) or "(vide)", ""]
    with open(os.path.join(out, "reviews.md"), "w", encoding="utf-8") as f:
        f.write("\n".join(L))
    return f"Avis : {len(revs)} récupérés ; global {summary.get('review_score_desc', '?')} {pct} sur {summary.get('total_reviews', '?')}"


def do_news(appid, a, out):
    since = to_ts(a.since) if a.since else 0
    until = to_ts(a.until, True) if a.until else int(time.time())
    kw = a.keyword.lower() if a.keyword else None
    end, items, seen = until, [], set()
    for _ in range(a.news_pages):
        d = get_json(f"https://api.steampowered.com/ISteamNews/GetNewsForApp/v2/?appid={appid}&count=100&maxlength=0&enddate={end}")
        batch = d.get("appnews", {}).get("newsitems", [])
        if not batch:
            break
        for n in batch:
            if n["gid"] in seen or n["date"] < since or n["date"] > until:
                continue
            seen.add(n["gid"])
            if kw and kw not in (n["title"] + " " + n["contents"]).lower():
                continue
            items.append(n)
        oldest = min(n["date"] for n in batch)
        if oldest <= since or len(batch) < 100:
            break
        end = oldest - 1
        time.sleep(1)
    if a.count:
        items = items[: a.count]
    with open(os.path.join(out, "news.json"), "w", encoding="utf-8") as f:
        json.dump(items, f, ensure_ascii=False, indent=2)
    L = [f"# Actualités Steam {appid}", "",
         f"{len(items)} billet(s)" + (f", mot-clé `{a.keyword}`" if kw else "") + (f", depuis {a.since}" if a.since else ""), ""]
    for n in items:
        L += [f"## {fmt_ts(n['date'])} | {n['title']}", f"{n['url']}  (feed : {n.get('feedname')}, auteur : {n.get('author') or '?'})",
              "", clean(n["contents"]), ""]
    with open(os.path.join(out, "news.md"), "w", encoding="utf-8") as f:
        f.write("\n".join(L))
    return f"Actus : {len(items)} billet(s)" + "".join(f"\n  {fmt_ts(n['date'])} {n['title']} {n['url']}" for n in items[:8])


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("game", help="nom du jeu ou appid")
    p.add_argument("--outdir", default="steam_out")
    p.add_argument("--cc", default="FR", help="pays pour les prix")
    p.add_argument("--info", action="store_true")
    p.add_argument("--reviews", action="store_true")
    p.add_argument("--news", action="store_true")
    p.add_argument("--lang", default="all", help="avis : french, english, all...")
    p.add_argument("--negative", action="store_true")
    p.add_argument("--positive", action="store_true")
    p.add_argument("--recent", action="store_true", help="avis les plus récents (défaut)")
    p.add_argument("--helpful", action="store_true", help="avis les plus utiles")
    p.add_argument("--purchase", default="all", choices=["all", "steam", "non_steam_purchase"])
    p.add_argument("--days", type=int, default=365, help="fenêtre (jours) pour --helpful")
    p.add_argument("--num", type=int, default=20, help="avis par page (max 100)")
    p.add_argument("--pages", type=int, default=1, help="pages d'avis (cursor)")
    p.add_argument("--keyword", help="actus : filtre titre+contenu")
    p.add_argument("--since", help="actus : AAAA-MM-JJ")
    p.add_argument("--until", help="actus : AAAA-MM-JJ")
    p.add_argument("--count", type=int, default=0, help="actus : max de billets gardés")
    p.add_argument("--news-pages", type=int, default=30, help="pages de 100 billets parcourues vers le passé")
    a = p.parse_args()
    if not (a.info or a.reviews or a.news):
        a.info = a.reviews = a.news = True
    appid = resolve(a.game, a.cc)
    out = os.path.abspath(os.path.join(a.outdir, str(appid)))
    os.makedirs(out, exist_ok=True)
    print(f"appid {appid}")
    if a.info:
        print(do_info(appid, a.cc, out))
    if a.reviews:
        print(do_reviews(appid, a, out))
    if a.news:
        print(do_news(appid, a, out))
    print(f"Dossier : {out}")


if __name__ == "__main__":
    main()
