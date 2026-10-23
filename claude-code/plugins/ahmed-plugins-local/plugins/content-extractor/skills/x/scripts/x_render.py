#!/usr/bin/env python3
"""x_render.py — Rend les tweets normalisés en un post.md lisible."""
from x_parse import format_date


def _quote(text, indent):
    pad = "  " * indent
    return "\n".join(f"{pad}> {line}" if line else f"{pad}>" for line in (text or "").splitlines() or [""])


def _block(t, indent=0):
    pad = "  " * indent
    a, s = t["author"], t["stats"]
    head = (f"{pad}**@{a['screen_name']}** ({a['name']}{', vérifié' if a['verified'] else ''})"
            f" · {format_date(t['created_at'])} · [lien]({t['url']})")
    stats = " · ".join(f"{label} {s[k]}" for k, label in
                       (("likes", "likes"), ("retweets", "reposts"), ("replies", "réponses"),
                        ("quotes", "citations"), ("bookmarks", "signets"), ("views", "vues"))
                       if s.get(k) is not None)
    lines = [head, _quote(t["text"], indent)]
    if stats:
        lines.append(f"{pad}{stats}")
    for m in t["media"]:
        alt = f" (alt : {m['alt']})" if m.get("alt") else ""
        lines.append(f"{pad}- [{m['type']}] {m['url'] or m.get('preview')}{alt}")
    if t["card"]:
        c = t["card"]
        lines.append(f"{pad}- Carte : {c.get('title') or ''} — {c.get('domain') or ''} {c.get('url') or ''}".rstrip())
        if c.get("description"):
            lines.append(f"{pad}  {c['description']}")
    if t["poll"]:
        state = "final" if t["poll"].get("final") else "en cours"
        lines.append(f"{pad}- Sondage ({state}) : " + " ; ".join(f"{c['label']} : {c['count']}" for c in t["poll"]["choices"]))
    if t["note"]:
        lines.append(f"{pad}- Community Note : {t['note']}")
    if t["article"]:
        lines.append(f"{pad}- Article : {t['article'].get('title') or ''}\n\n{t['article'].get('text') or ''}")
    return "\n".join(lines)


def direct_replies(tweets, thread):
    """Reponses de premier niveau (au post ou a un maillon du thread de l'auteur), ordre de capture."""
    skip = set(thread["self_thread"])
    out = []
    for parent in [thread["focal"], *thread["self_thread"]]:
        out += [c for c in thread["children"].get(parent, []) if c not in skip and c in tweets]
    return out


def top_replies(tweets, thread, n=20):
    """Top n des reponses directes par likes decroissants (egalite : vues)."""
    def key(i):
        s = tweets[i]["stats"]
        return (s.get("likes") or 0, s.get("views") or 0)
    return sorted(direct_replies(tweets, thread), key=key, reverse=True)[:n]


def render_markdown(tweets, thread, top_n=20):
    focal = tweets[thread["focal"]]
    out = [f"# Post de @{focal['author']['screen_name']}", ""]
    if thread["ancestors"]:
        out += ["## Contexte (posts parents)", ""] + [_block(tweets[i]) + "\n" for i in thread["ancestors"]]
    out += ["## Post", "", _block(focal), ""]
    if focal["quoted_id"] and focal["quoted_id"] in tweets:
        out += ["## Post cité", "", _block(tweets[focal["quoted_id"]]), ""]
    if thread["self_thread"]:
        out += ["## Thread de l'auteur", ""] + [_block(tweets[i]) + "\n" for i in thread["self_thread"]]
    top = top_replies(tweets, thread, top_n)
    out += [f"## Meilleures réponses (top {top_n} par likes, {len(top)} affichées)", ""]
    out += [_block(tweets[i]) + "\n" for i in top]
    return "\n".join(out).rstrip() + "\n"


def render_replies(tweets, thread, header):
    """replies.md : directes par likes decroissants, sous-reponses indentees dans l'ordre de conversation."""
    skip = set(thread["self_thread"])
    direct = direct_replies(tweets, thread)
    ordered = sorted(direct, key=lambda i: ((tweets[i]["stats"].get("likes") or 0,
                                             tweets[i]["stats"].get("views") or 0)), reverse=True)
    n_direct = len([c for c in thread["children"].get(thread["focal"], []) if c in tweets and c not in skip])
    n_self = len(direct) - n_direct
    out = [f"# Réponses à @{tweets[thread['focal']]['author']['screen_name']}", "", header, "",
           f"{n_direct} réponses directes au post, {n_self} réponses au thread de l'auteur, "
           f"{len([i for i in thread['descendants'] if i not in skip])} au total (sous-réponses incluses).", ""]

    def walk(tid, depth):
        for c in thread["children"].get(tid, []):
            if c in tweets and c not in skip:
                out.append(_block(tweets[c], depth) + "\n")
                walk(c, depth + 1)

    for tid in ordered:
        out.append(_block(tweets[tid]) + "\n")
        walk(tid, 1)
    if thread["orphans"]:
        out += ["## Réponses dont le parent n'a pas été récupéré", ""]
        out += [_block(tweets[i]) + f"\n(en réponse à {tweets[i]['reply_to']})\n" for i in thread["orphans"]]
    return "\n".join(out).rstrip() + "\n"
