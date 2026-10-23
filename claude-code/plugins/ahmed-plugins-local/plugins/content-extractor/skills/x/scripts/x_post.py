#!/usr/bin/env python3
"""
x_post.py — Extrait 100 % d'un post X : post, thread de l'auteur, toutes les
réponses, post cité, carte, sondage, Community Note, article, médias.

Connecté (cookies de x_login.py) : capture GraphQL via x_capture.py.
Sans cookies / session expirée : bascule fxtwitter (post seul) et le dit.

Sortie : <outdir>/x_<id>/ avec post.md, tweets.json, raw/NNN_<op>.json, media/.

Usage :
  python x_post.py "<url>" [--outdir DIR] [--max-replies N] [--max-pages N]
    [--quick | --replies [--no-deep]] [--ranking Relevance|Recency|Likes] [--no-media] [--headed]
"""
import argparse
import json
import os
import sys
import urllib.parse
import urllib.request
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from x_capture import UA, capture  # noqa: E402
from x_cookies import load_cookies  # noqa: E402
from x_parse import build_thread, collect, parse_status_url  # noqa: E402
from x_render import direct_replies, render_markdown, render_replies, top_replies  # noqa: E402

try:
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
except Exception:
    pass


def fetch_fxtwitter(user, tid):
    url = f"https://api.fxtwitter.com/{user or 'i'}/status/{tid}"
    with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": UA}), timeout=30) as r:
        return json.loads(r.read().decode("utf-8"))


def _fx_one(t, quoted_id=None):
    a = t.get("author") or {}
    media = []
    for m in (t.get("media") or {}).get("all") or []:
        if m.get("type") == "photo":
            media.append({"type": "photo", "url": m.get("url"), "preview": None, "alt": m.get("altText")})
        else:
            media.append({"type": m.get("type"), "url": m.get("url"), "preview": m.get("thumbnail_url"), "alt": m.get("altText")})
    poll = t.get("poll")
    art = t.get("article")
    return {
        "id": str(t.get("id")), "url": t.get("url"),
        "author": {"screen_name": a.get("screen_name"), "name": a.get("name"),
                   "verified": bool((a.get("verification") or {}).get("verified"))},
        "created_at": t.get("created_at"), "text": t.get("text") or "", "lang": t.get("lang"),
        "reply_to": t.get("replying_to_status"), "conversation_id": None, "quoted_id": quoted_id,
        "stats": {k: t.get(src) for k, src in (("replies", "replies"), ("retweets", "retweets"), ("likes", "likes"),
                                               ("quotes", "quotes"), ("bookmarks", "bookmarks"), ("views", "views"))},
        "media": media, "card": None,
        "poll": {"choices": [{"label": c.get("label"), "count": c.get("count")} for c in poll.get("choices") or []],
                 "final": None} if poll else None,
        "note": (t.get("community_note") or {}).get("text"),
        "article": {"title": art.get("title"), "text": art.get("preview_text")} if isinstance(art, dict) else None,
        "source": "fxtwitter",
    }


def from_fxtwitter(data):
    t = data.get("tweet") or data
    q = t.get("quote")
    main = _fx_one(t, quoted_id=str(q["id"]) if q else None)
    return [main] + ([_fx_one(q)] if q else [])


def _ext(url, kind):
    ext = os.path.splitext(urllib.parse.urlparse(url).path)[1]
    return ext if ext else (".jpg" if kind == "photo" else ".mp4")


def download_media(tweets, outdir):
    n = 0
    mdir = Path(outdir) / "media"
    for t in tweets.values():
        for i, m in enumerate(t["media"]):
            if not m.get("url"):
                continue
            dest = mdir / f"{t['id']}_{i}{_ext(m['url'], m['type'])}"
            if not dest.exists():
                mdir.mkdir(parents=True, exist_ok=True)
                try:
                    req = urllib.request.Request(m["url"], headers={"User-Agent": UA})
                    with urllib.request.urlopen(req, timeout=120) as r:
                        dest.write_bytes(r.read())
                except Exception as e:
                    print(f"  média non téléchargé ({m['url']}) : {e}", file=sys.stderr)
                    continue
            m["file"] = str(dest)
            n += 1
    return n


def relevant_ids(tweets, thread):
    """Focal + ancestors + self_thread + descendants + orphans + cites, ordre de premiere apparition."""
    seen = []
    base = [thread["focal"], *thread["ancestors"], *thread["self_thread"], *thread["descendants"], *thread["orphans"]]
    for i in base:
        if i in tweets and i not in seen:
            seen.append(i)
    for i in list(seen):
        q = tweets[i].get("quoted_id")
        if q and q in tweets and q not in seen:
            seen.append(q)
    return seen


def dump_raw(out, payloads):
    raw = Path(out) / "raw"
    raw.mkdir(exist_ok=True)
    for i, p in enumerate(payloads):
        f = raw / f"{i:03d}_{p['op']}.json"
        if not f.exists():
            f.write_text(json.dumps(p["body"], ensure_ascii=False), encoding="utf-8")


def write_outputs(out, tweets, tid, no_media=False, replies_header=None, media_scope="focal"):
    """Ecrit post.md (top 20), tweets.json et, si replies_header, replies.md.
    media_scope : 'focal' = post, cite, thread de l'auteur ; 'all' = aussi les reponses."""
    thread = build_thread(tweets, tid)
    tweets = {i: tweets[i] for i in relevant_ids(tweets, thread)}
    if no_media:
        n_media = 0
    elif media_scope == "all":
        n_media = download_media(tweets, out)
    else:
        keep = {tid, tweets[tid].get("quoted_id"), *thread["ancestors"], *thread["self_thread"]}
        n_media = download_media({i: t for i, t in tweets.items() if i in keep}, out)
        for i, t in tweets.items():  # pour que tweets.json garde le chemin des medias deja telecharges
            for k, m in enumerate(t["media"]):
                f = Path(out) / "media" / f"{t['id']}_{k}{_ext(m['url'], m['type'])}" if m.get("url") else None
                if f and f.exists():
                    m["file"] = str(f)
    (Path(out) / "tweets.json").write_text(json.dumps(list(tweets.values()), ensure_ascii=False, indent=1), encoding="utf-8")
    (Path(out) / "post.md").write_text(render_markdown(tweets, thread), encoding="utf-8")
    if replies_header:
        (Path(out) / "replies.md").write_text(render_replies(tweets, thread, replies_header), encoding="utf-8")
    return tweets, thread, n_media


def main(argv=None):
    ap = argparse.ArgumentParser(description="Extrait un post X complet.")
    ap.add_argument("url")
    ap.add_argument("--outdir", default="x_extract")
    ap.add_argument("--max-replies", type=int, default=2000)
    ap.add_argument("--max-pages", type=int, default=150, help="pages de sous-fils max (passe profonde)")
    ap.add_argument("--quick", action="store_true", help="phase 1 : post + meilleures réponses visibles, sans défilement")
    ap.add_argument("--replies", action="store_true", help="phases 2 et 3 : réponses directes puis sous-fils (replies.md)")
    ap.add_argument("--no-deep", action="store_true", help="avec --replies : s'arrêter après la phase 2")
    ap.add_argument("--ranking", choices=["Relevance", "Recency", "Likes"], default=None,
                    help="tri des réponses demandé à X (rankingMode)")
    ap.add_argument("--no-media", action="store_true")
    ap.add_argument("--headed", action="store_true")
    args = ap.parse_args(argv)
    try:
        canon, tid, user = parse_status_url(args.url)
    except ValueError as e:
        print(e, file=sys.stderr)
        return 2
    out = Path(args.outdir) / f"x_{tid}"
    out.mkdir(parents=True, exist_ok=True)
    log = lambda m: print(m, file=sys.stderr)  # noqa: E731

    cookies, source, res = load_cookies(), "graphql", None
    if cookies:
        print(f"[1/3] Capture connectée de {canon}...")

        def phase2(r):
            tw = collect(p["body"] for p in r["payloads"])
            if tid not in tw:
                return
            dump_raw(out, r["payloads"])
            tw, th, _ = write_outputs(out, tw, tid, args.no_media,
                                      "Phase 2/3 : réponses directes complètes, sous-fils en cours")
            counter = tw[tid]["stats"]["replies"]
            print(f"PHASE 2 OK : {len(th['children'].get(tid, []))}/{counter} réponses directes, replies.md écrit", flush=True)

        res = capture(canon, cookies, max_replies=args.max_replies, headed=args.headed, max_pages=args.max_pages,
                      log=log, quick=args.quick, deep=not args.no_deep, ranking=args.ranking,
                      on_phase2=phase2 if args.replies else None)
        if res["login_required"]:
            print("Session X expirée : relance x_login.py. Bascule fxtwitter (post seul).")
            res = None
    else:
        print("Pas de cookies X valides : lance x_login.py pour avoir les réponses. Bascule fxtwitter (post seul).")

    if res:
        dump_raw(out, res["payloads"])
        tweets = collect(p["body"] for p in res["payloads"])
    if not res or tid not in tweets:
        if res:
            print("Post principal absent des captures : bascule fxtwitter.")
        source = "fxtwitter"
        tweets = {t["id"]: t for t in from_fxtwitter(fetch_fxtwitter(user, tid))}

    final = "Complet" if not (args.replies and args.no_deep) else "Phase 2 : réponses directes complètes, sous-fils non explorés"
    header = final if final != "Complet" else "complet"
    quick = args.quick and source == "graphql"
    tweets, thread, n_media = write_outputs(out, tweets, tid, args.no_media,
                                            None if quick else header,
                                            media_scope="focal" if quick else "all")
    counter = tweets[tid]["stats"]["replies"]
    direct = len(thread["children"].get(tid, []))
    pct = f" ({100 * direct // counter} %)" if counter else ""
    if quick:
        print(f"Mode rapide | Tweets : {len(tweets)} | Top réponses : {len(top_replies(tweets, thread))} "
              f"(sur {direct} directes capturées / compteur X : {counter}) | Médias : {n_media}"
              f" | --replies pour les réponses complètes")
    else:
        print(f"Source : {source} | Tweets : {len(tweets)} | Réponses directes : {direct} / compteur X : {counter}{pct}"
              f" | Réponses au total (sous-réponses incluses) : {len(thread['descendants'])}"
              f" | Orphelines : {len(thread['orphans'])} | Médias : {n_media}"
              f" | Limite --max-replies atteinte : {'oui' if res and res['capped'] else 'non'}"
              f" | Limite --max-pages atteinte : {'oui' if res and res.get('pages_capped') else 'non'}"
              f" | Pages incomplètes : {len(res['incomplete_pages']) if res else 0}")
        if args.replies and source == "graphql":
            print(f"PHASE 3 OK : {direct}/{counter} réponses directes, {len(thread['descendants'])} au total, replies.md final"
                  if not args.no_deep else f"PHASE 3 ignorée (--no-deep) : {direct}/{counter} réponses directes")
    print(f"Dossier : {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
