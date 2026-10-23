---
name: youtube
description: "Use when a YouTube URL needs its transcript, metadata, description, comments, replies, video, or readable frames."
metadata:
  type: reference
---

# Extraction de contenu YouTube (transcript + description + commentaires)

## Pourquoi ce skill

Lors d'une recherche, l'info la plus précise est souvent **dans une vidéo** (un
créateur qui mesure des chiffres à l'écran) ou **dans ses commentaires** (où la
communauté corrige, complète, ou répond aux questions de l'auteur). `WebFetch`
ne sait lire ni les sous-titres YouTube ni les commentaires — il renvoie une
page quasi vide. Ce skill récupère tout, proprement, avec les outils faits pour ça.

> [!important] Toujours préférer le script à des appels manuels
> Le script `scripts/yt_extract.py` encapsule tous les pièges déjà rencontrés
> (nouvelle API de `youtube-transcript-api`, encodage Windows cp1252, chemins
> `/tmp` divergents bash↔python, récupération de TOUS les commentaires). Ne
> réinvente pas la roue à la main : lance le script.

## Utilisation

> [!important] Chemin du script — sinon tu le cherches à l'aveugle
> Les deux scripts (`yt_extract.py`, `yt_frames.py`) sont dans le sous-dossier
> **`scripts/` de CE skill**. Construis le chemin à partir du **répertoire de base
> du skill** qui t'est donné à l'invocation (la ligne « Base directory for this
> skill: … », qui se termine par `…/skills/youtube`) — **pas** à partir du
> dossier courant. Forme à utiliser :
>
> ```bash
> python "<SKILL_DIR>/scripts/yt_extract.py" "<url_ou_id>" --outdir <dossier>
> ```
>
> où `<SKILL_DIR>` = ce répertoire de base. N'utilise **jamais** un `scripts/…`
> relatif seul : il dépend du cwd et échoue presque toujours.

Exemples (remplace `<SKILL_DIR>` par le répertoire de base du skill) :

```bash
# Tout récupérer (transcript + description + métadonnées + commentaires)
python "<SKILL_DIR>/scripts/yt_extract.py" "https://www.youtube.com/watch?v=OgZ052bYhXg" --outdir C:/Users/Ahmed/AppData/Local/Temp/yt

# Juste le transcript + description, sans les commentaires (plus rapide)
python "<SKILL_DIR>/scripts/yt_extract.py" OgZ052bYhXg --no-comments --outdir C:/Users/Ahmed/AppData/Local/Temp/yt

# Préférer une transcription française puis anglaise
python "<SKILL_DIR>/scripts/yt_extract.py" <id> --lang fr en --outdir C:/Users/Ahmed/AppData/Local/Temp/yt

# Plusieurs vidéos : UN SEUL appel, traitées une par une (pause de 8 s entre deux)
python "<SKILL_DIR>/scripts/yt_extract.py" id1 id2 id3 --lang fr en --outdir C:/Users/Ahmed/AppData/Local/Temp/yt
```

Accepte une URL `watch`, `youtu.be`, `/shorts/`, `/embed/`, ou un **ID brut**
(11 caractères, y compris un ID qui commence par `-`). Installe automatiquement
`youtube-transcript-api` et `yt-dlp` s'ils manquent.

> [!danger] Jamais d'extractions en parallèle (blocage IP YouTube)
> Le 2026-10-15, 17 extractions lancées en même temps (`&` + `wait` en bash) ont
> fait bloquer l'IP par YouTube en quelques secondes : `IpBlocked` pour TOUS les
> transcripts, puis HTTP 429 sur les sous-titres via yt-dlp, et le blocage a
> duré plus que la séance. Seuls description et commentaires passent encore.
> - Plusieurs vidéos = **un seul appel** avec plusieurs IDs (séquentiel, `--delay 8`
>   par défaut). Ne jamais boucler sur le script avec `&`, ni lancer plusieurs
>   appels en parallèle, ni dans plusieurs agents à la fois.
> - Viser 10 à 15 vidéos par séance, pas 30 : prioriser les plus pertinentes.
> - **Repli NordVPN automatique (accord d'Ahmed, 2026-10-18)** : au premier blocage, le
>   script connecte l'app NordVPN (`scripts/nordvpn.py`, CLI officielle `NordVPN.exe -c -g
>   <pays>` / `-d`, état lu sur la carte NordLynx), réessaie, change de pays une fois si
>   besoin, et **déconnecte à la fin du lot** (il laisse le VPN connecté s'il l'était déjà).
>   Tout le PC passe par le VPN pendant ce temps (Tailscale, Brave inclus). Si NordVPN est
>   absent ou ne se connecte pas, le script le dit : **demander à Ahmed de l'activer**, puis
>   relancer. `--no-vpn` désactive le repli.
> - Si le script affiche `Transcript : BLOQUÉ`, il a déjà tenté NordVPN, réessayé (45 s
>   puis 90 s) et tenté le repli yt-dlp. Ne pas relancer en boucle : travailler avec les
>   commentaires et la description, et relancer les IDs bloqués 30 à 60 min plus
>   tard en un seul appel avec `--no-comments`.
> - Les cookies du navigateur (`cookiesfrombrowser`) ne marchent pas ici :
>   Brave verrouille sa base quand il est ouvert, Firefox n'a pas de profil.

### Ce que ça produit

Dans `<outdir>/<video_id>/` :

| Fichier | Contenu |
|---|---|
| `transcript.txt` | Sous-titres, une ligne par segment avec timestamp `[m:ss]` |
| `transcript.full.txt` | Transcription recollée en un seul bloc — **idéal pour `Grep`/lecture/recherche d'un chiffre** |
| `description.txt` | Description de la vidéo |
| `metadata.json` | Titre, chaîne, date, vues, likes, durée, tags, URL |
| `comments.txt` | Tous les commentaires (auteur, likes, texte ; réponses indentées) |
| `comments.json` | Idem, structuré (auteur, texte, likes, is_reply, timestamp) |

Et un résumé sur stdout (titre, chaîne, état du transcript, nombre de commentaires).

## Workflow recommandé en recherche

1. **Lance le script** sur la/les vidéo(s) pertinente(s). Mets `--outdir` dans un
   dossier de travail (`/tmp/yt` par ex.), pas dans un vault ou un repo.
2. **Cherche dans les fichiers** avec `Grep` plutôt que de tout lire :
   - un chiffre précis : `Grep` sur `transcript.full.txt` ET `comments.txt`
     (les commentaires contiennent souvent la valeur exacte que la vidéo donne à
     l'oral de façon imprécise, ou une correction).
   - une affirmation : lis le `transcript.full.txt` en entier (il est court).
3. **Recoupe** : un chiffre lu dans une transcription auto-générée peut être mal
   transcrit (ex. « 1,0 gold » = nombre coupé). Confirme via les commentaires ou
   une 2ᵉ source avant de l'affirmer.

## Pièges connus (déjà gérés par le script, à savoir si tu débogues à la main)

- **`youtube-transcript-api` ≥ récent** : l'API a changé. C'est
  `YouTubeTranscriptApi().fetch(video_id, languages=[...])` (méthode d'instance),
  **plus** `YouTubeTranscriptApi.get_transcript(...)` (supprimée). Les segments
  sont dans `.snippets`, chaque snippet a `.text` et `.start`.
- **Encodage Windows** : la console est en cp1252 → un `print` de texte avec
  emoji/accents lève `UnicodeEncodeError`. Le script force l'UTF-8
  (`PYTHONIOENCODING=utf-8` + `sys.stdout.reconfigure`). En manuel, préfixe :
  `PYTHONIOENCODING=utf-8 python …`.
- **`/tmp` bash ≠ `/tmp` python** : sous Git Bash, `/tmp` = `%LOCALAPPDATA%\Temp`,
  mais le Python Windows interprète `/tmp` comme `C:\tmp`. Si tu passes un chemin
  entre bash et python, convertis avec `cygpath -w` (vers Windows) / `cygpath -u`
  (vers bash). Le script écrit ses propres fichiers donc n'est pas concerné, mais
  tes commandes `Read`/`Grep` ultérieures doivent viser le bon chemin (le résumé
  imprime le chemin **absolu**).
- **Sous-titres absents** : certaines vidéos ont les sous-titres désactivés
  (`TranscriptsDisabled`). Le script l'indique (`transcript : INDISPONIBLE`) et
  continue (description + commentaires restent récupérés). Dans ce cas, l'info
  se trouve peut-être uniquement dans les commentaires ou la description.
- **Vidéo supprimée, privée ou chaîne fermée** (`Video unavailable`, `VideoUnplayable`) :
  le script affiche `=== VIDÉO INDISPONIBLE ===`, la liste en fin de lot, et sort avec
  le code 2 si toutes les vidéos demandées sont dans ce cas. Rien n'est récupérable, ni
  frames ni commentaires : passer directement à une autre vidéo. Avant le 2026-10-16, ce
  cas sortait un faux succès « None — None » (deux des trois vidéos de test d'un support
  de bureau étaient dans ce cas).
- **yt-dlp** : pas besoin de ffmpeg ni de runtime JS pour les métadonnées et
  commentaires (les warnings à ce sujet sont sans effet ici). Les commentaires
  passent par `getcomments=True` + `extractor_args` `max_comments=all`.

## Secours : pas de sous-titres → extraire et LIRE des frames de la vidéo

Quand une vidéo a les sous-titres désactivés (`TranscriptsDisabled`) **et** que
l'info recherchée est affichée à l'écran (écran de récompenses d'un jeu, tableau,
stats, UI d'un logiciel…), il reste une voie fiable : télécharger la vidéo, en
extraire des images, et **les lire visuellement avec l'outil `Read`** (qui rend
les images). C'est souvent la seule façon de récupérer un chiffre montré à l'écran
mais jamais dit ni écrit en texte.

```bash
python "<SKILL_DIR>/scripts/yt_frames.py" "<url_ou_id>" --outdir <dossier>
```

(`<SKILL_DIR>` = le répertoire de base du skill, cf. callout plus haut.)

Options utiles :

```bash
# Toute la vidéo : frames aux changements de scène + 1 frame / 3 s
python "<SKILL_DIR>/scripts/yt_frames.py" xLAjU3Ik8SY

# Cibler un passage précis (ex. l'écran de résultats en fin de vidéo)
python "<SKILL_DIR>/scripts/yt_frames.py" xLAjU3Ik8SY --start 1:00 --end 1:18

# Échantillonnage régulier serré, sans détection de scène
python "<SKILL_DIR>/scripts/yt_frames.py" <id> --interval 2 --no-scene
```

Le script imprime le **chemin absolu de chaque frame** ; ouvre les `scene_*.jpg`
en priorité avec `Read` (les écrans statiques type menu/récompenses y atterrissent),
puis les `t_*.jpg` (échantillonnage temporel) si besoin.

> [!tip] Workflow type
> 1. `yt_extract.py` d'abord (transcript + commentaires) — si transcript dispo, souvent suffisant.
> 2. Si `Transcript : INDISPONIBLE`, lance `yt_frames.py`, cible la fin (`--start`)
>    si c'est un écran de résultats, puis `Read` les `scene_*.jpg` pour lire les valeurs.
> 3. Recoupe avec les commentaires (`yt_extract.py`) si un chiffre est ambigu.

### Pièges frames (déjà gérés)

- **Plus de mp4 progressif ni de piste directe (2026-10-15)** : YouTube ne servait plus le
  format 18 (« Requested format is not available »), puis la piste vidéo directe renvoyait
  403. Le script prend désormais une piste vidéo seule (l'audio est inutile pour des images),
  et sur 403 se rabat sur le flux **HLS** (m3u8, itags 311/231/230/229), qui passe.
- **403 sur TOUTES les vidéos, même la piste directe et sans flux HLS (2026-10-16)** :
  yt-dlp 2026.07.04 sans le composant JS `yt-dlp-ejs` se faisait refuser tout téléchargement
  (le message final « Requested format is not available » masquait le 403). Corrigé par
  `python -m pip install -U "yt-dlp[default]"` (2026.08.19 + yt-dlp-ejs ; Node suffit comme
  moteur JS). Le script affiche maintenant cette commande au lieu de l'erreur trompeuse. Les
  métadonnées et sous-titres passaient encore : seul le téléchargement était touché.
- **`OSError: [WinError 448] … point de montage non approuvé : …\OpenAI\Codex\bin`** (PC fixe,
  session SSH, 2026-10-16) : yt-dlp parcourait tout le PATH pour trouver un moteur JS et
  plantait sur ce dossier. Les quatre scripts yt-dlp du plugin lui passent maintenant Node
  directement (`js_runtimes={"node": {"path": shutil.which("node")}}`) : plus de parcours du PATH.
- **Ne télécharger que le passage utile** à la main si besoin (rapide, quelques Mo) :
  `python -m yt_dlp -f "311/231/230" --download-sections "*8:20-9:40" --ffmpeg-location <dossier bin ffmpeg> -o segment.%(ext)s <url>`,
  puis `ffmpeg -i segment.mp4 -vf "fps=1/4,scale=960:-1" t_%02d.jpg` et une planche contact
  (`-vf "scale=320:-1,tile=5x4" -frames:v 1 contact.jpg`) pour tout voir en une lecture.

- **Sélection de scène vide → ffmpeg plante** (« received no packets »). Si aucun
  changement de scène n'est détecté (segment court/statique), le filtre `select`
  ne garde aucune frame et ffmpeg sort en erreur. Le script force la 1ʳᵉ frame
  (`select='eq(n\,0)+gt(scene,…)'`) et rend l'étape non bloquante, l'échantillonnage
  par intervalle servant de filet.
- **Format vidéo** : le script prend le mp4 **progressif** (format 18 / `avc1`+audio
  en un seul fichier) pour ne PAS dépendre du merge ffmpeg au téléchargement.
- **ffmpeg requis** pour cette partie (pas pour `yt_extract.py`). S'il manque :
  `winget install --id Gyan.FFmpeg -e --accept-package-agreements --accept-source-agreements`.
  Le PATH n'est pas rechargé dans le shell courant après l'install winget — le
  script cherche donc aussi ffmpeg directement dans le dossier d'install winget.

## Dépendances

- `youtube-transcript-api` (transcription) et `yt-dlp` (description, métadonnées,
  commentaires, téléchargement vidéo) — installées automatiquement via `pip`.
- `ffmpeg` — **uniquement** pour `yt_frames.py` (extraction d'images). Via winget
  (`Gyan.FFmpeg`). Pas nécessaire pour `yt_extract.py`.
- Python 3.9+.
