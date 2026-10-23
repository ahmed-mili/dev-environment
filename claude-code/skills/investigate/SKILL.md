---
name: investigate
description: "Use when Ahmed asks for research, a comparison, a pre-purchase opinion, a fact check, or types /investigate. Mandatory sweep of YouTube, Reddit, X and web via content-extractor skills. Takes priority over anthropic-skills:deep-research (costly subagents)."
---

# Enquête multi-canaux

Orchestrateur sans script. Il impose la découverte sur 4 canaux (YouTube, Reddit,
X, web) puis l'extraction via les skills `content-extractor:*`. Pas de sous-agents
(quota). Pas de `WebFetch`/`fetch` sur YouTube, Reddit ou X : ils échouent ou
renvoient des pages vides.

## 1. Découper la question

Écrire 3 à 6 points vérifiables (ex. « telle fonction est-elle autorisée par
l'éditeur X, selon quel texte, depuis quand ? »). Chaque point devra finir
confirmé, contredit ou non vérifié.

## 2. Découverte : les 4 canaux, aucun sauté

- **YouTube** (requêtes en anglais ET en français si pertinent) :
  ```bash
  python -m yt_dlp --flat-playlist --print "%(id)s | %(title)s | %(view_count)s" "ytsearch10:<requête>"
  ```
- **Reddit, X, web** : MCP `brave-search` (`brave_web_search`) avec `site:reddit.com <requête>`,
  `site:x.com <requête>`, puis requête libre. À défaut : `freeweb` `web_search`.
- `brave-search` : limite de débit possible (« Rate limit exceeded ») et pannes réseau
  passagères (DNS). Espacer les requêtes, ne pas en lancer plus de 3 en parallèle,
  réessayer une fois ; sinon `freeweb` `web_search`.
- Privilégier les sources primaires (règlement, communiqué, page éditeur), puis
  les vidéos/fils récents et très commentés. Ignorer les contenus de plus d'un an
  si le sujet évolue vite (règles, prix, versions).

## 3. Extraction obligatoire

Invoquer le tool `Skill` (`content-extractor:<x>`) AVANT d'utiliser ses scripts :
le répertoire de base du skill y est donné.

| Canal | Skill | Plancher |
|---|---|---|
| YouTube | `content-extractor:youtube` | >= 2 vidéos, transcript + commentaires |
| Reddit | `content-extractor:reddit` | >= 2 fils (URL `/comments/<id>/`) |
| X | `content-extractor:x` | posts X si le sujet y est actif |
| Web | `content-extractor:webpage` | >= 3 pages complètes (>= 1 source primaire lue) |
| TikTok, Instagram, Twitch... | `content-extractor:video` | selon besoin |

Sources selon le sujet, en plus des 4 canaux :
- **Achat** : `content-extractor:shop` (fiche Amazon.fr/LDLC/Cdiscount/TopAchat : prix,
  vendeur, avis négatifs d'abord) et `content-extractor:prices` (LeDénicheur, idealo :
  offres, prix le plus bas, historique). Wooting : prix de référence = configurateur
  wooting.io, là où Ahmed achète.
- **Jeu PC** : `content-extractor:steam` (prix FR, avis, annonces et patch notes officiels
  via API, sans le mur cookies de Steam).

Règles anti-blocage :
- YouTube : **un SEUL appel séquentiel** avec plusieurs IDs, jamais de boucle ni de
  `&`, 10 à 15 vidéos max par séance (blocage IP sinon, cf. skill youtube). Sur
  blocage, `yt_extract.py` bascule seul sur NordVPN puis le coupe ; s'il n'y arrive
  pas, demander à Ahmed d'activer NordVPN et relancer (jamais abandonner la vidéo).
- Reddit : le script ne prend que des URL de thread ; une URL de listing/recherche
  passe par le MCP Playwright (voir le skill).
- Webpage : toujours `--no-images --no-screenshot` pour une enquête texte. Un mur de
  cookies (Steam, dust2.us) renvoie du bruit (62 mots ou liste de cookies) : vérifier
  `Contenu : N mots` dans le résumé ; si vide, citer la source via un second canal
  (X, article de presse) et la marquer « primaire non lue ». Avant d'abandonner une page
  primaire, essayer le MCP Playwright (`playwright`, ou `playwright2` si le premier est
  occupé) : Brave avec fenêtre passe la plupart des murs (fiches Gigabyte, UGREEN).
- Recherche YouTube en français : beaucoup de bruit ; commencer par l'anglais et ne
  garder du français que les titres clairement sur le sujet.
- X : `x_post.py URL --quick --no-media` suffit (6 s) ; URL tirée des résultats brave `site:x.com`.
- Une vidéo `VIDÉO INDISPONIBLE` peut venir d'une panne DNS : retester le lot une fois.
- Sorties dans le **scratchpad de session**, jamais dans un vault ou un repo.
- Lire avec `Grep` sur `transcript.full.txt`, `comments.txt`, `page.md` plutôt
  que tout charger.

## 4. Recouper

- Tout chiffre ou affirmation clé : confirmé par **2 sources indépendantes**
  (une vidéo qui cite un communiqué ne compte pas comme indépendante de celui-ci).
- Lire les commentaires : les corrections y vivent.
- Transcription automatique = chiffres et noms propres à confirmer ailleurs.
- Ce qui reste seul ou contredit est marqué **non vérifié**. Aucun guess sur prix,
  versions, règles ; indiquer la date de chaque source.

## 5. Livrable

1. Synthèse courte, point par point, en français, sans verbiage.
2. Tableau des sources : canal | titre/URL | skill utilisé | ce qu'elle apporte.
3. Couverture réelle : nombre d'éléments extraits par canal.
4. Un canal sans résultat est déclaré avec les requêtes essayées, jamais passé
   sous silence. Liste finale de ce qui reste non vérifié.

## Images (règle d'Ahmed)

Si des images ou captures sont gardées ou embarquées : rien de haram (tenue ou pose
suggestive, nudité, fan-service, quel que soit le style). Trier en REGARDANT
l'image (jamais au nom de fichier) ; dans le doute, écarter.
