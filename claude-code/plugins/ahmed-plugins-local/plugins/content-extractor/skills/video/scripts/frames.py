#!/usr/bin/env python3
"""
frames.py — Télécharge une vidéo (TOUTE URL supportée par yt-dlp : TikTok,
Instagram, X/Twitter, Twitch, Vimeo...) et en extrait des images (frames) à lire
visuellement avec l'outil Read. À utiliser quand la vidéo n'a PAS de sous-titres
mais qu'une info utile est affichée à l'écran (stats, tableau, UI, écran de
résultats...).

Modes (cumulables) : scènes (changements de plan, capte les écrans statiques)
+ interval (1 frame toutes les N s, filet de sécurité). Frames écrites dans
<outdir>/<extractor>_<id>/frames/ ; chemins Windows absolus imprimés.

Usage :
  python frames.py "<url>" [--outdir DIR] [--scene-threshold 0.25] [--interval 3]
                   [--no-scene] [--quality 720] [--start MM:SS] [--end MM:SS]
                   [--cookies-from-browser BROWSER] [--cookies FILE]

Dépendances : yt-dlp (auto-installé) + ffmpeg (PATH ou install winget Gyan.FFmpeg).
"""
import argparse
import glob
import os
import re
import shutil
import subprocess
import sys

os.environ.setdefault("PYTHONIOENCODING", "utf-8")
try:
    sys.stdout.reconfigure(encoding="utf-8")
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


def find_ffmpeg():
    """Localise ffmpeg : PATH d'abord, puis l'install winget (Gyan.FFmpeg)."""
    exe = shutil.which("ffmpeg")
    if exe:
        return exe
    base = os.path.join(os.environ.get("LOCALAPPDATA", ""), "Microsoft", "WinGet", "Packages")
    hits = glob.glob(os.path.join(base, "Gyan.FFmpeg*", "**", "ffmpeg.exe"), recursive=True)
    if hits:
        return hits[0]
    raise SystemExit(
        "ffmpeg introuvable. Installe-le :\n"
        "  winget install --id Gyan.FFmpeg -e --accept-package-agreements --accept-source-agreements\n"
        "puis relance (ce script cherche aussi dans l'install winget)."
    )


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
    if isinstance(info, dict) and info.get("_type") == "playlist" and info.get("entries"):
        return next((e for e in info["entries"] if e), info)
    return info


def probe_name(url, args):
    import yt_dlp
    opts = {"quiet": True, "no_warnings": True, "ignoreerrors": True, "skip_download": True}
    opts.update(cookie_opts(args))
    with yt_dlp.YoutubeDL(opts) as ydl:
        info = first_entry(ydl.extract_info(url, download=False))
    if not info:
        raise SystemExit(f"yt-dlp n'a rien pu extraire de : {url!r}")
    return f"{slug(info.get('extractor_key') or info.get('extractor'))}_{slug(info.get('id'))}"


def download(url, outdir, quality, args):
    import yt_dlp
    target = os.path.join(outdir, "video.%(ext)s")
    fmt = f"best[height<={quality}][ext=mp4]/best[height<={quality}]/best[ext=mp4]/best"
    opts = {"outtmpl": target, "format": fmt, "quiet": True, "no_warnings": True, "ignoreerrors": True}
    opts.update(cookie_opts(args))
    with yt_dlp.YoutubeDL(opts) as ydl:
        info = first_entry(ydl.extract_info(url, download=True))
        try:
            path = ydl.prepare_filename(info)
        except Exception:
            path = None
    if not (path and os.path.exists(path)):
        cands = glob.glob(os.path.join(outdir, "video.*"))
        path = cands[0] if cands else path
    if not (path and os.path.exists(path)):
        raise SystemExit(f"Échec du téléchargement de : {url!r} (contenu privé ? essaie --cookies-from-browser firefox)")
    return path


def main():
    ap = argparse.ArgumentParser(description="Extrait des frames d'une vidéo (toute URL yt-dlp) pour lecture visuelle.")
    ap.add_argument("url")
    ap.add_argument("--outdir", default="frames_extract")
    ap.add_argument("--scene-threshold", type=float, default=0.25,
                    help="Sensibilité détection de scène 0-1 (plus bas = plus de frames). Défaut 0.25")
    ap.add_argument("--interval", type=float, default=3.0, help="Frame toutes les N secondes (défaut 3)")
    ap.add_argument("--no-scene", action="store_true", help="Désactiver la détection de scène")
    ap.add_argument("--quality", type=int, default=720, help="Hauteur max de la vidéo téléchargée (défaut 720)")
    ap.add_argument("--width", type=int, default=960, help="Largeur des frames extraites (défaut 960)")
    ap.add_argument("--start", default=None, help="Début (MM:SS ou secondes)")
    ap.add_argument("--end", default=None, help="Fin (MM:SS ou secondes)")
    ap.add_argument("--cookies-from-browser", default=None)
    ap.add_argument("--cookies", default=None)
    args = ap.parse_args()

    ensure_ytdlp()
    ff = find_ffmpeg()
    name = probe_name(args.url, args)
    outdir = os.path.join(args.outdir, name)
    framedir = os.path.join(outdir, "frames")
    os.makedirs(framedir, exist_ok=True)
    for old in glob.glob(os.path.join(framedir, "*.jpg")):
        os.remove(old)

    eprint("[1/2] Téléchargement de la vidéo...")
    video_path = download(args.url, outdir, args.quality, args)

    trim = []
    if args.start:
        trim += ["-ss", args.start]
    if args.end:
        trim += ["-to", args.end]

    eprint("[2/2] Extraction des frames...")
    if not args.no_scene:
        # eq(n,0) garantit au moins la 1re frame : sinon ffmpeg sort
        # « received no packets » sur un segment statique. check=False : l'interval reste un filet.
        subprocess.run(
            [ff, "-hide_banner", "-loglevel", "error", *trim, "-i", video_path,
             "-vf", f"select='eq(n\\,0)+gt(scene,{args.scene_threshold})',scale={args.width}:-1",
             "-vsync", "vfr", "-q:v", "3", os.path.join(framedir, "scene_%03d.jpg")],
            check=False,
        )
    if args.interval and args.interval > 0:
        subprocess.run(
            [ff, "-hide_banner", "-loglevel", "error", *trim, "-i", video_path,
             "-vf", f"fps=1/{args.interval},scale={args.width}:-1",
             "-q:v", "3", os.path.join(framedir, "t_%03d.jpg")],
            check=False,
        )

    frames = sorted(glob.glob(os.path.join(framedir, "*.jpg")))
    print(f"\n=== {len(frames)} frames extraites dans : {os.path.abspath(framedir)} ===")
    print("Ouvre-les avec l'outil Read pour lire ce qui est affiché à l'écran :")
    for f in frames:
        print(" ", os.path.abspath(f))
    print("\nAstuce : les écrans statiques (menus, écrans de résultats) sortent surtout dans les scene_*.jpg.")


if __name__ == "__main__":
    main()
