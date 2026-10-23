---
name: prices
description: "Use when a product's price comparison on LeDénicheur or idealo is needed: offers, lowest real price, shipping, merchant links, price history, or finding the product page."
metadata:
  type: reference
---

# Comparateurs de prix : LeDénicheur et idealo

## Pourquoi ce skill

Les deux comparateurs bloquent le headless (LeDénicheur : défi Cloudflare « Un instant... » ; idealo :
503). Le script pilote donc **Brave avec fenêtre** (profil temporaire jetable, jamais celui d'Ahmed),
la **fenêtre est minimisée via CDP** pour ne jamais rester au premier plan (la page reste `visible`),
et le navigateur est toujours fermé à la fin. Il n'utilise PAS le MCP Playwright : aucun conflit avec
une autre session.

Règle de fond (mémoires d'Ahmed) : jamais de slug ou d'URL deviné, jamais de prix inventé ; un lien
n'est bon que si le bon produit apparaît AU CONTENU de la page.

## Utilisation

> [!important] Chemin du script
> Construis-le depuis le **répertoire de base du skill** (ligne « Base directory for this skill: … »,
> terminant par `…/skills/prices`), pas depuis le dossier courant :
>
> ```bash
> python "<SKILL_DIR>/scripts/prices.py" "<url produit>" --outdir <dossier>
> ```

```bash
# Offres + historique d'une page produit (LeDénicheur product.php?p=NNN ou idealo /prix/NNN/nom.html)
python "<SKILL_DIR>/scripts/prices.py" "https://www.idealo.fr/prix/202132303/samsung-990-pro-1-to.html" --outdir C:/Users/Ahmed/AppData/Local/Temp/pr

# Trouver les pages produit d'un nom (recherche du site rendue dans le navigateur, vérifiée au contenu)
python "<SKILL_DIR>/scripts/prices.py" --find "Samsung 990 Pro 1 To" --outdir C:/Users/Ahmed/AppData/Local/Temp/pr
python "<SKILL_DIR>/scripts/prices.py" --find "Wooting 80HE" --site ledenicheur --limit 5 --outdir ...

# Options : --no-history (offres seules), --no-series (LeDénicheur : pas de survol du graphique, plus rapide),
#           --resolve-links (idealo : URL marchand finale au lieu du lien clickout)
```

Codes de sortie : `0` ok, `2` blocage anti-bot / captcha (rien n'est écrit comme valide), `3` page
disparue, `1` autre erreur. Un produit sans aucune offre n'est pas une erreur : `offers.json` porte
`no_offers_listed: true` et un avertissement est imprimé.

### Sortie

Dans `<outdir>/<site>_<id>/` : `offers.json` + `offers.md` (nom exact, offres : marchand, titre, prix, frais de
port, total livré, stock, lien ; prix le plus bas, nombre d'offres, date/heure du relevé), puis
`history.json` + `history.md` (3 mois, 6 mois, 1 an : actuel, min, max, tendance, points journaliers).
`--find` écrit `find_<nom>.json`. Aucune image n'est téléchargée.

## Ce que chaque site expose

| | LeDénicheur | idealo |
|---|---|---|
| Recherche | `ledenicheur.fr/search?query=...` (paramètre `query`, pas `search` ni `q`) | `idealo.fr/prechcat.html?q=...` |
| Page produit | `ledenicheur.fr/product.php?p=NNN` | `idealo.fr/prix/NNN/<nom>.html` |
| Offres | DOM : `[data-test=OfferListItem]`, nom du marchand = `alt` du logo | DOM : `li.productOffers-listItem` + JSON-LD `AggregateOffer` (recoupement) |
| Lien marchand | clickout `ledenicheur.fr/go-to-shop/<shop>/offer/<ref>` | clickout `idealo.fr/relocator/relocate?...` (`--resolve-links` tente la redirection) |
| Frais de port | calculés par la bascule « Prix livraison incluse » (différence) | affichés (« X € livraison incl. ») |
| Historique | graphique recharts : événements `mousemove` synthétiques sur chaque point (info-bulle : date, prix, marchand), 1 an en ~6 s | JSON propre : `/price-chart/sites/4/products/NNN/history?period=3M\|6M\|1Y` (centimes) |

## Workflow recommandé

1. Nom connu sans URL : `--find`, prendre les URLs marquées `OK vérifié`, jamais une URL non vérifiée.
2. Lancer le script sur chaque URL, lire `offers.md` (puis `history.md` si besoin).
3. Pour un top hardware : croiser les deux sites (convention d'Ahmed : LeDénicheur puis idealo), confirmer
   le prix retenu sur la fiche marchand (skill `content-extractor:shop`), citer la date du relevé.

## Pièges connus (déjà gérés)

- **LeDénicheur `/search?search=` ou `?q=`** : « Nous n'avons pas trouvé "" » (paramètre ignoré). Le bon est `query`.
- **Headless** : Cloudflare « Un instant... » (LeDénicheur) et 503 (idealo). D'où le navigateur avec fenêtre minimisée.
- **idealo `/prechcat.html`** : la page contient aussi des carrousels de produits sans rapport (PS5, iPhone) ;
  `--find` ne garde que les liens dont le nom contient tous les mots recherchés.
- **Vraie souris sur le graphique** : ~1 s par point en fenêtre minimisée (1 an = 6 min) ; les événements
  synthétiques dans la page donnent les mêmes valeurs en quelques secondes.
- **Minimiser une fenêtre** : seul `Browser.setWindowBounds` en `minimized` via CDP marche (`--start-minimized`
  et `--window-position` sont sans effet ; idealo passe toujours fenêtre minimisée, vérifié le 2026-10-17), avec les 4 drapeaux anti-throttling du script.
- **Boutons « Voir toutes les offres (N) » (LeDénicheur) et « Afficher plus d'offres » (idealo)** : cliqués avec
  des délais généreux ; avec un délai court, la liste reste tronquée (6 sur 17, 20 sur 24).
- **Min/Max affichés par LeDénicheur** : le texte « Min / Max » suit toujours la tendance 3 mois, même si on
  sélectionne 1 an ; les min/max 6 mois et 1 an viennent donc de la série survolée.
- **Prix de LeDénicheur vs idealo** : deux listes de marchands différentes, donc des min d'historique différents.
  Normal, d'où le croisement.

## Limites (constatées le 2026-10-17)

- **Navigateur avec fenêtre obligatoire** : sans Brave/Chrome/Edge installé, le script s'arrête.
- **Wooting 80HE** : idealo ne référence pas le produit (la recherche ne renvoie que des accessoires) ;
  sur LeDénicheur les pages existent mais sans aucun marchand en stock à la date du test (Wooting vend en direct).
  Le script le dit (`no_offers_listed`), l'historique reste lisible.
- **LeDénicheur, groupe « Offres sans lien direct »** : marchands non partenaires, repliés ; seul leur prix
  « Dès X € » est relevé (`unlinked_group_from_price`), pas le détail.
- **idealo** : toutes les offres listées sont des offres en stock ; le champ stock vaut « En stock (offre listée) ».
  Les offres d'occasion ou d'autres variantes ne sont pas mélangées (une page = une variante).
- **LeDénicheur, séries** : un point par jour (3 mois = 91, 1 an = 366) ; `--no-series` les supprime (min/max
  3 mois seulement). Un relevé complet dure ~1 min (navigateur + 3 périodes), idealo ~30 s.
- **Pas de recherche via MCP brave-search depuis le script** : si `--find` ne trouve rien (site bloqué ou produit
  absent), passer par le MCP `brave-search` depuis la session avec `site:ledenicheur.fr` ou `site:idealo.fr/prix`,
  puis vérifier l'URL avec ce script.

## Dépendances (auto-installées)

- Python 3.9+, `playwright` ; navigateur : Brave (`C:/Program Files/BraveSoftware/...`), sinon Chrome ou Edge.
