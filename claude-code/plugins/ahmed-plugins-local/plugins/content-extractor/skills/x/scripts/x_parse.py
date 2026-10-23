#!/usr/bin/env python3
"""
x_parse.py — Transforme le JSON GraphQL brut de X en tweets normalisés.

Volontairement INDÉPENDANT de la structure des réponses : on parcourt tout le
JSON et on garde chaque objet qui ressemble à un tweet (rest_id + legacy.full_text).
X réorganise souvent ses timelines (instructions, modules, curseurs) ; les objets
tweet eux-mêmes changent beaucoup moins. Pur, sans réseau : testé par unittest.
"""
import html
import re
from datetime import datetime

_URL = re.compile(r"^(?:https?://)?(?:www\.|mobile\.)?(?:x|twitter|fxtwitter|vxtwitter|fixupx|fixvx)\.com/"
                  r"(?:i/(?:web/)?status|([A-Za-z0-9_]{1,15})/status(?:es)?)/(\d+)", re.I)


def parse_status_url(url):
    m = _URL.match((url or "").strip())
    if not m:
        raise ValueError(f"Pas une URL de post X (attendu x.com/<user>/status/<id>) : {url!r}")
    user, tid = m.group(1), m.group(2)
    canon = f"https://x.com/{user}/status/{tid}" if user else f"https://x.com/i/status/{tid}"
    return canon, tid, user


def _is_tweet(d):
    leg = d.get("legacy")
    return (d.get("__typename") in (None, "Tweet") and bool(d.get("rest_id"))
            and isinstance(leg, dict) and "full_text" in leg)


def iter_tweet_results(node):
    if isinstance(node, dict):
        if _is_tweet(node):
            yield node
        for v in node.values():
            yield from iter_tweet_results(v)
    elif isinstance(node, list):
        for v in node:
            yield from iter_tweet_results(v)


def _get(d, *keys):
    for k in keys:
        if not isinstance(d, dict):
            return None
        d = d.get(k)
    return d


def _int(v):
    try:
        return int(v)
    except (TypeError, ValueError):
        return None


def _expand(text, urls, media):
    for u in urls or []:
        if u.get("url") and u.get("expanded_url"):
            text = text.replace(u["url"], u["expanded_url"])
    for m in media or []:
        if m.get("url"):
            text = text.replace(m["url"], "")
    return html.unescape(text).strip()


def _media(leg):
    items = _get(leg, "extended_entities", "media") or _get(leg, "entities", "media") or []
    out = []
    for m in items:
        if m.get("type") == "photo":
            out.append({"type": "photo", "url": m.get("media_url_https", "") + "?name=orig",
                        "preview": None, "alt": m.get("ext_alt_text")})
            continue
        mp4 = [v for v in _get(m, "video_info", "variants") or [] if v.get("content_type") == "video/mp4"]
        best = max(mp4, key=lambda v: v.get("bitrate") or 0) if mp4 else None
        out.append({"type": m.get("type"), "url": best["url"] if best else None,
                    "preview": m.get("media_url_https"), "alt": m.get("ext_alt_text")})
    return out


def _bindings(card):
    bv = card.get("binding_values") or []
    if isinstance(bv, dict):
        return bv
    return {b["key"]: b.get("value") or {} for b in bv if isinstance(b, dict) and "key" in b}


def _card_and_poll(t):
    card = _get(t, "card", "legacy")
    if not card:
        return None, None
    vals = _bindings(card)
    s = lambda k: (vals.get(k) or {}).get("string_value")
    if (card.get("name") or "").startswith("poll"):
        choices = []
        for i in range(1, 5):
            label = s(f"choice{i}_label")
            if label is None:
                break
            choices.append({"label": label, "count": _int(s(f"choice{i}_count"))})
        return None, {"choices": choices, "final": (vals.get("counts_are_final") or {}).get("boolean_value")}
    return {"title": s("title"), "description": s("description"),
            "url": s("card_url") or card.get("url"), "domain": s("vanity_url") or s("domain")}, None


def _article(t):
    a = _get(t, "article", "article_results", "result")
    if not a:
        return None
    blocks = _get(a, "content_state", "blocks") or []
    body = "\n\n".join(b.get("text", "") for b in blocks if b.get("text"))
    return {"title": a.get("title"), "text": body or a.get("preview_text")}


def _user(t):
    r = _get(t, "core", "user_results", "result") or {}
    core, leg = r.get("core") or {}, r.get("legacy") or {}
    return {"screen_name": core.get("screen_name") or leg.get("screen_name"),
            "name": core.get("name") or leg.get("name"),
            "verified": bool(r.get("is_blue_verified") or leg.get("verified"))}


def normalize(t):
    leg = t["legacy"]
    note = _get(t, "note_tweet", "note_tweet_results", "result")
    media_ents = _get(leg, "extended_entities", "media") or _get(leg, "entities", "media")
    if note and note.get("text"):
        text = _expand(note["text"], _get(note, "entity_set", "urls"), media_ents)
    else:
        text = _expand(leg.get("full_text", ""), _get(leg, "entities", "urls"), media_ents)
    author = _user(t)
    card, poll = _card_and_poll(t)
    pivot = t.get("birdwatch_pivot") or {}
    return {
        "id": t["rest_id"],
        "url": f"https://x.com/{author['screen_name'] or 'i'}/status/{t['rest_id']}",
        "author": author,
        "created_at": leg.get("created_at"),
        "text": text,
        "lang": leg.get("lang"),
        "reply_to": leg.get("in_reply_to_status_id_str"),
        "conversation_id": leg.get("conversation_id_str"),
        "quoted_id": leg.get("quoted_status_id_str"),
        "stats": {"replies": _int(leg.get("reply_count")), "retweets": _int(leg.get("retweet_count")),
                  "likes": _int(leg.get("favorite_count")), "quotes": _int(leg.get("quote_count")),
                  "bookmarks": _int(leg.get("bookmark_count")), "views": _int(_get(t, "views", "count"))},
        "media": _media(leg),
        "card": card,
        "poll": poll,
        "note": _get(pivot, "subtitle", "text") or pivot.get("title"),
        "article": _article(t),
        "source": "graphql",
    }


def _merge(old, new):
    for k, v in new.items():
        if old.get(k) in (None, [], {}, "") and v not in (None, [], {}, ""):
            old[k] = v


def collect(bodies):
    tweets = {}
    for b in bodies:
        for raw in iter_tweet_results(b):
            n = normalize(raw)
            if n["id"] in tweets:
                _merge(tweets[n["id"]], n)
            else:
                tweets[n["id"]] = n
    return tweets


def build_thread(tweets, focal_id):
    children = {}
    for tid, t in tweets.items():
        if t["reply_to"]:
            children.setdefault(t["reply_to"], []).append(tid)
    ancestors, cur = [], tweets.get(focal_id)
    while cur and cur["reply_to"] in tweets and cur["reply_to"] not in ancestors:
        cur = tweets[cur["reply_to"]]
        ancestors.insert(0, cur["id"])
    descendants, stack = set(), list(children.get(focal_id, []))
    while stack:
        tid = stack.pop()
        if tid not in descendants:
            descendants.add(tid)
            stack.extend(children.get(tid, []))
    focal = tweets.get(focal_id)
    author = focal["author"]["screen_name"] if focal else None
    self_thread, cur = [], focal_id
    while True:
        nxt = next((c for c in children.get(cur, []) if tweets[c]["author"]["screen_name"] == author), None)
        if not nxt:
            break
        self_thread.append(nxt)
        cur = nxt
    quoted = {t["quoted_id"] for t in tweets.values() if t["quoted_id"]}
    known = {focal_id, *ancestors, *descendants, *quoted}
    orphans = [tid for tid, t in tweets.items()
               if tid not in known and t["reply_to"] and t["reply_to"] not in tweets]
    return {"focal": focal_id, "ancestors": ancestors, "children": children,
            "descendants": descendants, "self_thread": self_thread, "orphans": orphans}


def format_date(created_at):
    try:
        return datetime.strptime(created_at, "%a %b %d %H:%M:%S %z %Y").strftime("%Y-%m-%d %H:%M UTC")
    except (TypeError, ValueError):
        return created_at or "?"
