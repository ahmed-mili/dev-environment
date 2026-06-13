# CLAUDE.md — dev-environment

Conventions spécifiques à ce repo. S'applique en plus du `CLAUDE.md` global user-level.

---

## 🎯 Objectif

Repo **partageable** — 1 commande copy-pastable depuis le README pour cousins/frères/amis. Aucune valeur personnelle ne doit figurer dans un fichier versionné.

---

## 🛑 Règles d'or

### 1. Aucune valeur perso codée en dur

Dans un fichier versionné du repo, **jamais** de nom, hostname, IP, email, ou identifiant personnel en dur. Exemples interdits :
- `<prenom-perso>` comme nom d'utilisateur
- `<hostname-perso>` comme hostname
- Une IP Tailscale en dur

**Parade** :
- Dériver dynamiquement : `$USER`, `whoami`, `getprop`, `$env:USERNAME`
- Externaliser dans `~/.bashrc.local` (non versionné)
- Lire depuis l'environnement au runtime

### 2. Cross-platform explicite

Chaque script/chemin doit indiquer sa plateforme cible :
- `windows/` → PowerShell 7+, Windows Terminal, `C:\dev`
- `android/` → Termux (bash), `~/storage`, libellés Xiaomi/HyperOS obligatoires
- `claude-code/` → config Claude Code (statusline, settings, hooks, skills)

Pas de chemin Linux dans un script Windows, et inversement.

### 3. ASCII-only dans les scripts PowerShell

Les fichiers `.ps1` doivent rester **ASCII-only** (pas de BOM UTF-8 non plus). Raison : Windows PowerShell 5.1 lit les `.ps1` en CP-1252 quand aucun BOM n'est présent. Les séquences multi-octets UTF-8 (émojis, flèches, etc.) deviennent des smart-quotes qui cassent le parser. Les commentaires et les chaînes affichées passent par des variables de couleur `[Console]::Write` ou des codes d'échappement `[char]27`, jamais par des glyphes littéraux.

### 4. Idempotence

Tout script d'installation (bootstrap, setup, deploy) doit pouvoir être relancé sans effet de bord. Vérifier l'existence avant de créer, nettoyer avant de remplacer.

### 5. Non-régression sur le téléphone

Tout changement côté desktop qui touche au pipeline téléphone→desktop (img2clip, screenshot-watcher, clip-watcher) doit être testé sur les 3 sources :
- Screenshot PC (`Win+Shift+S`)
- Screenshot téléphone
- Photo téléphone (appareil photo)

---

## 📂 Structure

```
dev-environment/
├── windows/        # PowerShell 7, Windows Terminal, Fastfetch, Rust statusline
│   └── files/
├── android/        # Termux bash, Ubuntu-style prompt, fastfetch, ssh-client
│   └── setup-ssh-client.sh
├── claude-code/    # Config Claude Code (statusline, settings, hooks, skills)
│   ├── termux/img2clip      # push image téléphone → desktop
│   ├── deploy.ps1             # sync repo ↔ ~/.claude/ (Windows)
│   └── skills/
├── bootstrap.ps1   # one-liner Windows (idempotent, 8 étapes)
├── bootstrap.sh    # one-liner Android (auto-detect legacy → migrate)
└── README.md       # commande copy-pastable publique
```

---

## 🔧 Patterns récurrents

### `deploy.ps1` / `deploy.sh`

Bidirectionnel (repo ↔ `~/.claude/`). Whitelist explicite des fichiers trackés. Le reste de `~/.claude/` (sessions, history, plugins officiels, credentials) est laissé intact.

### `img2clip` — règle à 2 lecteurs

Pipeline téléphone → desktop :
1. **Dépôt fichier** (`rsync`/`scp`) dans `~/.claude-images`
2. **Windows natif** (`img-clip-watcher.ps1`) : pour Claude Code pwsh natif

Le presse-papiers Windows **ne doit plus** être alimenté par `ssh -p 2222 ... SetImage` depuis `img2clip` : ce SetImage écrit dans la window station éphémère de la connexion SSH et renvoie un faux succès. Le bon design est local au lecteur : le wrapper `claude()` du profil pwsh lance `img-clip-watcher.ps1` dans la même window station que Claude, et ce watcher lit `%USERPROFILE%\.claude-images`.

---

## 📝 Quoi commiter

| Doit être versionné | Ne doit PAS être versionné |
|---------------------|---------------------------|
| Scripts, configs, skills | `~/.bashrc.local`, secrets, IPs perso |
| README avec one-liner public | Logs, sessions, history Claude |
| `.gitignore` adapté | Fichiers générés (binaires, cache) |

---

## 🧪 Checklist avant push

- [ ] `grep -rE "<prenom-perso>|<hostname-perso>|<ip-perso>" --include="*" .` → aucun match dans un fichier versionné (sauf commentaire documentant le pourquoi)
- [ ] `deploy.ps1 -Pull` (ou `-Push`) testé
- [ ] img2clip testé sur les 3 sources (PC screenshot, tel screenshot, tel photo)
- [ ] Pas de caractère non-ASCII dans un `.ps1`
