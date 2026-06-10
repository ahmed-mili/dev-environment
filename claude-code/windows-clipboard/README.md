# windows-clipboard — image du téléphone → Alt+V dans Claude Code pwsh NATIF

Pendant du dossier `wsl-clipboard/` (qui alimente le presse-papier **Wayland**
pour le Claude **WSL**), ce dossier alimente le presse-papiers **Windows natif**
pour le Claude **pwsh** (vaults Obsidian, sessions zellij ouvertes depuis le
téléphone via le sshd Windows :2222).

## La root cause (prouvée le 2026-06-10)

Le presse-papiers Windows est **par window station**, et chaque connexion SSH
entrante reçoit une window station éphémère (`Service-0x0-<LUID>$`) détruite à
la déconnexion. Conséquences :

- Un `ssh -p 2222 … powershell SetImage` lancé par le téléphone (l'ancien
  « maillon Windows natif » d'`img2claude`) **réussit** (exit 0)… dans un
  presse-papiers fantôme que personne ne lira jamais. Faux positif permanent.
- Le Claude pwsh vit dans la logon session du **serveur zellij** créé par la
  connexion SSH de l'user ; son Alt+V lit (via `powershell
  [Clipboard]::GetImage()`) le presse-papiers de **cette** window station.

**Repro de la preuve** : `SetText('MARKER')` via une connexion ssh :2222 →
readback OK dans sa winsta (`Service-0x0-1a409f8c$`), clipboard **vide** depuis
la session zellij (`Service-0x0-cf9df44$`).

Le seul design qui marche par construction : faire le `SetImage` **depuis la
window station du lecteur**.

## Les pièces

| Fichier | Rôle |
|---|---|
| `img-clip-watcher.ps1` | Watcher (PS 5.1, ASCII pur) : poll `\\wsl.localhost\<distro>\<home>\.claude-images` (1 s), pousse chaque nouvelle image dans le presse-papiers de SA window station. Mutex `Local\img-clip-watcher-<winsta>` (1 par clipboard), meurt avec son ancre (serveur zellij / shell appelant). |
| Wrappers `claude()` / `ollama()` (dans `windows/files/ps7-profile.ps1`) | Lancent le watcher avant le binaire (`claude`) ou avant `ollama launch claude`, via `Invoke-CimMethod Win32_Process Create` : le process échappe au job ConPTY du pane zellij (qui tue son arborescence à la fermeture) tout en gardant le token — donc la window station — de l'appelant. |
| Launchers Bash `ollama-launcher.sh` / `ollama-claude-launcher.sh` | Lancent aussi le watcher avant Claude, pour couvrir `Ctrl+Y` dans Zellij et les shells Bash/Git-Bash qui contournent le profil pwsh. |
| `windows/install.ps1` (étape 2b) | Déploie le watcher vers `~/.local/bin/img-clip-watcher.ps1`. |

## Chaîne complète (3 lecteurs, 1 envoi)

```
téléphone (img2claude) --rsync--> WSL ~/.claude-images/img-<hash>.jpg
    ├── wl-copy image/png            → Alt+V dans Claude WSL
    ├── img-clip-watcher (par winsta) → Alt+V dans Claude pwsh natif (chaque session zellij)
    └── (session interactive : pwsh au PC → wrapper claude() → même watcher → Win+V/Discord)
```

## Pièges appris (ne pas re-tomber dedans)

- **`Local\` ≠ par window station** : le namespace `Local\` des objets nommés
  est par **session Windows** (session 0 entière en SSH). Un mutex `Local\` nu
  bloquait les watchers des autres window stations → le nom du mutex inclut la
  winsta.
- **`Start-Process` depuis un pane zellij** : l'enfant reste dans le job ConPTY
  du pane → tué à la fermeture du pane. `Invoke-CimMethod Win32_Process Create`
  préserve le token/winsta de l'appelant ET échappe au job (vérifié :
  winsta identique loggée au démarrage).
- **PS 5.1 + UTF-8 sans BOM** : lu en CP-1252 ; un tiret cadratin U+2014 devient
  un smart-quote 0x94 qui casse le parse. Le watcher est ASCII pur par contrat.
- **GDI+ ne décode pas WebP** : une image `.webp` est loggée + sautée (la voie
  WSL la gère, elle).
- **WSL/UNC peut tousser** (`Wsl/Service/E_UNEXPECTED`) : le watcher logge
  l'erreur transitoire et continue au lieu de mourir silencieusement.

## Debug

Log : `%TEMP%\img-clip-watcher.log` (démarrages avec winsta, SetImage OK/échec,
sorties). Un `demarrage … winsta=…` qui ne matche pas la winsta du claude visé
= le watcher tourne au mauvais endroit.
