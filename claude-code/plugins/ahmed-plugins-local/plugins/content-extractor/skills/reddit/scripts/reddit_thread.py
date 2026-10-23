#!/usr/bin/env python3
"""
reddit_thread.py — Récupère un thread Reddit COMPLET (post + images + TOUS les
commentaires, réponses incluses) et les écrit dans des fichiers json/txt.

Architecture (pourquoi c'est complet ET sans auth) :
  1. Playwright ouvre le thread dans un vrai Chromium -> Reddit sert un défi
     anti-bot que le navigateur résout automatiquement. AUCUNE auth/cookie/OAuth.
  2. L'API JSON anonyme (/comments/<id>.json, morechildren) est FERMÉE par Reddit
     (403, constaté le 2026-10-16). On lit donc les PARTIELS HTML shreddit depuis
     la page (same-origin) : /svc/shreddit/comments/... puis on déplie en BFS tous
     les faceplate-partial[method=post] (more-comments : réponses masquées et
     commentaires de premier niveau suivants), dédup par thingid, plafond
     --max-more-requests sur le nombre de POST, partiels non dépliés signalés.

Sortie : <outdir>/reddit_<id>/ avec
  - post.json / post.txt        (titre, auteur, sub, score, type, selftext, images)
  - comments.json / comments.txt (TOUS les commentaires : author, score, depth, body)
  - images/                      (images du post téléchargées, lisibles avec Read)

Usage :
  python reddit_thread.py "<url_thread>" [--outdir DIR]
                          [--max-more-requests N] [--no-images] [--headed]
"""
import argparse
import json
import os
import re
import subprocess
import sys
import urllib.request

os.environ.setdefault("PYTHONIOENCODING", "utf-8")
try:
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
except Exception:
    pass

UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36")


def eprint(*a, **k):
    print(*a, file=sys.stderr, **k)


def ensure_playwright():
    try:
        import playwright  # noqa: F401
    except ImportError:
        eprint("[deps] Installation de playwright...")
        subprocess.run([sys.executable, "-m", "pip", "install", "-U", "-q", "playwright"], check=True)
    from playwright.sync_api import sync_playwright
    try:
        with sync_playwright() as p:
            b = p.chromium.launch(headless=True)
            b.close()
            return
    except Exception:
        pass
    eprint("[deps] Installation du navigateur Chromium pour Playwright...")
    subprocess.run([sys.executable, "-m", "playwright", "install", "chromium"], check=True)


def parse_url(url):
    u = url.strip()
    if "redd.it" in u and "/comments/" not in u:
        try:
            with urllib.request.urlopen(urllib.request.Request(u, headers={"User-Agent": UA}), timeout=20) as r:
                u = r.url
        except Exception:
            pass
    u = u.split("?")[0].rstrip("/")
    m = re.search(r"/comments/([0-9a-z]+)", u, re.I)
    if not m:
        raise SystemExit(f"URL Reddit sans id de thread (attendu .../comments/<id>/...) : {url!r}")
    canon = re.sub(r"https?://(old\.|new\.|np\.|www\.)?reddit\.com", "https://www.reddit.com", u)
    return m.group(1), canon


# JS exécuté DANS la page (défi déjà résolu, same-origin). L'API JSON anonyme est
# fermée (403) : on lit les PARTIELS HTML shreddit et on déplie les
# faceplate-partial[method=post] (more-comments) en BFS.
FETCH_ALL_JS = r"""
async ({ id, sub, maxPosts }) => {
  const sleep = (ms) => new Promise(r => setTimeout(r, ms));
  const parse = (h) => new DOMParser().parseFromString(h, 'text/html');
  const csrf = (document.cookie.match(/(?:^|;\s*)csrf_token=([^;]+)/) || [])[1] || '';
  const A = (el, n) => el.getAttribute(n);

  // ---- Post (DOM de la page chargée) ----
  const sp = document.querySelector('shreddit-post');
  const body = sp.querySelector('[slot="text-body"]');
  const paras = (el) => {
    const ps = [...el.querySelectorAll('p')].map(p => p.textContent.replace(/[ \t\r\n]+/g, ' ').trim()).filter(Boolean);
    return ps.length ? ps.join('\n\n') : el.textContent.replace(/[ \t]+/g, ' ').replace(/\n\s*\n+/g, '\n\n').trim();
  };
  const imgs = [];
  const addImg = (u) => { if (u && !imgs.includes(u)) imgs.push(u); };
  const href = A(sp, 'content-href') || '';
  if (/^https?:\/\/i\.redd\.it\//.test(href)) addImg(href);
  const mediaKey = (u) => { const f = u.split('?')[0].split('/').pop(); return f.replace(/\.[a-z0-9]+$/i, '').split('-v0-').pop(); };
  const seenKeys = new Set(imgs.map(mediaKey));
  const scope = sp.querySelector('gallery-carousel') || (A(sp, 'post-type') === 'image' ? sp : null);
  if (scope) {
    for (const im of scope.querySelectorAll('img')) {
      const cands = [im.getAttribute('src'), im.getAttribute('data-lazy-src')];
      for (const s of (im.getAttribute('srcset') || '').split(',')) cands.push(s.trim().split(' ')[0]);
      const real = cands.filter(u => u && /redd\.it\//.test(u)).map(u => u.replace(/&amp;/g, '&'));
      if (!real.length) continue;
      const k = mediaKey(real[0]);
      if (seenKeys.has(k)) continue;
      let best = real.find(u => /^https?:\/\/i\.redd\.it\//.test(u));
      if (!best) {                                   // preview.redd.it -> i.redd.it/<id>.<ext>
        const f = real[0].split('?')[0].split('/').pop();
        const ext = (f.match(/\.[a-z0-9]+$/i) || ['.jpg'])[0];
        best = 'https://i.redd.it/' + k + ext;
      }
      seenKeys.add(k); addImg(best);
    }
  }
  const post = {
    id, title: A(sp, 'post-title'), author: A(sp, 'author'),
    subreddit: A(sp, 'subreddit-prefixed-name'), score: +A(sp, 'score'),
    upvote_ratio: +A(sp, 'upvote-ratio') || null, num_comments: +A(sp, 'comment-count'),
    created: A(sp, 'created-timestamp'), permalink: 'https://www.reddit.com' + (A(sp, 'permalink') || ''),
    url: href, post_type: A(sp, 'post-type'), is_video: A(sp, 'post-type') === 'video',
    is_gallery: A(sp, 'post-type') === 'gallery',
    selftext: body ? paras(body) : '',
  };

  // ---- Commentaires ----
  const nodes = new Map();      // thingid -> {rec, children[]}
  const roots = [];
  const queue = [];             // {src, inputs, anchor}
  const queued = new Set();
  const failed = [];
  let posts = 0, dupes = 0;

  const ingest = (doc, anchor) => {
    const els = [...doc.querySelectorAll('shreddit-comment')];
    const stack = [];
    for (const el of els) {
      const tid = A(el, 'thingid'); const depth = +(A(el, 'depth') || 0);
      while (stack.length && stack[stack.length - 1].depth >= depth) stack.pop();
      if (!tid || nodes.has(tid)) { if (tid) dupes++; stack.push({ depth, tid }); continue; }
      let parent = stack.length ? stack[stack.length - 1].tid : null;
      if (!parent && anchor) {                  // remonte de l'ancre jusqu'à un ancêtre plus haut
        let t = anchor.tid;
        while (t && nodes.has(t) && nodes.get(t).rec.depth >= depth) t = nodes.get(t).rec.parent_id;
        parent = t || null;
      }
      // Le texte doit appartenir à CE commentaire : un commentaire supprimé n'a pas de
      // [slot=comment] propre, et un querySelector simple renverrait celui de sa première réponse.
      const slot = [...el.querySelectorAll('[slot="comment"]')].find(s => s.closest('shreddit-comment') === el) || null;
      const rec = { id: tid.replace(/^t1_/, ''), author: A(el, 'author'), score: A(el, 'score') === null ? null : +A(el, 'score'),
        depth, body: slot ? paras(slot) : '', is_submitter: A(el, 'author') === post.author,
        parent_id: parent, created: A(el, 'created'), permalink: A(el, 'permalink') };
      const node = { rec, children: [] };
      nodes.set(tid, node);
      const holder = parent && nodes.get(parent);
      (holder ? holder.children : roots).push(node);
      stack.push({ depth, tid });
    }
    for (const fp of doc.querySelectorAll('faceplate-partial[method="post"]')) {
      const s = A(fp, 'src') || '';
      if (!s || s.includes('user-hover-card')) continue;
      const inputs = [...fp.querySelectorAll('input')].map(i => [i.getAttribute('name'), i.getAttribute('value') || '']).filter(x => x[0]);
      const key = s + '|' + inputs.map(x => x.join('=')).join('&');
      if (queued.has(key)) continue;
      queued.add(key);
      const host = fp.closest('shreddit-comment');
      let a = null;
      if (host) a = { tid: A(host, 'thingid'), depth: +(A(host, 'depth') || 0) };
      else {                                    // dernier commentaire AVANT le partial
        for (const el of els) {
          if (el.compareDocumentPosition(fp) & Node.DOCUMENT_POSITION_FOLLOWING) a = { tid: A(el, 'thingid'), depth: +(A(el, 'depth') || 0) };
        }
        if (/top-level=1/.test(s)) a = null;    // premier niveau suivant : racine
      }
      const item = { src: s, inputs, anchor: a };
      if (/top-level=1/.test(s)) queue.unshift(item); else queue.push(item);   // largeur d'abord
    }
  };

  const r0 = await fetch(`/svc/shreddit/comments/r/${sub}/t3_${id}?render-mode=partial`);
  if (!r0.ok) return { error: 'comments_partial_status_' + r0.status };
  ingest(document, null);                       // commentaires déjà rendus dans la page
  ingest(parse(await r0.text()), null);         // + partiel serveur (dédupliqué)

  // BFS sur les partiels, plafond sur le nombre de POST
  while (queue.length) {
    if (posts >= maxPosts) break;
    const it = queue.shift();
    posts++;
    const form = new URLSearchParams(it.inputs);
    form.set('csrf_token', csrf);
    let html = null, status = 0;
    for (let attempt = 0; attempt < 4 && html === null; attempt++) {
      try {
        const r = await fetch(it.src, { method: 'POST', body: form,
          headers: { 'Content-Type': 'application/x-www-form-urlencoded' } });
        status = r.status;
        if (r.ok) html = await r.text(); else await sleep(1000 * Math.pow(2, attempt));
      } catch (e) { status = -1; await sleep(1000 * Math.pow(2, attempt)); }
    }
    if (html === null) failed.push({ src: it.src, status });
    else ingest(parse(html), it.anchor);
    await sleep(200);
  }
  const unexpanded = queue.map(q => q.src);

  // ---- Ordre arborescent (DFS) ----
  const comments = [];
  const walk = (list) => { for (const n of list) { comments.push(n.rec); walk(n.children); } };
  walk(roots);

  return { post, images: imgs, comments,
    stats: { fetched: comments.length, announced: post.num_comments, post_requests: posts,
             duplicates: dupes, unexpanded: unexpanded.length, failed: failed.length,
             unexpanded_samples: unexpanded.slice(0, 3), failed_samples: failed.slice(0, 3) } };
}
"""


def slug(s, n=60):
    return (re.sub(r"[^0-9A-Za-z_-]+", "_", str(s or "")).strip("_") or "img")[:n]


def main():
    ap = argparse.ArgumentParser(
        description="Récupère un thread Reddit COMPLET (post + images + tous les commentaires) via Playwright + partiels shreddit.")
    ap.add_argument("url")
    ap.add_argument("--outdir", default="reddit_extract")
    ap.add_argument("--max-more-requests", type=int, default=300,
                    help="Plafond de requêtes POST more-comments (défaut 300). "
                         "Très haut par défaut pour tout récupérer ; le reste éventuel est signalé.")
    ap.add_argument("--no-images", action="store_true", help="Ne pas télécharger les images")
    ap.add_argument("--headed", action="store_true", help="Afficher la fenêtre du navigateur (debug)")
    args = ap.parse_args()

    post_id, canon = parse_url(args.url)
    msub = re.search(r"/r/([^/]+)/comments/", canon)
    ensure_playwright()
    from playwright.sync_api import sync_playwright

    eprint("[1/3] Ouverture du thread dans Chromium (résolution du défi anti-bot)...")
    with sync_playwright() as pw:
        browser = pw.chromium.launch(headless=not args.headed)
        ctx = browser.new_context(user_agent=UA, locale="en-US",
                                  viewport={"width": 1280, "height": 1000})
        page = ctx.new_page()
        page.goto(canon, wait_until="domcontentloaded", timeout=60000)
        try:
            page.wait_for_selector("shreddit-post", timeout=30000)
        except Exception:
            raise SystemExit("Le post ne s'est pas chargé (thread supprimé/privé, ou défi non résolu).")

        sub = msub.group(1) if msub else page.evaluate(
            "() => document.querySelector('shreddit-post').getAttribute('subreddit-name') || ''")
        eprint("[2/3] Lecture des partiels shreddit + dépliage de TOUS les commentaires (more-comments)...")
        data = page.evaluate(FETCH_ALL_JS, {"id": post_id, "sub": sub, "maxPosts": args.max_more_requests})
        browser.close()

    if not data or data.get("error"):
        raise SystemExit(f"Échec récupération des partiels shreddit : {data.get('error') if data else 'réponse vide'} "
                         "(thread supprimé/privé, ou défi non résolu).")

    post = data["post"]
    comments = data["comments"]
    images = data.get("images", [])
    stats = data.get("stats", {})

    outdir = os.path.join(args.outdir, f"reddit_{post_id}")
    os.makedirs(outdir, exist_ok=True)

    # --- Images ---
    eprint("[3/3] Écriture des fichiers" + ("" if args.no_images else " + téléchargement des images") + "...")
    saved_images = []
    if not args.no_images and images:
        imgdir = os.path.join(outdir, "images")
        os.makedirs(imgdir, exist_ok=True)
        for idx, u in enumerate(images):
            try:
                clean = u.split("?")[0]
                ext = os.path.splitext(clean)[1] or ".jpg"
                dest = os.path.join(imgdir, f"img_{idx:02d}_{slug(os.path.basename(clean))}")
                if not dest.endswith(ext):
                    dest += ext
                req = urllib.request.Request(u, headers={"User-Agent": UA})
                with urllib.request.urlopen(req, timeout=30) as r:
                    open(dest, "wb").write(r.read())
                saved_images.append(dest)
            except Exception as e:
                eprint(f"  (image non téléchargée : {u} -> {type(e).__name__})")

    # --- post.json / post.txt ---
    post_out = dict(post)
    post_out["images"] = images
    with open(os.path.join(outdir, "post.json"), "w", encoding="utf-8") as f:
        json.dump(post_out, f, ensure_ascii=False, indent=2)
    with open(os.path.join(outdir, "post.txt"), "w", encoding="utf-8") as f:
        f.write(f"# {post['title']}\n")
        f.write(f"{post['subreddit']}  -  u/{post['author']}  -  score {post['score']} "
                f"({post['num_comments']} commentaires)\n")
        f.write(f"{post['permalink']}\n\n")
        if post.get("selftext"):
            f.write(post["selftext"] + "\n")
        if post.get("url"):
            f.write(f"\n[contenu] {post['url']}\n")

    # --- comments.json / comments.txt ---
    with open(os.path.join(outdir, "comments.json"), "w", encoding="utf-8") as f:
        json.dump(comments, f, ensure_ascii=False, indent=2)
    with open(os.path.join(outdir, "comments.txt"), "w", encoding="utf-8") as f:
        for c in comments:
            indent = "  " * int(c.get("depth") or 0)
            op = " [OP]" if c.get("is_submitter") else ""
            score = f" (+{c['score']})" if c.get("score") is not None else ""
            body = (c.get("body") or "").replace("\n", "\n" + indent + "  ")
            f.write(f"{indent}[u/{c.get('author')}{op}]{score} {body}\n")

    # --- Résumé ---
    print("\n=== Thread Reddit récupéré (Playwright + partiels shreddit) ===")
    print(f"Titre   : {post['title']}")
    print(f"Sub     : {post['subreddit']}   Auteur : u/{post['author']}   Score : {post['score']}")
    fetched = stats.get("fetched", len(comments))
    announced = stats.get("announced")
    print(f"Commentaires récupérés : {fetched}" + (f" / {announced} annoncés" if announced is not None else "")
          + f"   (en {stats.get('post_requests', 0)} requêtes POST more-comments)")
    if stats.get("unexpanded"):
        print(f"ATTENTION : {stats['unexpanded']} partiels NON dépliés "
              f"(plafond --max-more-requests={args.max_more_requests} atteint ; relance avec une valeur plus haute).")
    if stats.get("failed"):
        print(f"ATTENTION : {stats['failed']} partiels en échec après 4 essais (ex. {stats.get('failed_samples')}).")
    if saved_images:
        print(f"Images téléchargées ({len(saved_images)}) -> ouvre-les avec l'outil Read :")
        for p in saved_images:
            print("  ", os.path.abspath(p))
    if post.get("is_video"):
        print(f"Post VIDÉO -> télécharge le média avec le skill `video` (media.py) sur {post['permalink']}")
    print(f"Dossier : {os.path.abspath(outdir)}")
    print("Fichiers : post.txt, post.json, comments.txt, comments.json"
          + (", images/" if saved_images else ""))


if __name__ == "__main__":
    main()
