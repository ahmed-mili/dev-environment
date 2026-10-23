# Plugin `content-extractor`

Extracteur de contenu local pour Claude Code. Récupère tout ce qui est extractible d'une URL sociale/web : vidéos (YouTube, TikTok, Instagram, X/Twitter, Twitch, +1800 sites yt-dlp), threads Reddit, et leurs commentaires — transcript, métadonnées, description, commentaires, téléchargement média, extraction de frames.

## Skills exposés

Découpage par **différence réelle de capacité**, pas par étiquette de plateforme (yt-dlp auto-détecte le site depuis l'URL, donc `tiktok`/`instagram`/`x` partageraient le même moteur → un seul skill `video` les couvre).

| Skill | Namespace | Pour quoi |
|---|---|---|
| `youtube` | `content-extractor:youtube` | YouTube : **transcript** (via `youtube-transcript-api`, plus fiable que yt-dlp) + description + métadonnées + **tous** les commentaires + frames. |
| `reddit` | `content-extractor:reddit` | Reddit : post + **images** + commentaires/réponses, via un vrai navigateur Chromium (Playwright) qui résout le défi anti-bot. **Aucune auth, aucune app, aucun cookie.** |
| `video` | `content-extractor:video` | Toute autre vidéo (TikTok, Instagram, Twitch, +1800 sites) via yt-dlp : métadonnées + commentaires + téléchargement + frames. |
| `x` | `content-extractor:x` | Post X complet : texte, thread, réponses, citation, sondage, note, article, médias (session Brave connectée, sinon fxtwitter). |
| `webpage` | `content-extractor:webpage` | N'importe quelle **page web** (article, doc, comparatif) via Playwright : contenu en **markdown qui garde la mise en forme** (titres, **tableaux**, listes) + **capture pleine page** + images. Marche là où WebFetch échoue (JS / anti-bot). |
| `shop` | `content-extractor:shop` | Fiche produit marchande FR (Amazon.fr, LDLC, Cdiscount, TopAchat) : prix, stock, vendeur, specs, avis (négatifs d'abord), Q&A, recherche LDLC/Cdiscount/TopAchat. |
| `prices` | `content-extractor:prices` | Comparateurs LeDénicheur et idealo : offres, prix le plus bas, frais de port, liens marchands, historique 3 mois / 6 mois / 1 an, recherche vérifiée au contenu. Brave avec fenêtre minimisée (headless bloqué). |
| `steam` | `content-extractor:steam` | Steam : infos jeu + prix FR, avis (filtres langue/négatifs/récents, pagination) et annonces/patch notes officielles (filtre mot-clé et date), via les API publiques, sans cookie ni clé. Marche quand la page Steam n'affiche qu'un mur de cookies. |

Pourquoi `youtube` et `reddit` sont séparés de `video` : leur **workflow** est différent (texte-first — transcript / thread), alors que TikTok/Instagram/X sont **visual-first** (pas de sous-titres → frames). `webpage` couvre tout le reste du web (hors plateformes ci-dessus).

## Scripts

Chaque skill est **auto-contenu** : ses scripts vivent dans `skills/<skill>/scripts/`, donc le chemin `<repertoire-du-skill>/scripts/…` que Claude construit à l'invocation pointe directement dessus (pas de `lib/` partagée ni de build step).

| Script | Skill | Rôle |
|---|---|---|
| `yt_extract.py` | youtube | transcript + description + métadonnées + commentaires |
| `yt_frames.py` | youtube | download + extraction de frames (écrans sans sous-titres) |
| `media.py` | video | yt-dlp générique : métadonnées + commentaires + download (toute URL) |
| `frames.py` | video | download + extraction de frames (toute vidéo) |
| `reddit_thread.py` | reddit | post + images + commentaires via Playwright (vrai Chromium, résout le js_challenge ; aucune auth) |
| `webpage.py` | webpage | page web → markdown structuré (tableaux préservés) + screenshot pleine page + images, via Playwright |
| `shop.py` (+ `shop_sites.py`, `shop_common.py`, `shop_login.py`) | shop | fiche + avis + Q&A via Playwright et JSON-LD ; `shop_login.py` capture la session Brave Amazon (ferme Brave : accord d'Ahmed requis) |
| `prices.py` | prices | page produit ou `--find` → offers.json/md + history.json/md, via Playwright (Brave avec fenêtre minimisée, profil jetable) |
| `steam.py` | steam | nom → appid, appdetails (prix FR), appreviews (cursor), GetNewsForApp (pagination par enddate), sortie markdown + json ; stdlib seule |

## Dépendances

- Python 3.9+
- `youtube-transcript-api`, `yt-dlp` — auto-installées par les scripts qui en ont besoin.
- `ffmpeg` — uniquement pour l'extraction de frames (`yt_frames.py` / `frames.py`). Via winget : `winget install --id Gyan.FFmpeg -e`.
- `playwright` + **Chromium** — auto-installés par `reddit_thread.py` / `webpage.py` si absents (sinon réutilise le Chromium déjà présent).
- `readability-lxml`, `markdownify`, `lxml` — auto-installés par `webpage.py`.

## Auth

- **Reddit** : **aucune auth nécessaire** — `reddit_thread.py` pilote un vrai Chromium qui résout le défi anti-bot tout seul. C'est la solution durable (pas d'app Reddit, pas de cookie, pas d'OAuth).
- **Instagram / X** (contenu privé) : `media.py` accepte `--cookies-from-browser firefox` (ou `chrome`) ou `--cookies cookies.txt`. ⚠️ Brave chiffre ses cookies (app-bound) → illisibles sans admin ; pour Brave, préférer `--cookies` (fichier cookies.txt exporté). Sans cookies, le public passe ; le privé renvoie un message clair.

## Historique

Absorbe l'ancien plugin mono-skill `youtube-extract` (devenu le skill `youtube`).
