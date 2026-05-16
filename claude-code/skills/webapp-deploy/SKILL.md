---
name: webapp-deploy
description: Règles obligatoires pour tout projet web/app déployé (Firebase Hosting, GitHub Pages, Netlify, Vercel, etc.). Cache-control anti-stale, deployment workflow, et vérifications post-deploy. Se déclenche dès que le projet mentionne Firebase, GitHub Pages, Netlify, Vercel, web app, site web, hébergement, ou hosting.
---

# Règles obligatoires — Web App / Site Web déployé

Ce skill s'applique à TOUT projet déployé sur un hébergeur statique (Firebase Hosting, GitHub Pages, Netlify, Vercel, Cloudflare Pages, etc.). Il est NON NÉGOCIABLE et s'impose à tout modèle IA (Claude, Ollama, GPT, etc.) travaillant sur le projet.

## 1. Cache-Control — Règle absolue

Le cache navigateur est l'ennemi n°1 des déploiements. Un fichier CSS/JS/image servi avec un `max-age` long rend les mises à jour invisibles pendant des jours/semaines sur mobile.

### Configuration Firebase Hosting (`firebase.json`)

```json
"headers": [
  {
    "source": "**/*.@(otf|ttf|woff|woff2)",
    "headers": [
      { "key": "Cache-Control", "value": "public, max-age=31536000, immutable" }
    ]
  },
  {
    "source": "**/*.@(css|js|png|jpg|jpeg|gif|webp|svg|ico)",
    "headers": [
      { "key": "Cache-Control", "value": "public, max-age=0, must-revalidate" }
    ]
  },
  {
    "source": "/index.html",
    "headers": [
      { "key": "Cache-Control", "value": "no-cache, no-store, must-revalidate" }
    ]
  }
]
```

### Configuration GitHub Pages (`.github/workflows/deploy.yml`)

Ajouter les headers via Cloudflare ou un `_headers` file si Netlify, ou via `.htaccess` si Apache. Pour GitHub Pages natif, les headers ne sont pas modifiables — utiliser le cache-busting par query string (`?v=HASH`) dans le HTML.

### Configuration Netlify (`netlify.toml`)

```toml
[[headers]]
  for = "**/*.@(css|js|png|jpg|jpeg|gif|webp|svg|ico)"
  [headers.values]
    Cache-Control = "public, max-age=0, must-revalidate"

[[headers]]
  for = "/index.html"
  [headers.values]
    Cache-Control = "no-cache, no-store, must-revalidate"
```

### Configuration Vercel (`vercel.json`)

```json
{
  "headers": [
    {
      "source": "**/*.@(css|js|png|jpg|jpeg|gif|webp|svg|ico)",
      "headers": [{ "key": "Cache-Control", "value": "public, max-age=0, must-revalidate" }]
    },
    {
      "source": "/index.html",
      "headers": [{ "key": "Cache-Control", "value": "no-cache, no-store, must-revalidate" }]
    }
  ]
}
```

### Raisonnement

| Type de fichier | Cache | Pourquoi |
|---|---|---|
| Polices (otf, woff2…) | 1 an, immutable | Ne changent jamais entre déploiements |
| HTML | no-cache, no-store | Point d'entrée — doit toujours être frais |
| CSS, JS, images | max-age=0, must-revalidate | Vérifie à chaque visite (304 si inchangé, nouveau si modifié) |

**JAMAIS** de `max-age` > 0 pour CSS/JS/images si les noms de fichiers sont fixes (pas de hash dans le nom). Si le projet utilise un bundler avec content-hash (Vite, Webpack, Next.js), `max-age=31536000` est acceptable car chaque build génère un nouveau nom de fichier.

## 2. Déploiement — Workflow obligatoire

Après chaque modification d'un fichier servi en production :

1. **Git** : `git add <fichiers> && git commit -m "<message>" && git push`
2. **Deploy** : lancer la commande de déploiement immédiatement après le push
   - Firebase : `firebase deploy --only hosting --non-interactive`
   - GitHub Pages : push suffit (Actions se déclenche)
   - Netlify : push suffit (auto-deploy)
   - Vercel : push suffit (auto-deploy)
3. **Vérification** : confirmer que le deploy a réussi (URL de confirmation ou sortie CLI)

### Quand déployer automatiquement (sans demander)
- L'utilisateur a validé la modification
- Au moins un fichier servi en prod a changé
- Le code n'est pas cassé

### Quand NE PAS déployer
- Modification de fichiers de config/dev uniquement (`.claude/`, `CLAUDE.md`, `README.md`, etc.)
- L'utilisateur demande explicitement de ne pas déployer
- Le code est cassé ou non testé

## 3. Vérifications post-déploiement

Après chaque déploiement, vérifier mentalement :
- Les headers cache-control sont-ils corrects ? (`curl -sI <url> | grep -i cache`)
- Le site charge-t-il sans erreur ? (pas de 404 sur les assets)
- Le cache navigateur sera-t-il invalidé au prochain chargement ?

## 4. Anti-patterns interdits

- **Interdit** : `max-age=2592000` (30 jours) sur des fichiers avec noms fixes
- **Interdit** : Déployer sans vérifier les headers cache-control
- **Interdit** : Dire "fais Ctrl+F5" comme solution permanente — ça ne marche pas sur mobile
- **Interdit** : Ignorer le cache mobile — Android Chrome et Safari iOS sont plus agressifs que desktop

## 5. Checklist nouveau projet

Quand un nouveau projet web/app est créé, appliquer AVANT le premier déploiement :

- [ ] Configurer les headers cache-control dans le fichier de config hosting
- [ ] Vérifier que `index.html` a `no-cache` ou `no-store`
- [ ] Vérifier que CSS/JS/images ont `must-revalidate`
- [ ] Vérifier que les polices ont `immutable` (si noms de fichiers stables)
- [ ] Tester les headers avec `curl -sI <url> | grep -i cache` après le premier déploiement