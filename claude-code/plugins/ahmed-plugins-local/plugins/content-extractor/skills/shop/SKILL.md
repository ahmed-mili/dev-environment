---
name: shop
description: "Use when a French shop product page (Amazon.fr, LDLC, Cdiscount, TopAchat) needs price, stock, seller, specs, reviews or Q&A, or a LDLC product search."
metadata:
  type: reference
---

# Fiche produit marchande : prix, stock, vendeur, specs, avis, Q&A

## Pourquoi ce skill

`webpage.py` rend mal les fiches marchandes (mur de consentement Amazon, pas de prix/vendeur/avis
structurés). Ce skill lit chaque site avec son parseur (JSON-LD quand il existe, DOM sinon) et
écrit des fichiers prêts à `Read`. Lecture seule, **aucune image téléchargée** (règle d'Ahmed : si
un jour des images sont gardées, rien de haram, trier en les regardant).

> [!important] Chemin du script, sinon tu le cherches à l'aveugle
> Les scripts sont dans le sous-dossier **`scripts/` de CE skill**. Construis le chemin à partir
> de la ligne « Base directory for this skill: … » (qui se termine par `…/skills/shop`), pas du
> dossier courant :
>
> ```bash
> python "<SKILL_DIR>/scripts/shop.py" "<url>" --outdir <dossier>
> ```

## Utilisation

```bash
# Fiche + avis (Amazon.fr : /dp/<ASIN> ; LDLC : /fiche/PBxxxx.html ; Cdiscount : .../f-xxxx-code.html ; TopAchat : .../detail2_..._ref_est_inXXXX.html)
python "<SKILL_DIR>/scripts/shop.py" "https://www.amazon.fr/dp/B0DC9LPHY6" --outdir <scratchpad>/shop
# Prioriser les avis négatifs (1 à 3 étoiles sur 5), les plus récents d'abord
python "<SKILL_DIR>/scripts/shop.py" "<url>" --negative --outdir <dossier>
# Recherche (LDLC, Cdiscount, TopAchat) puis fiche de l'URL choisie
python "<SKILL_DIR>/scripts/shop.py" --search "ssd 1 to nvme" --site ldlc
```

Options : `--recent` (tri du plus récent), `--max-reviews N` (40), `--pages N` (pages d'avis Amazon
connecté, 3), `--no-reviews`, `--no-cookies` (Amazon : ignorer la session), `--headed` (fenêtre).
Codes de sortie : 0 ok, **3 bloqué** (captcha / anti-bot / connexion exigée), **4 page non reconnue**
(jamais de faux succès), 2 usage.

### Sortie : `<outdir>/<site>_<id>/`

| Fichier | Contenu |
|---|---|
| `product.md` / `product.json` | titre, marque, référence/GTIN, prix, prix barré, stock, livraison, vendeur, expédié par, note, nb d'avis, specs (tableau), URL canonique, date/heure du relevé, remarques d'extraction |
| `reviews.md` / `reviews.json` | avis : note, date, titre, texte, achat vérifié, utile, source |
| `qa.md` | questions-réponses quand le site les expose |

Le résumé stdout donne prix, note, nombre d'avis écrits et les chemins absolus. **Lire les
« note : » du résumé** : elles disent ce qui manque (échantillon d'avis, pas de session…).

## Ce qui marche par site (testé le 2026-10-17)

| Site | Fiche | Avis | Q&A | Recherche |
|---|---|---|---|---|
| LDLC | complète (JSON-LD + tableau specs) | jusqu'à ~50 via `/avis/PBxxx.html`, notes /10 gardées | non | oui |
| TopAchat | complète (JSON-LD + specs) | ceux du JSON-LD (tous sur les petites fiches) | non | oui (champ de recherche du site) |
| Cdiscount | complète (JSON-LD + texte) | **échantillon** du JSON-LD (5 sur 499) | oui, les plus utiles | oui |
| Amazon.fr | complète | ~8 à 11 avis mis en avant sans connexion ; `/product-reviews/` avec session Brave | **non** (captcha même connecté) | **non** : utiliser `brave-search` `site:amazon.fr/dp` |

## Amazon : session Brave pour les avis et le Q&A

`/product-reviews/` et `/ask/questions/` redirigent vers la connexion. Sans cookies, `shop.py`
extrait les avis de la page produit et le dit dans les notes. Pour avoir tous les avis :

```bash
python "<SKILL_DIR>/scripts/shop_login.py"
```

**Accord permanent d'Ahmed (2026-10-17)** : lancer sans redemander, le dire en une ligne, mais
seulement quand aucun agent n'utilise Brave. Même mécanique que `x_login.py`, elle ferme
**tous** les Brave (aussi celui du MCP Playwright), lit les cookies amazon.fr par DevTools, puis
relance Brave. Cookies dans `%LOCALAPPDATA%\content-extractor\amazon-cookies.json` (hors repo, ne
jamais les afficher). `shop.py` les charge tout seul s'ils existent. Si Amazon les refuse, la note
l'indique et on retombe sur les avis de la page produit.
**Repli** si la session échoue : MCP Playwright (Brave) ou extension `claude-in-chrome` (Chrome
d'Ahmed, déjà connecté), `navigate` sur `https://www.amazon.fr/product-reviews/<ASIN>/?filterByStar=critical&sortBy=recent` puis `get_page_text`.

## Pièges connus (gérés)

- **Consentement cookies** : le bandeau est cliqué (« Refuser », ids Amazon/LDLC/Didomi/OneTrust). Le contenu reste de toute façon dans le DOM ; le vrai problème de `webpage.py` sur Amazon était la lecture, pas le blocage.
- **Captcha / anti-bot** : page quasi vide + marqueur (DataDome, captcha Amazon, Cloudflare, `/ap/signin`) → exit 3 avec message. Relancer avec `--headed`.
- **`--headed`** : la fenêtre est lancée avec les flags anti-occlusion puis **minimisée via CDP** (`Browser.setWindowBounds`), donc jamais au premier plan ; `visibilityState` reste « visible », le focus revient à Ahmed.
- **Amazon double les libellés** (« YUTAO TECH YUTAO TECH ») : dédoublonné. Prix du `.priceToPay`, jamais d'un prix barré.
- **LDLC** : notes sur 10 (converties sur 5 uniquement pour le filtre `--negative`). `/recherche/<q>/` vide = produit absent du catalogue (ex. Wooting 80HE : exit 4).
- **Cdiscount** : l'URL (slug) d'un résultat de recherche peut décrire une autre capacité que le titre : fiez-vous au titre du `product.md`. Prix et variante viennent du JSON-LD de l'offre affichée.
- **TopAchat** : une URL de catégorie erronée (`wm_ssd` au lieu de `w_ssd`) redirige vers l'accueil → exit 4.
- `--negative` ne retombe jamais sur « tous les avis » : s'il n'y a aucun avis négatif disponible, `reviews.md` est vide (c'est une information).

## Limites

- Session Amazon testée le 2026-10-17 (`shop_login.py` : 18 cookies) : `/product-reviews/` marche (`--negative` a sorti les 5 avis critiques du SHUOSUO, absents de la page produit). `/ask/questions/` renvoie un captcha même avec la session : Q&A Amazon non disponible, la note le signale. Amazon renvoie la même page quand `pageNumber` dépasse la dernière : le script s'arrête dès qu'aucun avis n'est nouveau.
- Cdiscount : pas de pagination des avis (échantillon du JSON-LD) ni des questions au-delà des plus utiles.
- LDLC : une seule page d'avis (`/avis/`), pas de pagination au-delà.
- Recherche Amazon impossible par le script ; Cdiscount/TopAchat dépendent du balisage actuel.
- **Savoir si une marque vend un modèle sur Amazon.fr** : jamais conclure « absent » d'une requête `brave-search site:amazon.fr` (erreur du 2026-10-17 : ProtoArc EC300 déclarée absente alors qu'elle était en stock). Ouvrir la **boutique de la marque** (`amazon.fr/stores/<Marque>/page/...`, lien du logo de marque sur une fiche du fabricant) avec le MCP Playwright, puis chercher le modèle dans son champ « Rechercher tout <Marque> ». Passer ensuite chaque `/dp/<ASIN>` trouvé à `shop.py`.
- Autres marchands (Materiel.net, Fnac, Gigabyte, UGREEN…) : skill `webpage` ou MCP Playwright.

## Dépendances (auto-installées)

Python 3.9+, `playwright` (+ Chromium), `beautifulsoup4`, `lxml`.
