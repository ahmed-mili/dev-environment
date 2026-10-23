---
name: steam
description: "Use when a Steam game needs its price, store details, user reviews, or official announcements and patch notes, including when the Steam page only shows a cookie wall."
metadata:
  type: reference
---

# Steam : infos, avis et actualités (API publiques)

## Pourquoi ce skill

Les pages `store.steampowered.com` et `steamcommunity.com` renvoient souvent un
mur de cookies / vérification d'âge à `WebFetch`. Les billets officiels (ex. Valve,
CS2, « Side-stepping Skill », 19/08/2024, Snap Tap) et les avis sont pourtant
accessibles par les API publiques de Steam, **sans cookie ni clé**. Le script
`scripts/steam.py` (stdlib seule) les interroge.

> [!important] Chemin du script
> Construis le chemin à partir du **répertoire de base du skill** donné à
> l'invocation (« Base directory for this skill: … », qui se termine par
> `…/skills/steam`), jamais depuis le dossier courant :
>
> ```bash
> python "<SKILL_DIR>/scripts/steam.py" "<jeu_ou_appid>" [options] --outdir <dossier>
> ```
>
> N'utilise jamais un `scripts/…` relatif seul.

## Utilisation

```bash
# Retrouver un billet officiel (le cas CS2 / Snap Tap)
python "<SKILL_DIR>/scripts/steam.py" 730 --news --keyword "snap tap" --since 2024-08-01 --until 2024-09-30 --outdir C:/Users/Ahmed/AppData/Local/Temp/steam

# Prix FR + fiche
python "<SKILL_DIR>/scripts/steam.py" "Elden Ring" --info --outdir C:/Users/Ahmed/AppData/Local/Temp/steam

# Avis récents négatifs en français (3 pages de 50)
python "<SKILL_DIR>/scripts/steam.py" 730 --reviews --lang french --negative --num 50 --pages 3 --outdir C:/Users/Ahmed/AppData/Local/Temp/steam

# Tout (info + avis + actus)
python "<SKILL_DIR>/scripts/steam.py" "Counter-Strike 2" --keyword snap --since 2024-08-01 --outdir C:/Users/Ahmed/AppData/Local/Temp/steam
```

Sans `--info/--reviews/--news` : les trois. Le jeu s'écrit par nom (recherche
magasin, correspondance exacte préférée, sinon candidats listés sur stderr) ou
par appid (plus sûr).

Options : `--cc FR` (pays du prix) ; avis : `--lang french|english|all`,
`--negative|--positive`, `--helpful` (plus utiles, avec `--days`), défaut plus
récents, `--purchase steam|non_steam_purchase|all`, `--num` (max 100),
`--pages` (pagination par cursor) ; actus : `--keyword`, `--since`, `--until`
(AAAA-MM-JJ), `--count`, `--news-pages`.

Sorties dans `<outdir>/<appid>/` : `app.json`, `reviews.md` + `reviews.json`,
`news.md` + `news.json`. Le résumé stdout donne le chemin absolu.

## Endpoints (tous vérifiés)

- `store.steampowered.com/api/storesearch/?term=…&cc=FR&l=french` : nom -> appid.
- `store.steampowered.com/api/appdetails?appids=…&cc=FR&l=french` : fiche + prix.
- `store.steampowered.com/appreviews/<appid>?json=1&…&cursor=*` : avis.
- `api.steampowered.com/ISteamNews/GetNewsForApp/v2/?appid=…&count=100&maxlength=0&enddate=<ts>` : actus.

## Pièges connus

- **Actus : seuls les derniers billets sortent par défaut.** Pour un billet
  ancien, `count` ne suffit pas : le script pagine vers le passé avec
  `enddate` (paramètre vérifié). Donner `--since`/`--until` resserre la
  recherche et évite des dizaines d'appels. `--news-pages` borne l'effort.
- **`maxlength=0`** est indispensable : sinon le contenu est tronqué.
- **BBCode et HTML** dans `contents` (`[h2]`, `[url=…]`, `[list]`, `{STEAM_CLAN_IMAGE}`,
  `<img>`) : nettoyés par le script ; les images sont retirées, jamais enregistrées.
- **Le champ `url` d'un billet** pointe vers `steamstore-a.akamaihd.net/news/externalpost/…`
  (redirige vers la page Steam) : le citer tel quel.
- **Avis : les totaux (score, % positifs) n'existent que pour `review_type=all`.**
  Avec `negative`/`positive`, `query_summary` ne contient que `num_reviews`.
  Le script fait donc un appel de stats séparé (`num_per_page=0`). Ces totaux
  suivent la langue demandée (`--lang`).
- **`cursor=*` obligatoire** pour la première page ; ensuite le `cursor` renvoyé
  (à encoder en URL, il contient `+` et `=`). Une page vide ou un cursor
  identique stoppe la pagination.
- **`day_range`** ne s'applique qu'au tri « plus utiles » (`filter=all`).
- **Heures jouées** : `playtime_at_review` (minutes) est l'heure au moment de
  l'avis ; le script retombe sur `playtime_forever` si absent.
- **Avis non filtrés** : beaucoup d'avis courts, insultes, humour. Ne pas
  généraliser à partir de 3 avis, citer le volume.
- **Prix** : `price_overview` absent pour un jeu gratuit, pas sorti ou retiré
  (le script le dit). `final_formatted` contient le symbole `€` (jamais
  reconstruit à la main). Le prix dépend de `--cc` : toujours FR pour Ahmed.
- **`appdetails` renvoie `success: false`** pour certains jeux restreints ou
  retirés ; le script l'indique au lieu de planter.
- **Limites de débit** : pas de limite documentée ; le script espace les
  appels (1 à 1,5 s) et réessaie sur 429/5xx (5 s, 15 s, 45 s). Ne pas lancer
  plusieurs instances en parallèle.
- **Console Windows** : encodage forcé en UTF-8 comme `yt_extract.py`.

## Après l'extraction

Lire `news.md` / `reviews.md` avec Read ; citer le passage exact avec sa date
et son URL. Pour une page Steam hors API (guides, discussions), voir le skill
`content-extractor:webpage`.
