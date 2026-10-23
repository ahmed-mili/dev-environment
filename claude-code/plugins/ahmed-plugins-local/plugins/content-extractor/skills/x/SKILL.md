---
name: x
description: "Use when an X/Twitter post URL needs its full text, thread, replies, quoted post, article, poll, community note, images, or video."
metadata:
  type: reference
---

# Extraction d'un post X (Twitter) : texte, thread, réponses, médias

## Pourquoi ce skill

`WebFetch` et `yt-dlp` ne rendent pas un post X en entier : pas de réponses, pas de
liens développés, pas de citation, pas de sondage ni de note de la communauté. Ce
skill pilote Chromium (Playwright) avec la session X d'Ahmed, capture les réponses
GraphQL de la page et produit un `post.md` complet plus les médias. Lecture seule.

> [!important] Chemin du script, sinon tu le cherches à l'aveugle
> Les scripts sont dans le sous-dossier **`scripts/` de CE skill**. Construis le
> chemin à partir de la ligne « Base directory for this skill: … » (qui se termine
> par `…/skills/x`), **pas** à partir du dossier courant. N'utilise jamais un
> `scripts/…` relatif seul.

## Utilisation

### 1. Première fois ou session expirée : `x_login.py`

```bash
python "<SKILL_DIR>/scripts/x_login.py"
```

**Prévenir Ahmed et obtenir son accord avant** : Brave se ferme puis se rouvre deux
fois. Les cookies sont stockés hors repo (`%LOCALAPPDATA%\content-extractor\x-cookies.json`).
Ne jamais les afficher ni les copier.

### 2. Extraction en trois phases : `x_post.py`

```bash
# Phase 1 (environ 6 s, au premier plan) : post, médias, top 20 des réponses par likes
python "<SKILL_DIR>/scripts/x_post.py" "https://x.com/<user>/status/<id>" --quick --outdir <scratchpad>/x
# Phases 2 et 3 (plusieurs minutes, à lancer avec run_in_background)
python "<SKILL_DIR>/scripts/x_post.py" "https://x.com/<user>/status/<id>" --replies --outdir <scratchpad>/x
```

Flux standard : lancer `--quick`, lire `post.md` tout de suite, puis lancer `--replies` en arrière-plan
et lire `replies.md` quand la ligne `PHASE 2 OK : <directes>/<compteur> ...` apparaît (réponses directes
complètes, en général 1 à 2 minutes), ou à la fin (`PHASE 3 OK`, sous-fils inclus, environ 15 minutes sur
un post à 500 réponses). `--no-deep` arrête après la phase 2. Sans option, tout s'enchaîne comme avant et
`replies.md` est aussi écrit.

- `post.md` : post, liens, citation, carte, sondage, note, thread de l'auteur, médias, puis « Meilleures réponses (top 20 par likes) ». Plus d'arbre complet.
- `replies.md` : réponses directes par likes décroissants, chacune suivie de ses sous-réponses indentées (ordre de conversation), puis les orphelines. L'en-tête dit « Phase 2/3 » ou « complet ».
- Tri demandé à X : la variable GraphQL `rankingMode` de `TweetDetail` (Relevance par défaut) accepte `Likes`, réécrite en lecture seule par `page.route`. `--quick` demande `Likes` (vrai top). Le mode complet fait trois passes sur la page principale (tri par défaut, `Likes`, `Recency`) car les listes se complètent ; chaque passe journalise son nombre de réponses GraphQL sur stderr (si une passe ramène 0, X a limité le débit : relancer plus tard). `--ranking Relevance|Recency|Likes` force une seule passe.

Options : `--max-replies N`, `--max-pages N` (sous-fils visités, 150 par défaut), `--no-media`, `--headed` (fenêtre visible).
Sans cookies, le script affiche le message pour `x_login.py` et bascule sur fxtwitter
(texte et médias du post seul, pas de réponses).

### 3. Lecture

1. Lire `post.md`, puis `replies.md`.
2. **Ouvrir les images de `media/` avec `Read`** avant d'en parler. Règle « rien de haram » : une image indécente est écartée sans description.
3. Vidéo dont l'info est à l'écran (pas de sous-titres) : `content-extractor:video` (`frames.py`) sur l'URL du post.

Autres fichiers : `tweets.json` (données structurées), `raw/` (réponses GraphQL brutes).

## Lire le résumé stdout

La ligne « Réponses récupérées N / compteur X » compare les réponses **directes**
au compteur `replies` de X (qui ne compte que les directes) ; le total avec
sous-réponses est donné à part. Un petit écart est normal : réponses supprimées,
comptes protégés, comptes qui bloquent Ahmed. Références mesurées : DevDsgn 13/13
directes (20 au total), Elia 91/94 (182 au total). Un écart important : relancer
avec `--headed` et vérifier la session.

La fin du résumé indique « Limite --max-pages atteinte » et « Pages incomplètes » (pages dont X annonçait encore des réponses mais où 20 rondes de défilement n'ont rien ramené). Cas Berman (compteur 523 à 528) : 399 directes avant le correctif, 394 avec le tri par défaut seul, 422 avec le tri `Likes` seul, 480 avec deux passes, 485 (91 %) avec les trois (Recency ajoute 5 pour environ 25 s de plus, phase 2 en 80 s). X termine lui-même chaque liste (voir piège ci-dessous) ; le reste est masqué, supprimé ou invisible pour ce compte.

## Pièges connus (déjà gérés)

- **Source des réponses** : l'opération GraphQL `TweetDetail` (HTTP 200). Les sous-fils s'ouvrent via `/i/status/<id>` (passe profonde, 150 pages max par défaut, réglable par `--max-pages`).
- **Langue de l'interface** : X suit le cookie `lang` (français), pas la locale du navigateur. Les libellés des boutons sont lus dans les curseurs JSON (`displayTreatment.actionText`, ex. « Afficher les spams probables », « Voir les réponses »), avec une regex EN/FR en secours. Sans cela, 3/13 et 8/94 réponses manquaient.
- **Fin de page** : une page est finie quand le dernier `TweetDetail` de la visite n'a plus de curseur `Bottom` et qu'aucun libellé de dépliage n'est resté sans clic. Les rondes sans nouveauté seules ne terminent pas une page tant qu'un `Bottom` est en attente (arrêt de sécurité à 20 rondes, noté dans `incomplete_pages`). Exception vérifiée sur Berman : un `Bottom` accompagné d'un `TimelineTerminateTimeline` de direction `Bottom` est vestigial, c'est la vraie fin de la liste chez X (14 pages, environ 394 directes pour un compteur de 523). Chaque ronde défile aussi jusqu'au vrai bas de page (`scrollTo`) en plus de la molette.
- **Posts recommandés** : les réponses capturées contiennent des tweets « plus de posts ». Ils restent dans `raw/` mais sont exclus de `tweets.json`, `post.md` et des médias.
- **Repli** : `api.fxtwitter.com/i/status/<id>` fonctionne sans nom d'utilisateur.
- **Lecture seule** : le script ne publie, n'aime et ne suit rien.
- **Scripts lancés avec `python -I`** : appeler `sys.stdout.reconfigure(encoding="utf-8")`.

## Dépendances

- Python 3.9+.
- `playwright` (Chromium installé au besoin, comme pour `reddit`).
- Brave, uniquement pour `x_login.py`.
