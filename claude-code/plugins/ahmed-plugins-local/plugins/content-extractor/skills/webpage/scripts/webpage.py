#!/usr/bin/env python3
"""
webpage.py — Extraction COMPLÈTE d'une page web via un vrai navigateur Chromium
(Playwright), en préservant la mise en forme.

Pourquoi un script dédié : beaucoup de pages sont en JS / derrière un anti-bot, où
un simple fetch renvoie une coquille vide ou un 403. Un vrai Chromium rend la page
comme un humain. On isole ensuite le contenu principal (readability) et on le
convertit en markdown qui garde la structure : titres, **tableaux**, listes, gras,
liens. On capture aussi la page en entier (PNG) pour le layout visuel.

Sortie : <outdir>/<domaine>_<slug>/
  - page.md     markdown structuré (titres, tableaux, listes...) ; images en local
  - page.txt    texte brut du contenu principal
  - page.html   HTML du contenu principal (nettoyé)
  - page.png    capture PLEINE PAGE (layout visuel, lisible avec l'outil Read)
  - meta.json   titre, auteur, date, description, langue, URL, nb de mots/images
  - images/     images du contenu, téléchargées (référencées en relatif dans page.md)

Usage :
  python webpage.py "<url>" [--outdir DIR] [--no-images] [--no-screenshot]
                    [--full] [--headed]
    --full         convertir TOUTE la page (pas seulement le contenu readability).
    --no-images    ne pas télécharger les images.
    --no-screenshot ne pas faire la capture PNG.

Dépendances (auto-installées) : playwright (+ Chromium), readability-lxml,
markdownify, lxml.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import urllib.parse
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


def ensure_deps():
    need = []
    for mod, pip in [("playwright", "playwright"), ("readability", "readability-lxml"),
                     ("markdownify", "markdownify"), ("lxml", "lxml")]:
        try:
            __import__(mod)
        except ImportError:
            need.append(pip)
    if need:
        eprint(f"[deps] Installation de : {', '.join(need)}")
        subprocess.run([sys.executable, "-m", "pip", "install", "-U", "-q", *need], check=True)
    # Chromium présent ?
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


def slug(s, n=60):
    return (re.sub(r"[^0-9A-Za-z_-]+", "_", str(s or "")).strip("_") or "x")[:n]


def out_name(url):
    p = urllib.parse.urlparse(url)
    domain = p.netloc.replace("www.", "")
    path = slug(p.path.strip("/").replace("/", "_")) or "index"
    return f"{slug(domain)}_{path}"


def extract_meta(full_html):
    """Quelques métadonnées via regex tolérante (titre, auteur, date, description, lang)."""
    def meta(*names):
        for nm in names:
            m = re.search(
                r'<meta[^>]+(?:property|name)=["\']' + re.escape(nm) + r'["\'][^>]+content=["\']([^"\']+)["\']',
                full_html, re.I)
            if not m:
                m = re.search(
                    r'<meta[^>]+content=["\']([^"\']+)["\'][^>]+(?:property|name)=["\']' + re.escape(nm) + r'["\']',
                    full_html, re.I)
            if m:
                return m.group(1).strip()
        return None
    lang = None
    ml = re.search(r'<html[^>]+lang=["\']([^"\']+)["\']', full_html, re.I)
    if ml:
        lang = ml.group(1)
    return {
        "byline": meta("author", "article:author", "og:article:author"),
        "published": meta("article:published_time", "datePublished", "og:updated_time"),
        "description": meta("description", "og:description"),
        "site": meta("og:site_name"),
        "lang": lang,
    }


def main():
    ap = argparse.ArgumentParser(description="Extraction complète d'une page web (markdown + screenshot) via Playwright.")
    ap.add_argument("url")
    ap.add_argument("--outdir", default="webpage_extract")
    ap.add_argument("--no-images", action="store_true")
    ap.add_argument("--no-screenshot", action="store_true")
    ap.add_argument("--full", action="store_true", help="Convertir toute la page (pas seulement le contenu readability)")
    ap.add_argument("--headed", action="store_true")
    args = ap.parse_args()

    if not re.match(r"^https?://", args.url):
        args.url = "https://" + args.url

    ensure_deps()
    from playwright.sync_api import sync_playwright
    from readability import Document
    from markdownify import markdownify as to_md
    from lxml import html as lxml_html

    outdir = os.path.join(args.outdir, out_name(args.url))
    os.makedirs(outdir, exist_ok=True)

    eprint("[1/3] Ouverture de la page dans Chromium (rendu JS + anti-bot)...")
    with sync_playwright() as pw:
        browser = pw.chromium.launch(headless=not args.headed)
        ctx = browser.new_context(user_agent=UA, locale="en-US",
                                  viewport={"width": 1366, "height": 1000})
        page = ctx.new_page()
        page.goto(args.url, wait_until="domcontentloaded", timeout=60000)
        page.wait_for_timeout(1500)
        # Scroll progressif pour déclencher le lazy-loading (images, sections).
        try:
            page.evaluate("""async () => {
              await new Promise(res => {
                let y = 0; const step = () => {
                  window.scrollBy(0, 1200); y += 1200;
                  if (y < document.body.scrollHeight && y < 60000) setTimeout(step, 120);
                  else { window.scrollTo(0, 0); setTimeout(res, 300); }
                }; step();
              });
            }""")
        except Exception:
            pass
        page.wait_for_timeout(500)

        final_url = page.url
        page_title = page.title()
        full_html = page.content()

        if not args.no_screenshot:
            eprint("[2/3] Capture pleine page...")
            try:
                page.screenshot(path=os.path.join(outdir, "page.png"), full_page=True)
            except Exception as e:
                eprint(f"  (screenshot échoué : {type(e).__name__})")
        browser.close()

    eprint("[3/3] Extraction du contenu + conversion markdown...")
    # Contenu principal : readability, sinon repli sur tout le body.
    title = page_title
    try:
        doc = Document(full_html)
        main_html = doc.summary(html_partial=True)
        title = doc.short_title() or page_title
    except Exception:
        main_html = full_html
    # Repli "full" ou si readability a trop rogné.
    plain_len = len(re.sub(r"<[^>]+>", "", main_html or ""))
    if args.full or plain_len < 200:
        mb = re.search(r"<body[^>]*>(.*)</body>", full_html, re.I | re.S)
        main_html = mb.group(1) if mb else full_html

    # Réécrit les <img> vers des fichiers locaux (et les télécharge).
    images = []
    try:
        tree = lxml_html.fromstring(main_html)
        seen = {}
        for img in tree.xpath("//img"):
            src = img.get("src") or img.get("data-src") or ""
            if not src or src.startswith("data:"):
                continue
            absu = urllib.parse.urljoin(final_url, src)
            if absu not in seen:
                idx = len(seen)
                clean = absu.split("?")[0]
                ext = os.path.splitext(clean)[1]
                ext = ext if re.match(r"^\.[A-Za-z0-9]{2,5}$", ext) else ".jpg"
                local = f"images/img_{idx:02d}_{slug(os.path.basename(clean), 30)}{ext}"
                seen[absu] = local
                images.append((absu, local))
            img.set("src", seen[absu])
            for a in ("data-src", "srcset", "data-srcset"):
                if img.get(a):
                    del img.attrib[a]
        main_html = lxml_html.tostring(tree, encoding="unicode")
    except Exception as e:
        eprint(f"  (réécriture images ignorée : {type(e).__name__})")

    if not args.no_images and images:
        imgdir = os.path.join(outdir, "images")
        os.makedirs(imgdir, exist_ok=True)
        ok = 0
        for absu, local in images:
            try:
                req = urllib.request.Request(absu, headers={"User-Agent": UA, "Referer": final_url})
                with urllib.request.urlopen(req, timeout=25) as r:
                    open(os.path.join(outdir, local), "wb").write(r.read())
                ok += 1
            except Exception:
                pass
        eprint(f"  images téléchargées : {ok}/{len(images)}")

    # Markdown (préserve titres / tableaux / listes / gras / liens).
    body_md = to_md(main_html, heading_style="ATX", bullets="-", strip=["script", "style"])
    body_md = re.sub(r"\n{3,}", "\n\n", body_md).strip()
    plain = re.sub(r"<[^>]+>", "", main_html)
    plain = re.sub(r"\s+\n", "\n", re.sub(r"[ \t]+", " ", plain)).strip()

    meta = extract_meta(full_html)
    meta_out = {
        "title": title, "url": final_url, "byline": meta["byline"],
        "published": meta["published"], "description": meta["description"],
        "site": meta["site"], "lang": meta["lang"],
        "word_count": len(plain.split()), "image_count": len(images),
    }

    with open(os.path.join(outdir, "page.md"), "w", encoding="utf-8") as f:
        f.write(f"# {title}\n\n")
        if meta["byline"] or meta["published"]:
            f.write(f"> {meta['byline'] or ''}{'  ·  ' if meta['byline'] and meta['published'] else ''}{meta['published'] or ''}\n")
        f.write(f"> source : {final_url}\n\n")
        f.write(body_md + "\n")
    with open(os.path.join(outdir, "page.txt"), "w", encoding="utf-8") as f:
        f.write(plain + "\n")
    with open(os.path.join(outdir, "page.html"), "w", encoding="utf-8") as f:
        f.write(main_html)
    with open(os.path.join(outdir, "meta.json"), "w", encoding="utf-8") as f:
        json.dump(meta_out, f, ensure_ascii=False, indent=2)

    # Résumé
    print("\n=== Page web extraite ===")
    print(f"Titre   : {title}")
    if meta["byline"] or meta["published"]:
        print(f"Source  : {meta['byline'] or '?'}  ·  {meta['published'] or '?'}")
    print(f"URL     : {final_url}")
    print(f"Contenu : {meta_out['word_count']} mots, {meta_out['image_count']} images")
    png = os.path.join(outdir, "page.png")
    if os.path.exists(png):
        print(f"Capture pleine page -> ouvre-la avec Read : {os.path.abspath(png)}")
    print(f"Dossier : {os.path.abspath(outdir)}")
    print("Fichiers : page.md, page.txt, page.html, meta.json"
          + (", page.png" if os.path.exists(png) else "")
          + (", images/" if (not args.no_images and images) else ""))


if __name__ == "__main__":
    main()
