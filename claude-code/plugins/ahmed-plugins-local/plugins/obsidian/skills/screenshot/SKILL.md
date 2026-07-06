---
name: obsidian-screenshot
description: "Capture la fenêtre Obsidian (même minimisée ou en arrière-plan) via Win32 PrintWindow, la rafraîchit sans premier plan (via le CLI Obsidian) avant capture, renvoie un PNG à lire pour analyser le rendu réel in-app (--scroll-capture si long). Seul moyen de voir le rendu natif d'Obsidian, plugins compris. Déclenche sur « montre-moi ce que ça donne », « vérifie le rendu », « screenshot Obsidian », et après toute modif de CSS snippet, callout, Dashboard ou template. Windows uniquement, Obsidian lancé."
---

# Capturer le rendu réel d'Obsidian (Win32)

## Pourquoi ce skill existe

L'export PDF, le HTML ou une preview ne montrent pas le **rendu natif d'Obsidian**
(thème actif, snippets CSS, plugins comme Dataview/Templater, Dashboard, canvas).
Pour itérer sur du design ou vérifier qu'une modif rend bien *dans l'app*, il faut
photographier la vraie fenêtre Obsidian. Ce skill le fait via Win32 `PrintWindow`
(`PW_RENDERFULLCONTENT`), donc **même si Obsidian est derrière une autre fenêtre ou
minimisé** — pas besoin de le mettre au premier plan ni d'interrompre l'utilisateur.

## Prérequis

- **Windows 10/11** (Win32 uniquement) et **Obsidian lancé** (`Obsidian.exe`).
- Le toolkit est auto-hébergé dans `C:\Users\Ahmed\.claude\tools\obsidian-screenshot\`
  (pywin32 vendoré dans `packages/`, pas de dépendance WSL). **Toujours** passer par
  le wrapper `.cmd` — il configure `PYTHONPATH`/`PATH` (DLLs pywin32) et l'encodage
  UTF-8, et appelle le bon interpréteur Python. Ne jamais lancer `python.exe`
  directement sur les scripts.
- **Rafraîchir / défiler sans premier plan** : `--refresh`, `--hard-reload` et
  `--scroll-capture` pilotent l'instance Obsidian en cours via le **CLI officiel
  d'Obsidian** (`Obsidian.com`, bundlé avec l'app desktop, sur le `PATH` — cf. skill
  `obsidian:cli`) et son API JS. Donc **aucun vol de focus** : comme la capture, tout
  le flux marche même Obsidian en arrière-plan. Si le CLI est indisponible, repli
  automatique sur les frappes clavier (qui, elles, exigent le premier plan).

## Commandes (wrapper `.cmd`)

Toutes via `C:\Users\Ahmed\.claude\tools\obsidian-screenshot\obsidian_tools.cmd` :

| Besoin | Commande |
|---|---|
| Vérifier qu'Obsidian est détecté (hwnd + dimensions) | `obsidian_tools.cmd --find` |
| Capturer la fenêtre entière (sans focus) | `obsidian_tools.cmd --capture --output "C:\temp\obsidian.png"` |
| Capturer vers un fichier temporaire | `obsidian_tools.cmd --capture` |
| Recharger les snippets CSS (sans focus, instantané) | `obsidian_tools.cmd --refresh` |
| Reload complet du renderer (sans focus, ~5 s) | `obsidian_tools.cmd --hard-reload` |
| Capturer un long document en le faisant défiler (sans focus, arrêt auto) | `obsidian_tools.cmd --scroll-capture --scroll-dir "C:\temp\scroll"` |

Sortie de `--capture` : un PNG (chemin absolu retourné). `--scroll-capture` produit
une série `scroll_001.png`, `scroll_002.png`, … dans le dossier indiqué (plafond 12).

## Workflow standard — vérification visuelle après une modif

1. **Rafraîchir** — souvent inutile (Obsidian recharge tout seul un fichier `.md`
   modifié sur disque). Selon le besoin, et **sans premier plan** :
   - modif de **snippet CSS** → `--refresh` : recharge les snippets, ré-applique le
     style au DOM en direct (instantané, garde la note ouverte et la position).
   - modif de **plugin / réglage / état récalcitrant** → `--hard-reload` : reload
     complet du renderer. Attendre **~5 s** avant de capturer, et **re-ouvrir la note
     voulue** (le workspace est restauré → la feuille active peut changer).
2. **Capturer** : `--capture --output "<png>"`.
3. **Lire** le PNG avec l'outil `Read` (analyse visuelle).
4. **Commenter** ce qui est visible (layout, couleurs, alignement, débordement…) et
   proposer des ajustements.
5. Itérer si besoin → modifier le fichier → revenir à l'étape 1.

Pour un document long (ex. `Dashboard.md`, un top) : `--scroll-capture` (défilement
piloté par le CLI Obsidian, **sans premier plan**), puis lire les PNG dans l'ordre.
S'arrête tout seul en fin de document ; plafonné à 12 captures.

## Règles et pièges

- **Toujours le wrapper `.cmd`** (jamais `python.exe` en direct) — sinon pywin32 ne
  se charge pas.
- **Ne pas supprimer** le PNG après lecture : l'utilisateur peut vouloir le garder
  pour comparaison (avant/après).
- **Obsidian introuvable** (`--find` échoue) → prévenir : « Obsidian n'est pas
  détecté, vérifie qu'il est lancé. »
- **Screenshot noir** : bug connu de `PrintWindow` sur certains rendus GPU → le
  signaler et suggérer de passer Obsidian en fenêtré (pas plein écran exclusif).
- **`--hard-reload` recharge toute la fenêtre** (~5 s, workspace restauré → la feuille
  active peut changer). Pour vérifier une note précise juste après, la ré-ouvrir
  (`obsidian://open?vault=…&file=…` ou `obsidian` CLI) avant de capturer. Pour une
  simple modif CSS, préférer `--refresh` (instantané, ne perd pas l'état).
- **CLI Obsidian requis pour refresh/scroll sans focus** : si `Obsidian.com` n'est pas
  sur le `PATH`, ces commandes basculent sur le clavier et exigent alors le premier
  plan (un message `ℹ️` le signale dans la sortie).
- **Chemins avec espaces** : guillemets (et `\\` en contexte PowerShell).

## Fichiers du toolkit (Windows)

- `window_tools.py` — logique Win32 générique (`find_window_by_process`,
  `capture_window`, `focus_window`, `send_keys_ctrl_r`, `send_keys_page_down`,
  `scroll_mouse_down`) — sert de **repli clavier** si le CLI Obsidian manque.
- `obsidian_tools.py` — CLI spécifique Obsidian (`--capture`, `--output`,
  `--refresh`, `--hard-reload`, `--find`, `--scroll-capture`, `--scroll-dir`).
  Refresh, hard-reload et scroll passent par le CLI Obsidian (`_obsidian_eval` →
  `Obsidian.com eval`), donc **sans premier plan** ; repli clavier via `window_tools`.
- `obsidian_tools.cmd` — wrapper batch (PYTHONPATH + DLLs pywin32 + UTF-8) qui lance
  le script. **Point d'entrée unique.**
- `requirements.txt` — `pywin32`, `psutil`, `numpy`, `opencv-python` (déjà vendorés
  dans `packages/`).
