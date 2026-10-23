#!/usr/bin/env python3
"""
yt_frames.py — Télécharge une vidéo YouTube et en extrait des images (frames) à
lire visuellement. À utiliser quand une vidéo n'a PAS de sous-titres mais qu'une
info utile est affichée à l'écran (écran de récompenses, tableau, stats, UI d'un
jeu/logiciel, etc.).

Deux modes d'extraction (cumulables) :
  - scènes  : frames aux changements de plan (détection auto) — capte les écrans
              statiques (menus, écrans de résultats) sans en rater.
  - interval: 1 frame toutes les N secondes — filet de sécurité régulier.

Les frames sont écrites dans <outdir>/<video_id>/frames/. Le script imprime le
chemin Windows ABSOLU de chaque frame pour que tu puisses les ouvrir avec l'outil
Read (qui lit les images) et y lire les chiffres/texte affichés.

Usage :
  python yt_frames.py <url_ou_id> [--outdir DIR] [--scene-threshold 0.25]
                      [--interval 3] [--no-scene] [--quality 720]
                      [--start MM:SS] [--end MM:SS]

Exemples :
  python yt_frames.py "https://youtu.be/xLAjU3Ik8SY"            # scènes + 1/3s
  python yt_frames.py xLAjU3Ik8SY --interval 2 --no-scene       # 1 frame / 2s
  python yt_frames.py <id> --start 1:00 --end 1:18              # seulement la fin

Dépendances : yt-dlp (auto-installé) + ffmpeg (voir find_ffmpeg() — cherche dans
le PATH puis dans l'install winget Gyan.FFmpeg).
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
        eprint("[deps] Installation de yt-dlp…")
        subprocess.run([sys.executable, "-m", "pip", "install", "-U", "-q", "yt-dlp"], check=True)


def find_ffmpeg():
    """Localise ffmpeg : PATH d'abord, puis l'emplacement d'install winget (Gyan.FFmpeg)."""
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
        "puis relance (le PATH peut nécessiter un nouveau shell ; ce script cherche aussi dans l'install winget)."
    )


def parse_video_id(s: str) -> str:
    s = s.strip()
    if re.fullmatch(r"[0-9A-Za-z_-]{11}", s):
        return s
    m = re.search(r"(?:v=|/shorts/|/embed/|youtu\.be/)([0-9A-Za-z_-]{11})", s)
    if m:
        return m.group(1)
    raise SystemExit(f"Impossible d'extraire l'ID vidéo de : {s!r}")


def download(video_id: str, outdir: str, quality: int) -> str:
    """Télécharge un mp4 progressif (audio+vidéo en un fichier, pas besoin de ffmpeg pour merger)."""
    import yt_dlp
    target = os.path.join(outdir, "video.%(ext)s")
    # format 18 = 360p mp4 progressif, puis meilleur progressif <= quality. Depuis 2026, YouTube ne sert
    # souvent plus AUCUN progressif (« Requested format is not available ») : on se rabat sur une piste
    # vidéo seule en avc1/mp4 (l'audio est inutile pour extraire des images, et pas de merge ffmpeg).
    fmt = (f"18/best[height<={quality}][vcodec^=avc1][acodec!=none]"
           f"/bestvideo[height<={quality}][vcodec^=avc1][ext=mp4]/bestvideo[height<={quality}]/best")
    opts = {"outtmpl": target, "format": fmt, "quiet": True, "no_warnings": True}
    # Sans chemin explicite, yt-dlp cherche un moteur JS dans tout le PATH et plante (WinError 448)
    # sur un dossier qu'il ne peut pas traverser, ex. ...\OpenAI\Codex\bin en session SSH (2026-10-16).
    node = shutil.which("node")
    if node:
        opts["js_runtimes"] = {"node": {"path": node}}
    url = f"https://www.youtube.com/watch?v={video_id}"
    try:
        with yt_dlp.YoutubeDL(opts) as ydl:
            info = ydl.extract_info(url, download=True)
            path = ydl.prepare_filename(info)
    except yt_dlp.utils.DownloadError as e:
        # Les pistes https « dash » renvoient parfois 403 (protection YouTube, 2026-10-15) alors que
        # le flux HLS (m3u8, itags 311/231/230/229) passe : on réessaie en HLS vidéo seule.
        if "403" not in str(e):
            raise
        print("[download] 403 sur la piste directe : nouvel essai via le flux HLS (m3u8)", file=sys.stderr)
        opts["format"] = f"bestvideo[height<={quality}][protocol^=m3u8]/311/231/230/229"
        try:
            with yt_dlp.YoutubeDL(opts) as ydl:
                info = ydl.extract_info(url, download=True)
                path = ydl.prepare_filename(info)
        except yt_dlp.utils.DownloadError as e2:
            # Sans flux HLS, yt-dlp répond « Requested format is not available », ce qui masque le vrai
            # problème : le 403 initial. Constaté le 2026-10-16 sur TOUTES les vidéos avec yt-dlp 2026.07.04
            # sans yt-dlp-ejs ; réglé par la mise à jour ci-dessous.
            raise SystemExit(
                "Téléchargement refusé par YouTube (403 sur la piste directe, pas de flux HLS de secours).\n"
                "Cause habituelle : yt-dlp trop ancien ou composant JS absent. Corriger avec :\n"
                '  python -m pip install -U "yt-dlp[default]"\n'
                f"Détail : {e2}")
    if not os.path.exists(path):
        cands = glob.glob(os.path.join(outdir, "video.*"))
        path = cands[0] if cands else path
    return path


def main():
    ap = argparse.ArgumentParser(description="Extrait des frames d'une vidéo YouTube pour lecture visuelle.")
    ap.add_argument("video")
    ap.add_argument("--outdir", default="yt_frames")
    ap.add_argument("--scene-threshold", type=float, default=0.25,
                    help="Sensibilité de détection de scène 0–1 (plus bas = plus de frames). Défaut 0.25")
    ap.add_argument("--interval", type=float, default=3.0, help="Frame toutes les N secondes (défaut 3)")
    ap.add_argument("--no-scene", action="store_true", help="Désactiver la détection de scène")
    ap.add_argument("--quality", type=int, default=720, help="Hauteur max de la vidéo téléchargée (défaut 720)")
    ap.add_argument("--width", type=int, default=960, help="Largeur des frames extraites (défaut 960)")
    ap.add_argument("--start", default=None, help="Début (MM:SS ou secondes)")
    ap.add_argument("--end", default=None, help="Fin (MM:SS ou secondes)")
    args = ap.parse_args()

    ensure_ytdlp()
    ff = find_ffmpeg()
    vid = parse_video_id(args.video)
    outdir = os.path.join(args.outdir, vid)
    framedir = os.path.join(outdir, "frames")
    os.makedirs(framedir, exist_ok=True)
    for old in glob.glob(os.path.join(framedir, "*.jpg")):
        os.remove(old)

    eprint("[1/2] Téléchargement de la vidéo…")
    video_path = download(vid, outdir, args.quality)

    trim = []
    if args.start:
        trim += ["-ss", args.start]
    if args.end:
        trim += ["-to", args.end]

    eprint("[2/2] Extraction des frames…")
    if not args.no_scene:
        # eq(n,0) garantit au moins la 1re frame : sinon, si aucune scène n'est
        # détectée (segment court/statique), ffmpeg sort « received no packets »
        # et plante. On ne met PAS check=True : si la détection échoue malgré tout,
        # l'extraction par intervalle ci-dessous reste un filet de sécurité.
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
        # chemin absolu Windows, directement utilisable par Read
        print(" ", os.path.abspath(f))
    print("\nAstuce : les écrans statiques (menus, écrans de récompenses) sortent surtout dans les scene_*.jpg.")


if __name__ == "__main__":
    main()
