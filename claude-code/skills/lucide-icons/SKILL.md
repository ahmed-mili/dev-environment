---
name: lucide-icons
description: Règle par défaut des icônes d'UI : Lucide (SVG inline) ; MIEUX est permis (décision d'Ahmed, 2026-10-01) — un jeu plus adapté au contexte, ex. Material Symbols Rounded pour une barre de navigation Android native, avec vraies versions pleine/trait. Logos de marque via les sources dédiées (Simple Icons, SVG Repo…). Jamais de caractères Unicode, d'emoji ni d'icônes improvisées. Icônes animées : lucide-animated (React) ou CSS sur le SVG Lucide. Se déclenche quand on parle d'icônes (y compris animées), de logos, de boutons, d'UI, de site web, de web app, ou quand on modifie du HTML/CSS.
---

# Icônes : Lucide par défaut, mieux si mieux existe

Dans tout projet web/app, **toute icône d'interface** utilise **Lucide** en SVG inline **par défaut**.

**Exception assumée (Ahmed, 2026-10-01 : « par défaut c'est Lucide, mais si on peut avoir mieux alors on fait mieux »)** : quand un autre jeu d'icônes COHÉRENT donne un résultat clairement meilleur pour le contexte, on le prend — par exemple **Material Symbols Rounded** (Google, Apache 2.0) pour une barre de navigation Android, parce qu'il a de vraies paires pleine/trait dessinées ensemble et que c'est le langage natif d'Android. Conditions : un seul jeu par zone (pas de mélange dans une même barre), une licence libre, des SVG inline (pas de police d'icônes chargée d'un CDN), et dire dans le commit/la note pourquoi ce jeu est meilleur ici. Jamais d'icônes générées à la main ou par IA pour de l'UI courante.

## Qu'est-ce que Lucide ?

Lucide est une bibliothèque d'icônes open-source (MIT), style line/stroke, cohérente, légère. +1500 icônes. Site : https://lucide.dev/icons

## Format SVG inline obligatoire

Chaque icône doit être insérée directement dans le HTML sous forme de `<svg>` inline. Pas de sprite sheet, pas de CDN, pas de police d'icônes, pas de fichier externe.

### Template SVG Lucide

```html
<svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
  <!-- chemins de l'icône ici -->
</svg>
```

Attributs obligatoires :
- `viewBox="0 0 24 24"` — Lucide utilise un canvas 24×24
- `fill="none"` — icônes line/stroke, jamais filled sauf exception
- `stroke="currentColor"` — hérite de la couleur du parent CSS
- `stroke-width="2"` — épaisseur standard Lucide (1.5 pour icônes très denses)
- `stroke-linecap="round"` — bouts arrondis
- `stroke-linejoin="round"` — jonctions arrondies
- `width` et `height` — adaptés au contexte (16, 18, 20, 24 px)

### Tailles recommandées par contexte

| Contexte | Taille | stroke-width |
|---|---|---|
| Bouton compact (32px) | 15–16 | 2 |
| Bouton normal (40px+) | 18–20 | 2 |
| Titre / hero | 24 | 2 |
| Indicateur de statut inline | 12–14 | 2.5 |
| Icône dans texte | 14–16 | 2 |

## Icônes courantes — Référence rapide

| Usage | Nom Lucide | Chemins SVG |
|---|---|---|
| Ajouter / Créer | Plus | `<path d="M5 12h14"/><path d="M12 5v14"/>` |
| Supprimer | Trash2 | `<path d="M3 6h18"/><path d="M19 6v14c0 1-1 2-2 2H7c-1 0-2-1-2-2V6"/><path d="M8 6V4c0-1 1-2 2-2h4c1 0 2 1 2 2v2"/><line x1="10" y1="11" x2="10" y2="17"/><line x1="14" y1="11" x2="14" y2="17"/>` |
| Fermer / Effacer | X | `<path d="M18 6 6 18"/><path d="m6 6 12 12"/>` |
| Modifier / Renommer | Pencil | `<path d="M17 3a2.83 2.83 0 1 1 4 4L7.5 20.5 2 22l1.5-5.5Z"/><path d="m15 5 4 4"/>` |
| Rechercher | Search | `<circle cx="11" cy="11" r="8"/><path d="m21 21-4.3-4.3"/>` |
| Valider / OK | Check | `<path d="M20 6 9 17l-5-5"/>` |
| Charger / Sync | Loader2 | `<path d="M21 12a9 9 0 1 1-6.219-8.56"/>` |
| Erreur / Alerte | AlertCircle | `<circle cx="12" cy="12" r="10"/><line x1="12" y1="8" x2="12" y2="12"/><line x1="12" y1="16" x2="12.01" y2="16"/>` |
| Déconnexion | LogOut | `<path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4"/><polyline points="16 17 21 12 16 7"/><line x1="21" y1="12" x2="9" y2="12"/>` |
| Flèche retour | ArrowLeft | `<path d="m12 19-7-7 7-7"/><path d="M19 12H5"/>` |
| Chevron bas | ChevronDown | `<path d="m6 9 6 6 6-6"/>` |
| Œil / Voir | Eye | `<path d="M2 12s3-7 10-7 10 7 10 7-3 7-10 7-10-7-10-7Z"/><circle cx="12" cy="12" r="3"/>` |
| Copier | Copy | `<rect width="14" height="14" x="8" y="8" rx="2" ry="2"/><path d="M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2"/>` |
| Lien externe | ExternalLink | `<path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6"/><polyline points="15 3 21 3 21 9"/><line x1="10" y1="14" x2="21" y2="3"/>` |

## Icônes animées

Une micro-animation sert à guider l'attention ou à confirmer une action (copié, envoyé, chargement), jamais à décorer. Source : post @DevDsgn du 2026-10-09, trié le 2026-10-10.

| Projet | Choix | Pourquoi |
|---|---|---|
| React (neo-calendar, opcode…) | **lucide-animated** (https://lucide-animated.com, repo `pqoqubbw/icons`, MIT, ~470 icônes) | Mêmes glyphes que Lucide : la règle « un seul jeu par zone » tient, on peut mélanger statiques et animées. |
| Sans React (HTML/CSS, vanilla, Obsidian sans React) | **CSS sur le SVG Lucide inline** | Zéro dépendance ; `motion` n'existe qu'en React. |

**React** : chaque icône est un item de registre shadcn, `https://lucide-animated.com/r/<nom-kebab>.json` (vérifié le 2026-10-10 : `dependencies: ["motion"]`, fichier `.tsx` dans `files[0].content`).
- Projet avec `components.json` : `npx shadcn@latest add "https://lucide-animated.com/r/copy.json"`.
- Sinon : récupérer le JSON, écrire `files[0].content` dans le projet, remplacer l'import `cn` de `@/lib/utils` par l'utilitaire du projet (ou une simple concaténation de classes), puis `npm i motion`.
- L'icône s'anime au survol de son propre `div`. Pour l'animer au survol du bouton parent, passer une `ref` et appeler `startAnimation()` / `stopAnimation()`.
- Dans un plugin Obsidian, vérifier le poids du bundle après l'ajout de `motion`.

**Sans React** : animer des sous-parties du SVG Lucide inline, au survol du **parent** :

```css
.icon-anim * { transform-box: fill-box; transform-origin: center; transition: transform 120ms ease-in, opacity 120ms ease-in; } /* sortie */
.btn:hover .icon-anim * { transition-duration: 180ms; transition-timing-function: cubic-bezier(.2,.8,.2,1); }   /* entrée */
.btn:hover .icon-anim .part-a { transform: translate(-2px, -2px); }
@media (prefers-reduced-motion: reduce) { .icon-anim * { transition: none; animation: none; } }
```

Règles de mouvement (reprises d'Arc UI, uiarc.dev) :
- n'animer que `transform` et `opacity` ;
- un seul mouvement continu par interaction ;
- une sortie plus rapide que l'entrée ;
- pas de rebond sur un indicateur d'état ;
- toujours une branche `prefers-reduced-motion`.

Écartés (même post) :
- **Lordicon, useanimations, Flaticon animé** : style différent de Lucide (mélange interdit dans une zone), format Lottie ou GIF, attribution exigée par Flaticon.
- **heroicons-animated, hugeicons-animated** : d'autres jeux que Lucide.
- **SVGator** : outil d'animation payant, pas une bibliothèque.
- **allsvgicons** : simple agrégateur.

## Ce qui est INTERDIT

- ❌ Caractères Unicode comme icônes : `+`, `×`, `✎`, `✓`, `↻`, `!`, `✕`, `☰`, `⋯`, `►`, etc.
- ❌ Emojis comme icônes : 🗑️, ✏️, 🔍, ❌, etc.
- ❌ Font Awesome ou autres polices d'icônes (font-awesome, material-icons, ionicons…)
- ❌ Fichiers icônes PNG/SVG externes pour des icônes d'UI simples
- ❌ Images base64 inline pour des icônes existantes dans Lucide

## Ce qui est AUTORISÉ (exceptions)

- ✅ Logos complexes avec couleurs spécifiques (ex: logo Google, logo app) → SVG inline ou image externe
- ✅ Photos/illustrations → `<img>` normal
- ✅ Sprites de personnages/jeux → `<img>` avec fichier dédié
- ✅ Favicons → fichier `.ico`/`.png`/`.svg` externe

## Logos de marque (hors Lucide)

Quand Lucide ne propose pas le logo exact d'une marque, plateforme ou jeu (préférer le SVG inline) :

| Source | Type | URL |
|---|---|---|
| **Simple Icons** | logos de marques uniquement, SVG monochrome | https://simpleicons.org/ |
| **SVG Repo** | icônes + logos SVG (mono & multi-couleur) | https://www.svgrepo.com/ |
| **Iconbuddy** | agrégateur open-source (300k+ icônes) | https://iconbuddy.com/ |
| **PNGFind** | PNG transparent, fallback si SVG introuvable | https://www.pngfind.com/ |

Workflow : Lucide d'abord (UI générique) → Simple Icons / SVG Repo (logo de marque) → Iconbuddy (SVG trop lourd/sale) → PNGFind (fallback PNG). Les logos de marque peuvent être **filled** et colorés, c'est leur identité visuelle — contrairement aux icônes UI Lucide. Pour un logo dans un vault Obsidian → skill `obsidian:brand-icons`.

## Comment trouver une icône Lucide

1. Aller sur https://lucide.dev/icons
2. Chercher par nom ou mot-clé
3. Cliquer sur l'icône → copier le SVG
4. Adapter `width`/`height` au contexte
5. Coller dans le HTML

## Quand un projet n'utilise PAS encore Lucide

Si le projet existe déjà avec d'autres icônes (Unicode, emoji, Font Awesome, etc.) :
1. Lister toutes les icônes utilisées
2. Les remplacer UNE PAR UNE par l'équivalent Lucide
3. Supprimer les dépendances aux anciennes polices d'icônes
4. Nettoyer le CSS qui ciblait les anciennes icônes (font-size, font-family, etc.)
5. Tester que chaque icône s'affiche correctement

## Quand un nouveau projet est créé

- Configurer Lucide dès le premier composant/icône
- Ne jamais introduire de caractère Unicode comme icône, même "en attendant"
- Le premier `+` ou `×` dans un bouton doit déjà être un SVG Lucide