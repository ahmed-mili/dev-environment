#!/usr/bin/env python3
"""
yt_extract.py — Récupère de façon fiable, pour une vidéo YouTube :
  - la transcription (sous-titres) complète
  - la description + métadonnées (titre, chaîne, date, vues, durée, tags)
  - TOUS les commentaires (+ réponses)

Stratégie (chaque source avec l'outil le plus fiable pour elle) :
  - Transcription  -> youtube-transcript-api  (plus robuste que les sous-titres yt-dlp,
                      pas besoin de ffmpeg, gère les pistes auto-générées et traduites)
  - Description /   -> yt-dlp --dump-single-json  (métadonnées complètes sans télécharger
    métadonnées /      la vidéo ; --write-comments récupère TOUS les commentaires)
    commentaires

Sortie : un dossier <outdir>/<video_id>/ contenant
  - transcript.txt   (texte brut, une ligne par segment avec timestamp)
  - transcript.full.txt (texte recollé, paragraphe unique — pratique pour lecture/recherche)
  - description.txt
  - metadata.json
  - comments.txt     (auteur + texte, indenté pour les réponses)
  - comments.json    (structuré : auteur, texte, likes, is_reply, timestamp)
Et un résumé imprimé sur stdout.

Usage :
  python yt_extract.py <url_ou_id> [<url_ou_id> ...] [--outdir DIR] [--no-comments] [--lang en fr ...]
  python yt_extract.py "https://www.youtube.com/watch?v=OgZ052bYhXg"
  python yt_extract.py OgZ052bYhXg --lang fr en --outdir ./yt
  python yt_extract.py id1 id2 id3 --outdir ./yt      # plusieurs vidéos, traitées UNE PAR UNE

Anti-blocage (IpBlocked / HTTP 429) : YouTube limite les sous-titres par IP. Lancer plusieurs
extractions en parallèle (`&` en bash) déclenche le blocage en quelques secondes, pour TOUTES
les vidéos. D'où : plusieurs vidéos = un seul appel (séquentiel, pause --delay entre deux),
nouvel essai avec attente croissante si bloqué, puis repli sur les sous-titres via yt-dlp.
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.request

# --- UTF-8 partout : sur Windows la console est en cp1252 et plante sur les emojis/accents. ---
os.environ.setdefault("PYTHONIOENCODING", "utf-8")
try:
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
except Exception:
    pass


def eprint(*a, **k):
    print(*a, file=sys.stderr, **k)


def ensure_deps():
    """Installe les dépendances manquantes (youtube-transcript-api, yt-dlp) à la volée."""
    missing = []
    try:
        import youtube_transcript_api  # noqa: F401
    except ImportError:
        missing.append("youtube-transcript-api")
    try:
        import yt_dlp  # noqa: F401
    except ImportError:
        missing.append("yt-dlp")
    if missing:
        eprint(f"[deps] Installation de : {', '.join(missing)}")
        subprocess.run(
            [sys.executable, "-m", "pip", "install", "-U", "-q", *missing],
            check=True,
        )


def parse_video_id(s: str) -> str:
    """Accepte une URL (watch, youtu.be, shorts, embed) ou un ID brut."""
    s = s.strip()
    if re.fullmatch(r"[0-9A-Za-z_-]{11}", s):
        return s
    m = re.search(r"(?:v=|/shorts/|/embed/|youtu\.be/)([0-9A-Za-z_-]{11})", s)
    if m:
        return m.group(1)
    raise SystemExit(f"Impossible d'extraire l'ID vidéo de : {s!r}")


BLOCK_MARKERS = ("IpBlocked", "RequestBlocked", "TooManyRequests", "429")


def is_block(reason) -> bool:
    """Vrai si l'échec vient d'une limitation YouTube (et non d'une vidéo sans sous-titres)."""
    return bool(reason) and any(m in str(reason) for m in BLOCK_MARKERS)


# Repli NordVPN (accord d'Ahmed du 2026-10-18) : sur blocage, nouvelle IP via l'app NordVPN,
# déconnectée à la fin du lot si c'est le script qui l'a connectée.
VPN = {"enabled": True, "ours": False, "was_on": False}


def vpn_switch() -> bool:
    """Passe par NordVPN (nouvelle IP). False si impossible : il faut alors demander à Ahmed de l'activer."""
    if not VPN["enabled"]:
        return False
    import nordvpn
    if not nordvpn.available():
        eprint("      NordVPN introuvable : demander à Ahmed d'activer un VPN puis relancer.")
        VPN["enabled"] = False
        return False
    if not VPN["ours"]:
        VPN["was_on"] = nordvpn.is_connected()
    eprint("      repli NordVPN : connexion…")
    country = nordvpn.connect()
    if not country:
        eprint("      NordVPN ne s'est pas connecté : demander à Ahmed de l'activer à la main.")
        VPN["enabled"] = False
        return False
    VPN["ours"] = True
    eprint(f"      NordVPN connecté ({country}) : nouvel essai")
    return True


def get_transcript_with_retry(video_id: str, langs, retries: int):
    """get_transcript ; si YouTube bloque l'IP : NordVPN (2 IP max), puis attente croissante."""
    segs, lang = get_transcript(video_id, langs)
    switches = 0
    while not segs and is_block(lang) and switches < 2 and vpn_switch():
        switches += 1
        segs, lang = get_transcript(video_id, langs)
    for attempt in range(retries):
        if segs or not is_block(lang):
            break
        wait = 45 * (attempt + 1)
        eprint(f"      bloqué par YouTube ({str(lang)[:40]}…) : nouvel essai dans {wait} s")
        time.sleep(wait)
        segs, lang = get_transcript(video_id, langs)
    return segs, lang


def transcript_from_ytdlp(info: dict, langs):
    """Repli : sous-titres (manuels puis auto) listés par yt-dlp, format json3. (segs, langue) ou (None, raison)."""
    subs, auto = info.get("subtitles") or {}, info.get("automatic_captions") or {}
    for pool in (subs, auto):
        for code in [c for l in langs for c in (l, f"{l}-orig")]:
            track = next((t for t in pool.get(code, []) if t.get("ext") == "json3"), None)
            if not track:
                continue
            try:
                req = urllib.request.Request(track["url"], headers={"User-Agent": "Mozilla/5.0"})
                with urllib.request.urlopen(req, timeout=30) as r:
                    data = json.load(r)
            except Exception as e:
                return None, f"yt-dlp {type(e).__name__}: {e}"
            segs = [{"start": e.get("tStartMs", 0) / 1000,
                     "text": "".join(s.get("utf8", "") for s in e["segs"]).strip()}
                    for e in data.get("events", []) if e.get("segs")]
            segs = [s for s in segs if s["text"]]
            if segs:
                return segs, code
    return None, "aucune piste yt-dlp"


def get_transcript(video_id: str, langs):
    """Retourne (segments, langue) ou (None, raison). segments = liste de dicts {start,text}."""
    from youtube_transcript_api import YouTubeTranscriptApi
    api = YouTubeTranscriptApi()
    # 1) essai direct dans les langues demandées (puis n'importe quelle langue dispo)
    try:
        fetched = api.fetch(video_id, languages=langs)
    except Exception:
        # 2) fallback : lister les pistes et prendre la 1re (traduite en 1re langue voulue si possible)
        try:
            tlist = api.list(video_id)
            tr = None
            for t in tlist:
                tr = t
                break
            if tr is None:
                return None, "aucune piste de sous-titres"
            if tr.language_code not in langs and tr.is_translatable:
                try:
                    tr = tr.translate(langs[0])
                except Exception:
                    pass
            fetched = tr.fetch()
        except Exception as e:
            return None, f"{type(e).__name__}: {e}"
    snippets = fetched.snippets if hasattr(fetched, "snippets") else fetched
    lang = getattr(fetched, "language_code", "?")
    segs = [{"start": float(getattr(s, "start", 0.0)), "text": s.text} for s in snippets]
    return segs, lang


def run_ytdlp_info(video_id: str, want_comments: bool):
    """Retourne le dict info.json complet de yt-dlp (sans télécharger la vidéo)."""
    import yt_dlp
    opts = {
        "skip_download": True,
        "quiet": True,
        "no_warnings": True,
        "ignoreerrors": True,
        "extract_flat": False,
    }
    # Sans chemin explicite, yt-dlp cherche un moteur JS dans tout le PATH et plante (WinError 448)
    # sur un dossier qu'il ne peut pas traverser, ex. ...\OpenAI\Codex\bin en session SSH (2026-10-16).
    node = shutil.which("node")
    if node:
        opts["js_runtimes"] = {"node": {"path": node}}
    if want_comments:
        opts["getcomments"] = True
        # tous les commentaires + toutes les réponses, triés par "top"
        opts["extractor_args"] = {
            "youtube": {
                "max_comments": ["all", "all", "all", "all"],
                "comment_sort": ["top"],
            }
        }
    url = f"https://www.youtube.com/watch?v={video_id}"
    with yt_dlp.YoutubeDL(opts) as ydl:
        info = ydl.extract_info(url, download=False)
    return info or {}


def fmt_ts(seconds: float) -> str:
    s = int(seconds)
    return f"{s // 3600:d}:{(s % 3600) // 60:02d}:{s % 60:02d}" if s >= 3600 else f"{s // 60:d}:{s % 60:02d}"


def main():
    ap = argparse.ArgumentParser(description="Récupère transcript + description + commentaires de vidéos YouTube.")
    ap.add_argument("videos", nargs="+", help="URL(s) YouTube ou ID(s) vidéo (11 caractères)")
    ap.add_argument("--outdir", default="yt_extract", help="Dossier de sortie (défaut : ./yt_extract)")
    ap.add_argument("--no-comments", action="store_true", help="Ne pas récupérer les commentaires (plus rapide)")
    ap.add_argument("--lang", nargs="+", default=["en", "fr", "es", "de"],
                    help="Langues de transcription préférées, par ordre (défaut : en fr es de)")
    ap.add_argument("--delay", type=float, default=8,
                    help="Pause en secondes entre deux vidéos (défaut : 8) pour ne pas se faire bloquer")
    ap.add_argument("--retries", type=int, default=2,
                    help="Nouveaux essais du transcript si YouTube bloque l'IP (défaut : 2, attente 45 s puis 90 s)")
    ap.add_argument("--no-vpn", action="store_true",
                    help="Ne pas basculer sur NordVPN quand YouTube bloque l'IP")
    # Un ID qui commence par « - » (ex. -ZuwoNJPHGE) serait lu comme une option : on le convertit en URL.
    argv = [f"https://youtu.be/{a}" if re.fullmatch(r"-[0-9A-Za-z_-]{10}", a) else a for a in sys.argv[1:]]
    args = ap.parse_args(argv)

    ensure_deps()
    VPN["enabled"] = not args.no_vpn
    blocked, unavailable = [], []
    try:
        for i, video in enumerate(args.videos):
            if i:
                time.sleep(args.delay)
            if len(args.videos) > 1:
                eprint(f"\n##### Vidéo {i + 1}/{len(args.videos)} : {video}")
            status = extract_one(video, args)
            if status == "blocked":
                blocked.append(parse_video_id(video))
            elif status == "unavailable":
                unavailable.append(parse_video_id(video))
    finally:
        if VPN["ours"]:
            import nordvpn
            if VPN["was_on"]:
                print("\nNordVPN laissé connecté (il l'était déjà avant), sur un autre serveur.")
            elif nordvpn.disconnect():
                print("\nNordVPN déconnecté (connecté par le script pour contourner le blocage).")
            else:
                print("\n!!! NordVPN n'a pas pu être déconnecté : le couper à la main.")
    if unavailable and len(args.videos) > 1:
        print(f"\n!!! Vidéos INDISPONIBLES (supprimées, privées ou chaîne fermée) : {' '.join(unavailable)}")
    if blocked:
        print(f"\n!!! Transcript BLOQUÉ par YouTube pour : {' '.join(blocked)}")
        if VPN["enabled"]:
            print("    Le repli NordVPN a été tenté sans succès (IP du VPN bloquée aussi).")
        else:
            print("    Repli NordVPN impossible : demander à Ahmed d'activer son VPN, puis relancer.")
        print("    Description et commentaires sont bien récupérés. Ne pas relancer en boucle :")
        print("    attendre 30 à 60 min puis relancer ces IDs en un seul appel, avec --no-comments.")
    if len(unavailable) == len(args.videos):
        sys.exit(2)


def extract_one(video: str, args) -> str:
    """Extrait une vidéo. Retourne 'ok', 'blocked' ou 'no-transcript'."""
    vid = parse_video_id(video)
    outdir = os.path.join(args.outdir, vid)
    os.makedirs(outdir, exist_ok=True)

    # --- Transcription ---
    eprint("[1/2] Transcription…")
    segs, lang = get_transcript_with_retry(vid, args.lang, args.retries)
    info = None
    if not segs and is_block(lang):
        eprint("      repli : sous-titres via yt-dlp…")
        info = run_ytdlp_info(vid, want_comments=not args.no_comments)
        segs2, lang2 = transcript_from_ytdlp(info, args.lang)
        if segs2:
            segs, lang = segs2, f"{lang2} (via yt-dlp)"
    if segs:
        with open(os.path.join(outdir, "transcript.txt"), "w", encoding="utf-8") as f:
            for s in segs:
                f.write(f"[{fmt_ts(s['start'])}] {s['text']}\n")
        full = " ".join(s["text"].replace("\n", " ") for s in segs)
        full = re.sub(r"\s+", " ", full).strip()
        with open(os.path.join(outdir, "transcript.full.txt"), "w", encoding="utf-8") as f:
            f.write(full + "\n")
        transcript_status = f"{len(segs)} segments, langue '{lang}', {len(full)} caractères"
        result = "ok"
    elif is_block(lang):
        transcript_status = f"BLOQUÉ par YouTube (limite par IP) : {str(lang)[:80]}"
        result = "blocked"
    else:
        transcript_status = f"INDISPONIBLE ({lang})"
        result = "no-transcript"

    # --- Description + métadonnées + commentaires ---
    eprint("[2/2] Description, métadonnées" + ("" if args.no_comments else " et commentaires") + "…")
    if info is None:
        info = run_ytdlp_info(vid, want_comments=not args.no_comments)
    if not info.get("title"):
        # yt-dlp n'a rien renvoyé : vidéo supprimée, privée ou chaîne fermée. On le dit
        # clairement au lieu d'un résumé « None — None » qui ressemble à un succès.
        print("\n=== VIDÉO INDISPONIBLE ===")
        print(f"ID / URL   : {vid}  (https://www.youtube.com/watch?v={vid})")
        print("Cause      : supprimée, privée ou chaîne fermée (voir l'erreur yt-dlp au-dessus).")
        print(f"Transcript : {transcript_status}")
        print("Rien d'exploitable : passer à une autre vidéo.")
        return "unavailable"

    meta = {
        "id": vid,
        "title": info.get("title"),
        "channel": info.get("channel") or info.get("uploader"),
        "channel_id": info.get("channel_id"),
        "upload_date": info.get("upload_date"),
        "duration_string": info.get("duration_string"),
        "view_count": info.get("view_count"),
        "like_count": info.get("like_count"),
        "comment_count": info.get("comment_count"),
        "tags": info.get("tags"),
        "categories": info.get("categories"),
        "webpage_url": info.get("webpage_url"),
    }
    with open(os.path.join(outdir, "metadata.json"), "w", encoding="utf-8") as f:
        json.dump(meta, f, ensure_ascii=False, indent=2)
    with open(os.path.join(outdir, "description.txt"), "w", encoding="utf-8") as f:
        f.write((info.get("description") or "") + "\n")

    comments = info.get("comments") or []
    n_comments = len(comments)
    if not args.no_comments:
        # JSON structuré
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
        # TXT lisible (réponses indentées)
        with open(os.path.join(outdir, "comments.txt"), "w", encoding="utf-8") as f:
            for c in norm:
                indent = "    " if c["is_reply"] else ""
                likes = f" (+{c['like_count']})" if c["like_count"] else ""
                txt = c["text"].replace("\n", " ").strip()
                f.write(f"{indent}[{c['author']}]{likes} {txt}\n")

    # --- Résumé ---
    print("\n=== Extraction terminée ===")
    print(f"Vidéo      : {meta['title']}  —  {meta['channel']}")
    print(f"ID / URL   : {vid}  ({meta['webpage_url']})")
    print(f"Publiée    : {meta['upload_date']}   Durée : {meta['duration_string']}   Vues : {meta['view_count']}")
    print(f"Transcript : {transcript_status}")
    print(f"Commentaires : {'(ignorés)' if args.no_comments else n_comments}")
    print(f"Dossier    : {os.path.abspath(outdir)}")
    print("Fichiers   : " + ("transcript.txt, transcript.full.txt, " if segs else "")
          + "description.txt, metadata.json" + ("" if args.no_comments else ", comments.txt, comments.json"))
    if result == "no-transcript":
        print("Sans transcript : l'info montrée à l'écran se lit avec yt_frames.py (voir SKILL.md, section Secours).")
    return result


if __name__ == "__main__":
    main()
