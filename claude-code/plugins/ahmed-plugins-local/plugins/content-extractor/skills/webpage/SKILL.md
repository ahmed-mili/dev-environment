---
name: webpage
description: "Use when a webpage needs full structured content and a visual capture, especially for JavaScript or anti-bot sites."
metadata:
  type: reference
---

# Extraction complète d'une page web (markdown + mise en forme + screenshot)

## Pourquoi ce skill

Beaucoup de pages sont rendues en JavaScript ou protégées par un anti-bot :
`WebFetch` / un fetch simple renvoie alors une coquille vide ou un 403, et un modèle
qui improvise une méthode finit par planter. Ce skill donne **une méthode
déterministe** : un vrai Chromium (Playwright) rend la page, on isole le contenu
principal (readability) et on le convertit en **markdown qui garde la mise en forme**
(titres, **tableaux**, listes, gras, liens). On capture aussi la page **en entier**
(PNG) pour le layout visuel.

Complémentaire à `defuddle` (readability simple, sans navigateur) : ici on gère en
plus les sites JS/anti-bot, le screenshot et les images.

## Première solution : le MCP Playwright (consigne d'Ahmed, 2026-10-16)

Pour **lire** une page (prix, fiche, annonce, liste), essayer d'abord le **MCP Playwright**
(navigateur Brave avec fenêtre) : c'est l'outil qui passe presque partout. Vérifié le
2026-10-16 sur Etsy (DataDome) et sur un listing Reddit (`js_challenge`), là où le script
ci-dessous, freeweb et fetch échouaient ou renvoyaient une archive.

1. Charger en un appel : `select:mcp__playwright__browser_navigate,mcp__playwright__browser_evaluate,mcp__playwright__browser_snapshot,mcp__playwright__browser_tabs`.
2. `browser_navigate` vers l'URL, puis `browser_evaluate` avec
   `() => document.body.innerText` (texte complet) ou une fonction ciblée ; `browser_snapshot`
   pour la structure et les boutons.
3. Fermer **ses** onglets avec `browser_tabs` `close` : le Brave du MCP est partagé avec
   d'autres sessions.

Garder le **script** ci-dessous quand il faut des **fichiers** (markdown fidèle avec tableaux,
capture pleine page, images téléchargées), ou en secours si le MCP n'est pas connecté.

## Utilisation du script

> [!important] Chemin du script — sinon tu le cherches à l'aveugle
> Le script est dans le sous-dossier **`scripts/` de CE skill**. Construis le chemin
> depuis le **répertoire de base du skill** (la ligne « Base directory for this
> skill: … », terminant par `…/skills/webpage`), pas depuis le dossier courant :
>
> ```bash
> python "<SKILL_DIR>/scripts/webpage.py" "<url>" --outdir <dossier>
> ```

Exemples :

```bash
# Page complète (markdown + mise en forme + screenshot + images)
python "<SKILL_DIR>/scripts/webpage.py" "https://www.tomshardware.com/reviews/best-gpus,4380.html" --outdir C:/Users/Ahmed/AppData/Local/Temp/cr

# Toute la page, pas seulement le contenu principal readability (utile si la page n'est pas un article)
python "<SKILL_DIR>/scripts/webpage.py" "<url>" --full --outdir C:/Users/Ahmed/AppData/Local/Temp/cr

# Sans télécharger les images / sans capture (plus rapide)
python "<SKILL_DIR>/scripts/webpage.py" "<url>" --no-images --no-screenshot --outdir C:/Users/Ahmed/AppData/Local/Temp/cr
```

### Ce que ça produit

Dans `<outdir>/<domaine>_<slug>/` :

| Fichier | Contenu |
|---|---|
| `page.md` | **Markdown structuré** : titres, **tableaux**, listes, gras, liens — images en chemins locaux. C'est le fichier à lire/`Grep`. |
| `page.txt` | Texte brut du contenu principal |
| `page.html` | HTML du contenu principal (nettoyé) — pour la structure exacte |
| `page.png` | **Capture PLEINE PAGE** — le layout visuel, **lisible avec l'outil `Read`** |
| `meta.json` | titre, auteur, date, description, langue, URL, nb de mots/images |
| `images/` | les images du contenu, téléchargées |

## Workflow recommandé

1. **Lance le script.** Lis `page.md` (ou `Grep` dedans) pour le contenu + la structure.
2. **Mise en page visuelle** (colonnes, encadrés, ce que readability a pu rater) : `Read` la `page.png`.
3. **Tableau à reproduire** : il est déjà en markdown dans `page.md` ; sinon vois `page.html`.

## Pièges connus (déjà gérés)

- **403 / JS** : un vrai Chromium rend la page (c'est tout l'intérêt vs `WebFetch`).
- **Lazy-loading** : le script scrolle toute la page avant de capturer, pour déclencher le chargement des images et sections différées.
- **Page non-article** : readability peut trop rogner ; le script bascule alors automatiquement sur le `<body>` complet (ou force-le avec `--full`).
- **Tableaux en `<div>`** (pas en `<table>`) : ne deviennent pas des tableaux markdown ; la `page.png` les rend visuellement.

## Limites connues (non contournées, constatées le 2026-10-16)

- **Etsy** : mur anti-bot DataDome (`geo.captcha-delivery.com`), la page ne contient que
  2 mots ; `fetch`, WebFetch et Playwright prennent un 403. **Contournement qui marche** :
  l'extension Chrome (`claude-in-chrome`) avec le Chrome d'Ahmed, `navigate` puis
  `get_page_text` sur l'annonce : prix par variante, dimensions, délais, avis, tout passe
  (vérifié le 2026-10-16 sur l'annonce 1358456250). Le MCP **Playwright** (Brave, avec
  fenêtre) passe aussi et rend la vraie page. **freeweb** ne renvoie qu'une copie
  web.archive.org (celle de février 2026 ce jour-là) : données possiblement périmées.
- **Amazon.fr, LDLC, Cdiscount, TopAchat** : utiliser le skill `content-extractor:shop`
  (fiche, prix, vendeur, avis, Q&A). Sur Amazon.fr, ce script ne rend que le mur de
  consentement cookies (constaté le 2026-10-17 sur une fiche `/dp/`) ; la recherche `/s?k=`
  est inexploitable ; avis complets et Q&A exigent une connexion (session Brave via `shop`).
- **Fiches constructeur Gigabyte, UGREEN** : même mur cookies (2026-10-17) ; passer par le
  MCP Playwright.
- **eBay** : une annonce retirée renvoie une page « Something went wrong » (24 mots) : ce
  n'est pas un blocage, l'annonce n'existe plus.
- **Sites Shopify** (ex. kqueo.fr, maxesport.gg) : si la page rend peu de texte, l'API publique
  `/products/<handle>.json` (ou `.js`) donne prix, variantes et description.

## Dépendances (auto-installées)

- Python 3.9+, `playwright` (+ Chromium), `readability-lxml`, `markdownify`, `lxml`.
