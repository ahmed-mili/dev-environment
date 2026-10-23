#!/usr/bin/env python3
"""
media.py — Extraction générique via yt-dlp pour TOUTE URL de contenu supportée
(TikTok, Instagram, X/Twitter, Twitch, Vimeo, Facebook... +1800 sites) :
  - métadonnées (titre, auteur, date, vues, likes, durée, tags)
  - description
  - commentaires (quand la plateforme les expose à yt-dlp)
  - téléchargement optionnel du média (--download)

yt-dlp auto-détecte la plateforme depuis l'URL : le même script sert toutes les
plateformes vidéo. Pas de transcription ici (spécifique YouTube -> skill youtube ;
texte Reddit -> skill reddit). Quand il n'y a pas de sous-titres et que l'info est
À L'ÉCRAN, enchaîne avec frames.py.

Sortie : <outdir>/<extractor>_<id>/ avec metadata.json, description.txt,
comments.json/.txt (si dispo), et media.* si --download.

Usage :
  python media.py "<url>" [--outdir DIR] [--no-comments] [--download]
                  [--cookies-from-browser BROWSER] [--cookies FILE]
"""
import argparse
import glob
import json
import os
import re
import shutil
import subprocess
import sys

# --- UTF-8 partout : sur Windows la console est en cp1252 et plante sur accents/emojis. ---
os.environ.setdefault("PYTHONIOENCODING", "utf-8")
try:
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
except Exception:
    pass


def eprint(*a, **k):
    print(*a, file=sys.stderr, **k)


def ensure_ytdlp():
    try:
        import yt_dlp  # noqa: F401
    except ImportError:
        eprint("[deps] Installation de yt-dlp...")
        subprocess.run([sys.executable, "-m", "pip", "install", "-U", "-q", "yt-dlp"], check=True)


def slug(s, n=80):
    out = re.sub(r"[^0-9A-Za-z_-]+", "_", str(s or "")).strip("_")
    return out[:n] or "item"


def cookie_opts(args):
    """Options communes à chaque appel yt-dlp : cookies et moteur JavaScript."""
    o = {}
    if args.cookies_from_browser:
        o["cookiesfrombrowser"] = (args.cookies_from_browser,)
    if args.cookies:
        o["cookiefile"] = args.cookies
    # Sans chemin explicite, yt-dlp cherche un moteur JS dans tout le PATH et plante (WinError 448)
    # sur un dossier qu'il ne peut pas traverser, ex. ...\OpenAI\Codex\bin en session SSH (2026-10-16).
    node = shutil.which("node")
    if node:
        o["js_runtimes"] = {"node": {"path": node}}
    return o


def first_entry(info):
    """Si yt-dlp renvoie une playlist, prend la 1re entrée non vide."""
    if isinstance(info, dict) and info.get("_type") == "playlist" and info.get("entries"):
        for e in info["entries"]:
            if e:
                return e
    return info


def main():
    ap = argparse.ArgumentParser(
        description="Extraction générique yt-dlp (métadonnées + commentaires + média) pour toute URL.")
    ap.add_argument("url", help="URL de la vidéo/post (TikTok, Instagram, X, Twitch, Vimeo... toute URL yt-dlp)")
    ap.add_argument("--outdir", default="media_extract", help="Dossier de sortie (défaut: ./media_extract)")
    ap.add_argument("--no-comments", action="store_true", help="Ne pas récupérer les commentaires (plus rapide)")
    ap.add_argument("--download", action="store_true", help="Télécharger le média (sinon métadonnées seules)")
    ap.add_argument("--cookies-from-browser", default=None,
                    help="Navigateur source des cookies (firefox, chrome, edge...) pour le contenu privé/auth (Instagram, X)")
    ap.add_argument("--cookies", default=None,
                    help="Fichier cookies.txt (format Netscape), alternative à --cookies-from-browser")
    args = ap.parse_args()

    ensure_ytdlp()
    import yt_dlp

    want_comments = not args.no_comments

    # --- Passe 1 : métadonnées (+ commentaires), sans télécharger ---
    eprint("[1/" + ("2" if args.download else "1") + "] Métadonnées"
           + (" + commentaires" if want_comments else "") + "...")
    opts = {"quiet": True, "no_warnings": True, "ignoreerrors": True, "skip_download": True}
    if want_comments:
        opts["getcomments"] = True
    opts.update(cookie_opts(args))
    with yt_dlp.YoutubeDL(opts) as ydl:
        info = first_entry(ydl.extract_info(args.url, download=False))
    if not info:
        raise SystemExit(
            f"yt-dlp n'a rien pu extraire de : {args.url!r}\n"
            "Causes possibles : URL invalide, contenu privé (essaie --cookies-from-browser firefox), "
            "ou plateforme non supportée."
        )

    name = f"{slug(info.get('extractor_key') or info.get('extractor'))}_{slug(info.get('id'))}"
    outdir = os.path.join(args.outdir, name)
    os.makedirs(outdir, exist_ok=True)

    meta = {
        "id": info.get("id"),
        "extractor": info.get("extractor_key") or info.get("extractor"),
        "title": info.get("title"),
        "uploader": info.get("uploader") or info.get("channel") or info.get("creator"),
        "uploader_id": info.get("uploader_id") or info.get("channel_id"),
        "upload_date": info.get("upload_date"),
        "duration_string": info.get("duration_string"),
        "view_count": info.get("view_count"),
        "like_count": info.get("like_count"),
        "repost_count": info.get("repost_count"),
        "comment_count": info.get("comment_count"),
        "tags": info.get("tags") or info.get("categories"),
        "webpage_url": info.get("webpage_url") or args.url,
    }
    with open(os.path.join(outdir, "metadata.json"), "w", encoding="utf-8") as f:
        json.dump(meta, f, ensure_ascii=False, indent=2)
    with open(os.path.join(outdir, "description.txt"), "w", encoding="utf-8") as f:
        f.write((info.get("description") or "") + "\n")

    comments = info.get("comments") or []
    if want_comments:
        norm = [{
            "author": c.get("author"),
            "text": c.get("text", ""),
            "like_count": c.get("like_count"),
            "is_reply": bool(c.get("parent") and c.get("parent") != "root"),
            "timestamp": c.get("timestamp"),
            "id": c.get("id"),
            "parent": c.get("parent"),
        } for c in comments]
        with open(os.path.join(outdir, "comments.json"), "w", encoding="utf-8") as f:
            json.dump(norm, f, ensure_ascii=False, indent=2)
        with open(os.path.join(outdir, "comments.txt"), "w", encoding="utf-8") as f:
            for c in norm:
                indent = "    " if c["is_reply"] else ""
                likes = f" (+{c['like_count']})" if c["like_count"] else ""
                f.write(f"{indent}[{c['author']}]{likes} {c['text'].replace(chr(10), ' ').strip()}\n")

    # --- Passe 2 : téléchargement du média (optionnel) ---
    media_path = None
    if args.download:
        eprint("[2/2] Téléchargement du média...")
        dopts = {
            "quiet": True, "no_warnings": True, "ignoreerrors": True,
            "outtmpl": os.path.join(outdir, "media.%(ext)s"),
            "format": "best[ext=mp4]/best",
        }
        dopts.update(cookie_opts(args))
        with yt_dlp.YoutubeDL(dopts) as ydl:
            dinfo = first_entry(ydl.extract_info(args.url, download=True))
            try:
                media_path = ydl.prepare_filename(dinfo)
            except Exception:
                media_path = None
        if not (media_path and os.path.exists(media_path)):
            cands = glob.glob(os.path.join(outdir, "media.*"))
            media_path = cands[0] if cands else None

    has_subs = bool(info.get("subtitles") or info.get("automatic_captions"))
    print("\n=== Extraction terminée ===")
    print(f"Plateforme : {meta['extractor']}")
    print(f"Titre      : {meta['title']}  -  {meta['uploader']}")
    print(f"URL        : {meta['webpage_url']}")
    print(f"Vues : {meta['view_count']}   Likes : {meta['like_count']}   Durée : {meta['duration_string']}")
    print(f"Sous-titres exposés : {'oui' if has_subs else 'NON -> si l info est a l ecran, enchaine avec frames.py'}")
    print(f"Commentaires : {'(ignorés)' if not want_comments else len(comments)}")
    if args.download:
        print(f"Média      : {os.path.abspath(media_path) if media_path else 'ECHEC du téléchargement'}")
    print(f"Dossier    : {os.path.abspath(outdir)}")


if __name__ == "__main__":
    main()
