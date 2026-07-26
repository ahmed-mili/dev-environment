---
name: obsidian-screenshot
description: "Capture la fenêtre Obsidian (même minimisée ou en arrière-plan) via Win32 PrintWindow, la rafraîchit sans premier plan (via le CLI Obsidian) avant capture, renvoie un PNG à lire pour analyser le rendu réel in-app (-ScrollCapture si long). Seul moyen de voir le rendu natif d'Obsidian, plugins compris. Déclenche sur « montre-moi ce que ça donne », « vérifie le rendu », « screenshot Obsidian », et après toute modif de CSS snippet, callout, Dashboard ou template. Windows uniquement, Obsidian lancé."
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
- **Aucune dépendance à installer** : la capture est en **PowerShell natif**
  (P/Invoke `user32.dll` + `System.Drawing`), lancé via `pwsh` (PowerShell 7).
  Il n'y a **plus de Python** dans la chaîne. Un Python reste installé sur la
  machine (3.12.10 au 2026-07-26), mais l'ancien pipeline pywin32 dépendait d'un
  interpréteur précis et de `packages/` vendorés : il cassait à chaque
  déplacement de l'un ou de l'autre. **Ne pas le ressusciter** — le choix est
  architectural, pas circonstanciel.
- **Rafraîchir / défiler sans premier plan** : `-Refresh`, `-HardReload` et
  `-ScrollCapture` pilotent l'instance en cours via le **CLI officiel d'Obsidian**
  (`Obsidian.com`, bundlé avec l'app desktop, sur le `PATH` — cf. skill `obsidian:cli`)
  et son API JS. Donc **aucun vol de focus** : tout le flux marche en arrière-plan.

## 🎯 Cibler le vault — obligatoire

Ahmed a **plusieurs vaults ouverts en même temps** (typiquement `Personal` et
`Efrei`). Le titre d'une fenêtre Obsidian se lit `<note> - <Vault> - Obsidian X.Y.Z`,
et c'est ce qui identifie la fenêtre.

**Toujours passer `-Vault <nom>`.** Sans lui, si plusieurs vaults sont ouverts, le
script **refuse de capturer** (plutôt que de photographier la mauvaise fenêtre en
silence) et liste les vaults disponibles. C'est volontaire : une capture du mauvais
vault est un piège coûteux — on croit regarder son rendu, on debugge un fantôme.

Même règle que pour le CLI Obsidian (`obsidian vault="Personal" eval …`).

## Commandes (wrapper `.cmd`)

Toutes via `C:\Users\Ahmed\.claude\tools\obsidian-screenshot\obsidian_tools.cmd` :

| Besoin | Commande |
|---|---|
| Lister les fenêtres Obsidian (hwnd + vault + titre) | `obsidian_tools.cmd -Find` |
| Capturer la fenêtre d'un vault (sans focus) | `obsidian_tools.cmd -Vault Personal -Capture -Output "C:\temp\obs.png"` |
| Capturer vers un fichier temporaire | `obsidian_tools.cmd -Vault Personal -Capture` |
| Recharger les snippets CSS (sans focus, instantané) | `obsidian_tools.cmd -Vault Personal -Refresh` |
| Reload complet du renderer (sans focus, ~5 s) | `obsidian_tools.cmd -Vault Personal -HardReload` |
| Capturer un long document en le faisant défiler (arrêt auto) | `obsidian_tools.cmd -Vault Personal -ScrollCapture -ScrollDir "C:\temp\scroll"` |

Sortie de `-Capture` : un PNG (chemin absolu retourné). `-ScrollCapture` produit une
série `scroll_001.png`, `scroll_002.png`, … dans le dossier indiqué (plafond 12,
réglable par `-MaxShots`).

## Workflow standard — vérification visuelle après une modif

1. **Rafraîchir** — souvent inutile (Obsidian recharge tout seul un `.md` modifié sur
   disque). Selon le besoin, et **sans premier plan** :
   - modif de **snippet CSS** → `-Refresh` : recharge les snippets et ré-applique le
     style au DOM en direct (instantané, garde la note ouverte et la position).
   - modif de **plugin / réglage / état récalcitrant** → `-HardReload` : reload complet
     du renderer. Attendre **~5 s** avant de capturer, et **re-ouvrir la note voulue**
     (le workspace est restauré → la feuille active peut changer).
2. **Capturer** : `-Vault <nom> -Capture -Output "<png>"`.
3. **Lire** le PNG avec l'outil `Read` (analyse visuelle).
4. **Commenter** ce qui est visible (layout, couleurs, alignement, débordement…) et
   proposer des ajustements.
5. Itérer si besoin → modifier le fichier → revenir à l'étape 1.

Pour un document long (ex. `Dashboard.md`, un top) : `-ScrollCapture`, puis lire les
PNG dans l'ordre. S'arrête tout seul en fin de document.

## Limite : ce skill ne teste PAS le rendu mobile

`PrintWindow` photographie la fenêtre desktop **à sa taille actuelle**. Il ne dit rien
d'Obsidian **Android/iOS**, où les media queries (`@media (max-width: 600px)`, grilles
de tuiles qui repassent en 2 colonnes…) changent tout.

Pour valider un rendu mobile sans toucher au téléphone : monter un **mock HTML** qui
charge le vrai snippet, le rendre dans **Brave headless** (`C:\Program Files\
BraveSoftware\Brave-Browser\Application\brave.exe` — pas d'Edge ni de Chrome sur cette
machine) ou via le MCP `playwright`, en fixant le viewport (390 px = téléphone), puis
mesurer `scrollWidth > innerWidth` pour détecter un débordement horizontal. Ne pas se
fier au seul `--screenshot` en ligne de commande : il tronque le rendu et fait croire
à un débordement qui n'existe pas (vérifié le 2026-07-14). Mesurer, puis regarder.

## Règles et pièges

- **Toujours `-Vault <nom>`** (voir plus haut). Sans lui + plusieurs vaults = refus.
- **Toujours le wrapper `.cmd`**, jamais le `.ps1` en direct : il fixe l'encodage UTF-8
  (les noms de vaults et de notes contiennent des accents et des `€`).
- **Ne pas supprimer** le PNG après lecture : l'utilisateur peut vouloir le garder pour
  comparaison (avant/après).
- **Obsidian introuvable** (`-Find` échoue) → prévenir : « Obsidian n'est pas détecté,
  vérifie qu'il est lancé. »
- **Screenshot noir** : bug connu de `PrintWindow` sur certains rendus GPU. Le script le
  détecte (échantillonnage) et émet un warning → suggérer de passer Obsidian en fenêtré
  (pas plein écran exclusif).
- **❌ `dev:screenshot` est MORT sur cette machine (revérifié le 2026-07-26)** :
  `obsidian vault="X" dev:screenshot path="…"` sort en **127 sans rien écrire**, et
  `dev:debug on` échoue pareil — donc le contournement CDP documenté le 2026-07-16
  n'est plus applicable, debugger attaché ou non. `obsidian help` liste pourtant les
  deux commandes : leur présence dans l'aide ne prouve rien, seul l'exit code compte.
  **Ne pas repartir dans ce rabbit hole** : `-Capture` est la seule voie fiable, et
  elle produit des frames à jour (validé par `-ScrollCapture`, 3 images distinctes
  dont la fin du document). Et TOUJOURS croiser la capture avec le DOM (`eval` sur
  textContent/getComputedStyle) : le DOM fait foi, pas le pixel.
- **🕐 FRAME PÉRIMÉ après une modif CSS (piège majeur, vécu le 2026-07-14)** : quand la
  fenêtre est en arrière-plan, Chromium **suspend le repaint**. `PrintWindow` renvoie
  alors le **dernier frame peint**, donc *l'ancien style*, alors que le DOM et le CSSOM
  sont déjà à jour. Symptôme : `getComputedStyle()` dit `rgb(101,143,242) underline`
  mais la capture montre encore du texte gris non souligné — on croit son fix cassé et
  on « re-corrige » un CSS qui marchait déjà (boucle garantie).
  **Le DOM fait foi, pas le pixel.** Toujours croiser une capture avec un
  `getComputedStyle()` via le CLI. Pour obtenir une image réellement à jour :
  `-HardReload`, attendre ~8 s, ré-ouvrir la note, puis `-Capture`. Un simple `-Refresh`
  ou un scroll piloté par le DOM **ne suffit pas** à forcer un nouveau frame — sauf à
  couper le throttling d'abord, ce que `-ScrollCapture` fait désormais lui-même
  (`setBackgroundThrottling(false)` avant la série, restauré après).
- **Fenêtre minimisée** : elle est restaurée en `SW_SHOWNOACTIVATE` (sans voler le
  focus), capturée, puis re-minimisée. L'utilisateur ne perd pas sa fenêtre active.
- **`-HardReload` recharge toute la fenêtre** (~5 s, workspace restauré → la feuille
  active peut changer). Pour vérifier une note précise juste après, la ré-ouvrir avant
  de capturer. Pour une simple modif CSS, préférer `-Refresh`.
- **Chemins avec espaces** : guillemets.

## Fichiers du toolkit (Windows)

Dans `%USERPROFILE%\.claude\tools\obsidian-screenshot\` :

- `obsidian_capture.ps1` — **tout le toolkit** : énumération des fenêtres Obsidian et
  résolution du vault par titre, capture `PrintWindow(PW_RENDERFULLCONTENT)`, bornes
  réelles via `DwmGetWindowAttribute` (sans l'ombre), détection de capture noire,
  gestion du minimisé, `-Refresh` / `-HardReload` / `-ScrollCapture` délégués au CLI
  Obsidian (donc sans premier plan).
- `obsidian_tools.cmd` — wrapper batch (UTF-8 + `pwsh`). **Point d'entrée unique.**
  Il résout le `.ps1` par son propre dossier (`%~dp0`), donc le toolkit est
  déplaçable d'un bloc.
- Les anciens `.py` (`obsidian_tools.py`, `window_tools.py`, `packages/` avec pywin32,
  `requirements.txt`) sont **morts**. Ne pas les appeler, ne pas les réparer — le
  `.ps1` les remplace intégralement. Ils survivent encore dans le repo
  `dev-environment/claude-code/tools/obsidian-screenshot/` : leur présence là-bas
  n'est pas un signe qu'il faut y revenir.

> [!warning] Si `obsidian_tools.cmd` est introuvable
> Le toolkit vit **hors du plugin**, dans `~/.claude/tools/`. Jusqu'au
> 2026-07-26, `deploy.ps1` ne synchronisait **pas** `tools/` (seulement
> `statusline.ps1`, `settings.json`, `hooks/`, `skills/`, `device-context`,
> `scripts/`) : le dossier a donc disparu de `~/.claude/` sans que rien ne
> puisse le redéployer, pendant que ce SKILL.md continuait de le décrire.
> `tools/` est depuis géré par `deploy.ps1` dans les deux sens, donc un
> `-Pull` suffit à le rétablir. Si le repo lui-même ne l'a pas :
> `claude-file-recovery` **avant** de recoder de mémoire.
