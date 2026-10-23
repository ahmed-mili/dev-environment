---
name: video
description: "Use when extracting media, metadata, frames, or comments from TikTok, Instagram, Twitch, Facebook, or yt-dlp sites; X posts go to content-extractor:x."
metadata:
  type: reference
---

# Extraction vidéo générique (TikTok, Instagram, X, Twitch, +1800 sites)

## Pourquoi ce skill

`yt-dlp` auto-détecte la plateforme depuis l'URL : **un seul moteur** sert TikTok,
Instagram, X/Twitter, Twitch, Vimeo... `WebFetch` ne sait lire ni la vidéo, ni ses
commentaires, ni ce qui est affiché à l'écran. Ce skill récupère tout proprement.

> [!note] YouTube, Reddit et X ont leurs propres skills
> - **YouTube** -> `content-extractor:youtube` (transcript via `youtube-transcript-api`, plus fiable que yt-dlp).
> - **Thread Reddit** (texte) -> `content-extractor:reddit`. Une **vidéo hébergée sur Reddit** reste extractible ici via `media.py`.
> - **Post X** (texte, thread, réponses, vidéo) -> content-extractor:x.

## Utilisation

> [!important] Chemin du script — sinon tu le cherches à l'aveugle
> Les scripts (`media.py`, `frames.py`) sont dans le sous-dossier **`scripts/` de
> CE skill**. Construis le chemin à partir du **répertoire de base du skill** qui
> t'est donné à l'invocation (la ligne « Base directory for this skill: … », qui se
> termine par `…/skills/video`) — **pas** à partir du dossier courant :
>
> ```bash
> python "<SKILL_DIR>/scripts/media.py" "<url>" --outdir <dossier>
> ```
>
> N'utilise **jamais** un `scripts/…` relatif seul (il dépend du cwd).

### 1. Métadonnées + description + commentaires (`media.py`)

```bash
# Tout récupérer (métadonnées + commentaires), sans télécharger la vidéo
python "<SKILL_DIR>/scripts/media.py" "https://www.tiktok.com/@user/video/123" --outdir C:/Users/Ahmed/AppData/Local/Temp/cr

# Plus rapide, sans commentaires
python "<SKILL_DIR>/scripts/media.py" "<url>" --no-comments --outdir C:/Users/Ahmed/AppData/Local/Temp/cr

# Télécharger aussi le média
python "<SKILL_DIR>/scripts/media.py" "<url>" --download --outdir C:/Users/Ahmed/AppData/Local/Temp/cr
```

Produit dans `<outdir>/<plateforme>_<id>/` : `metadata.json`, `description.txt`,
`comments.json`/`comments.txt` (si la plateforme les expose), et `media.*` si `--download`.
Le résumé stdout indique si des **sous-titres** sont exposés — sinon, passe aux frames.

### 2. Frames quand il n'y a pas de sous-titres (`frames.py`)

Quand l'info est **affichée à l'écran** (stats, tableau, UI, écran de résultats) et
qu'il n'y a pas de sous-titres : télécharge la vidéo, extrait des images, et **lis-les
avec l'outil `Read`** (qui rend les images).

```bash
# Scènes + 1 frame / 3 s
python "<SKILL_DIR>/scripts/frames.py" "<url>" --outdir C:/Users/Ahmed/AppData/Local/Temp/cr

# Cibler un passage (ex. la fin)
python "<SKILL_DIR>/scripts/frames.py" "<url>" --start 0:50 --end 1:10
```

Ouvre en priorité les `scene_*.jpg` (écrans statiques) avec `Read`, puis les `t_*.jpg`.

## Contenu privé / authentification (Instagram, X)

Certains contenus exigent une session connectée. Les deux scripts acceptent :

```bash
--cookies-from-browser firefox      # (ou chrome, edge) : réutilise tes cookies de navigateur
--cookies C:/chemin/cookies.txt     # fichier Netscape, alternative
```

Sans cookies, le **public** passe ; le **privé** renvoie un message clair (pas de plantage opaque).

## Workflow recommandé en recherche

1. `media.py` d'abord : métadonnées + commentaires (souvent la valeur est dans les commentaires).
2. Si le résumé dit « Sous-titres exposés : NON » **et** que l'info est à l'écran -> `frames.py`, cible le passage, puis `Read` les `scene_*.jpg`.
3. `Grep` sur `comments.txt` pour un chiffre/affirmation ; recoupe avant d'affirmer.

## Pièges connus (déjà gérés)

- **Plateforme non supportée / contenu privé** : `media.py` s'arrête avec un message explicite (essayer `--cookies-from-browser`).
- **Pas de commentaires** : beaucoup de plateformes n'exposent pas les commentaires à yt-dlp ; `comments.*` sera vide — ce n'est pas une erreur.
- **ffmpeg requis pour les frames** (pas pour `media.py`). S'il manque : `winget install --id Gyan.FFmpeg -e`. Le script le cherche aussi dans l'install winget si le PATH n'est pas rechargé.
- **Détection de scène vide** : sur un segment statique, le filtre `select` ne garde aucune frame ; le script force la 1re frame et l'échantillonnage par intervalle sert de filet.

## Dépendances

- `yt-dlp` (auto-installé via pip).
- `ffmpeg` — **uniquement** pour `frames.py`. Pas nécessaire pour `media.py`.
- Python 3.9+.
