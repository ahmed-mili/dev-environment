#!/usr/bin/env python3
"""
x_capture.py — Ouvre un post X connecte et garde le JSON brut de TOUTES les
reponses GraphQL (/i/api/graphql/), comme ce que lit l'interface.

Deplie les reponses jusqu'a epuisement : defilement + clic sur les boutons
« Show more replies » / « Show probable spam » / « Show additional replies »,
puis visite des reponses dont le compteur depasse ce qui a ete capture
(sous-fils replies). Aucun parsing du DOM pour les donnees.
Seuls clics autorises : ces boutons de depliage (lecture seule).
"""
import json
import random
import re
import urllib.parse

GRAPHQL = "/i/api/graphql/"
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36")
EXPAND = re.compile(
    r"^(Show more replies|Show probable spam|Show additional replies.*|Show replies"
    r"|Afficher plus de réponses|Afficher les spams probables|Voir les réponses"
    r"|Afficher d'autres réponses.*)$", re.I)
MAX_ROUNDS = 400
MAX_DEEP_PAGES = 150
IDLE_ROUNDS = 4
STUCK_ROUNDS = 20  # garde-fou : rondes sans rien de neuf alors qu'un curseur Bottom reste en attente


def _op(url):
    try:
        return url.split(GRAPHQL, 1)[1].split("/")[1].split("?")[0]
    except IndexError:
        return "unknown"


def rewrite_ranking(url, mode):
    """URL TweetDetail avec variables.rankingMode = mode (Relevance, Recency, Likes). Autres URL inchangees."""
    if "TweetDetail" not in url or "?" not in url:
        return url
    base, query = url.split("?", 1)
    q = urllib.parse.parse_qs(query, keep_blank_values=True)
    try:
        v = json.loads(q["variables"][0])
    except (KeyError, ValueError, IndexError):
        return url
    v["rankingMode"] = mode
    q["variables"] = [json.dumps(v, separators=(",", ":"))]
    return base + "?" + urllib.parse.urlencode({k: x[0] for k, x in q.items()}, quote_via=urllib.parse.quote)


def ranking_passes(quick, ranking):
    """Tris demandes a X pour la page principale. Rapide : Likes (vrai top). Complet : tri par defaut
    PUIS Likes PUIS Recency (les listes se completent : mesure Berman 394 + 422 -> 480 directes). Explicite : une passe."""
    if ranking:
        return [ranking]
    return ["Likes"] if quick else [None, "Likes", "Recency"]


def _login_wall(page, result):
    if "/login" in page.url or "/i/flow/login" in page.url:
        return True
    return any(p["status"] in (401, 403) and "TweetDetail" in p["op"] for p in result["payloads"])


def cursor_labels(bodies):
    """Collect displayTreatment.actionText of cursor objects (not Top/Bottom)."""
    labels = set()

    def walk(o):
        if isinstance(o, dict):
            ct = o.get("cursorType")
            txt = (o.get("displayTreatment") or {}).get("actionText") if ct else None
            if ct and ct not in ("Top", "Bottom") and isinstance(txt, str) and txt.strip():
                labels.add(txt.strip())
            for v in o.values():
                walk(v)
        elif isinstance(o, list):
            for v in o:
                walk(v)
    for b in bodies:
        walk(b)
    return labels


def has_bottom_cursor(body):
    """True si le JSON contient un curseur cursorType == 'Bottom' (X a encore des reponses)."""
    if isinstance(body, dict):
        if body.get("cursorType") == "Bottom":
            return True
        return any(has_bottom_cursor(v) for v in body.values())
    if isinstance(body, list):
        return any(has_bottom_cursor(v) for v in body)
    return False


def has_bottom_terminate(body):
    """True si la reponse contient TimelineTerminateTimeline direction Bottom : X declare
    la fin de la liste, le curseur Bottom qui l'accompagne est vestigial."""
    if isinstance(body, dict):
        if body.get("type") == "TimelineTerminateTimeline" and body.get("direction") == "Bottom":
            return True
        return any(has_bottom_terminate(v) for v in body.values())
    if isinstance(body, list):
        return any(has_bottom_terminate(v) for v in body)
    return False


def bottom_pending(payloads_of_visit):
    """Le dernier TweetDetail de CETTE visite porte-t-il encore un curseur Bottom exploitable ?
    Un Bottom accompagne d'un TimelineTerminateTimeline(Bottom) est la fin reelle."""
    details = [p for p in payloads_of_visit if "TweetDetail" in p["op"]]
    if not details:
        return False
    body = details[-1]["body"]
    return has_bottom_cursor(body) and not has_bottom_terminate(body)


def page_done(payloads_of_visit, clicked_labels):
    """Page terminee : plus de curseur Bottom dans le dernier TweetDetail de la visite
    et plus aucun libelle de depliage non clique."""
    if bottom_pending(payloads_of_visit):
        return False
    labels = cursor_labels(p["body"] for p in payloads_of_visit)
    return not (labels - set(clicked_labels))


def _click_one(el, page):
    try:
        if el.is_visible():
            el.click(timeout=3000)
            page.wait_for_timeout(random.randint(400, 900))
            return 1
    except Exception:
        pass
    return 0


def _click_expanders(page, labels=(), clicked_labels=None):
    clicked = 0
    for b in page.get_by_role("button", name=EXPAND).all():
        clicked += _click_one(b, page)
    for label in labels:
        found = page.get_by_role("button", name=label, exact=True).all()
        if not found:
            found = page.get_by_text(label, exact=True).all()
        n = 0
        for b in found:
            n += _click_one(b, page)
        if n and clicked_labels is not None:
            clicked_labels.add(label)
        clicked += n
    return clicked


def _count(result):
    from x_parse import collect
    return len(collect(p["body"] for p in result["payloads"]))


def _visit(page, url, result, max_replies, log, quick=False):
    result["pages"].append(url)
    page.goto(url, wait_until="domcontentloaded", timeout=60000)
    try:
        page.wait_for_selector('article[data-testid="tweet"]', timeout=20000)
    except Exception:
        pass
    if _login_wall(page, result):
        result["login_required"] = True
        return
    if quick:  # mode rapide : premieres reponses seulement, ni defilement ni clic
        page.wait_for_timeout(3000)
        return
    start = len(result["payloads"])
    idle, last_payloads, total, clicked_labels = 0, -1, 0, set()
    for _ in range(MAX_ROUNDS):
        before = len(result["payloads"])
        visit = result["payloads"][start:]
        clicked = _click_expanders(page, cursor_labels(p["body"] for p in visit), clicked_labels)
        page.evaluate("window.scrollTo(0, document.body.scrollHeight)")
        page.mouse.wheel(0, 2500)
        page.wait_for_timeout(random.randint(800, 1600))
        if len(result["payloads"]) != last_payloads:
            last_payloads = len(result["payloads"])
            total = _count(result)
            log(f"  {total} tweets captures...")
        if total >= max_replies:
            result["capped"] = True
            return
        idle = idle + 1 if (len(result["payloads"]) == before and not clicked) else 0
        visit = result["payloads"][start:]
        if idle >= STUCK_ROUNDS and not page_done(visit, clicked_labels):
            if bottom_pending(visit):
                result["incomplete_pages"].append(url)
            return
        if idle >= IDLE_ROUNDS and not bottom_pending(visit):
            return


def _deep_pass(page, focal_id, result, max_replies, log, max_pages=MAX_DEEP_PAGES):
    from x_parse import build_thread, collect
    seen = {focal_id}
    for _ in range(max_pages):
        if result["capped"] or result["login_required"]:
            return
        tweets = collect(p["body"] for p in result["payloads"])
        th = build_thread(tweets, focal_id)
        todo = [tid for tid in tweets if tid in th["descendants"] and tid not in seen
                and (tweets[tid]["stats"]["replies"] or 0) > len(th["children"].get(tid, []))]
        if not todo:
            return
        if len(seen) > max_pages:
            result["pages_capped"] = True
            return
        seen.add(todo[0])
        log(f"  sous-fil {todo[0]}...")
        _visit(page, f"https://x.com/i/status/{todo[0]}", result, max_replies, log)


def capture(url, cookies, max_replies=2000, headed=False, log=print, max_pages=MAX_DEEP_PAGES,
            quick=False, deep=True, on_phase2=None, ranking=None):
    from playwright.sync_api import sync_playwright
    from x_parse import parse_status_url
    canon, focal_id, _ = parse_status_url(url)
    result = {"payloads": [], "login_required": False, "capped": False, "pages": [],
              "incomplete_pages": [], "pages_capped": False}

    def on_response(r):
        if GRAPHQL not in r.url:
            return
        try:
            body = r.json()
        except Exception:
            log(f"  reponse GraphQL illisible (HTTP {r.status}) : {_op(r.url)}")
            return
        result["payloads"].append({"op": _op(r.url), "status": r.status, "body": body})

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=not headed)
        try:
            ctx = browser.new_context(locale="en-US", user_agent=UA, viewport={"width": 1280, "height": 1800})
            ctx.add_cookies(cookies)
            page = ctx.new_page()
            page.on("response", on_response)
            mode = {"v": None}

            def route(r):
                u = r.request.url
                r.continue_(url=rewrite_ranking(u, mode["v"])) if mode["v"] and "TweetDetail" in u else r.continue_()
            page.route("**/i/api/graphql/**", route)
            for mode["v"] in ranking_passes(quick, ranking):
                n0 = len(result["payloads"])
                _visit(page, canon, result, max_replies, log, quick=quick)
                log(f"  passe {mode['v'] or 'Relevance'} : {len(result['payloads']) - n0} reponses GraphQL")
                if result["login_required"]:
                    break
            mode["v"] = None  # sous-fils : tri par defaut
            if quick or result["login_required"]:
                return result
            if on_phase2:
                on_phase2(result)
            if deep:
                _deep_pass(page, focal_id, result, max_replies, log, max_pages)
        finally:
            browser.close()
    return result
