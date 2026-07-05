---
name: css-layout-check
description: "Vérifie les conflits CSS après une restructuration HTML/CSS — sélecteurs morts, règles dupliquées ou conflictuelles, propriétés qui s'écrasent. À utiliser après tout changement de structure HTML (renommage, déplacement, suppression d'éléments) ou ajout de règles pour des classes existantes. Déclencheurs — refactor HTML/CSS, changement de layout, restructuration de composants."
---

# Vérification CSS post-restructuration

Chaque fois que le HTML ou le CSS est restructuré (éléments déplacés, renommés, supprimés, ou nouvelles règles ajoutées pour des classes existantes), exécuter cette vérification **avant** de déployer.

## Étapes obligatoires

### 1. Détecter les sélecteurs CSS morts

Pour chaque classe CSS définie dans les fichiers CSS du projet, vérifier qu'elle est référencée dans au moins un fichier HTML/JS. Si ce n'est pas le cas, c'est du CSS mort qui peut créer des conflits silencieux.

Utiliser Grep pour chercher chaque nom de classe CSS dans les fichiers HTML/JS. Les classes qui n'apparaissent que dans le CSS sont suspectes.

### 2. Détecter les règles dupliquées ou conflictuelles

Pour chaque sélecteur CSS qui apparaît **plusieurs fois** dans les fichiers CSS, comparer les propriétés :
- Si deux blocs définissent les **mêmes propriétés** pour le même sélecteur, le second écrase le premier → **conflit silencieux**.
- Si les propriétés sont **différentes** mais le sélecteur est le même, les deux blocs fusionnent silencieusement → **comportement inattendu** si un bloc ancien contient des propriétés non voulues (ex: `display: flex`).

Cas particulier dangereux : un ancien sélecteur avec `display: flex` ou `display: grid` qui écrase un layout `display: block` par défaut.

### 3. Vérifier la cohérence HTML ↔ CSS

Après une restructuration :
- Lister toutes les classes utilisées dans le HTML
- Lister toutes les classes définies dans le CSS
- Signaler toute classe HTML sans règle CSS correspondante (OK pour les utilitaires, suspect pour les classes de layout)
- Signaler toute classe CSS sans utilisation HTML (CSS mort)

### 4. Vérifier les changements de structure

Quand un élément HTML change de parent ou de conteneur (ex: passage d'un div flex unique à 3 divs séparés), vérifier :
- Le nouveau conteneur n'hérite pas accidentellement de styles flex/grid de l'ancien
- Les `margin`, `gap`, `padding` des anciens conteneurs ne s'appliquent plus aux nouveaux enfants
- Les `order` CSS flex ne créent pas d'ordre inattendu dans le nouveau layout

## Format du rapport

Afficher les résultats en 3 sections :

**⚠️ Conflits** — Sélecteurs dupliqués avec propriétés conflictuelles. Toujours corriger avant de déployer.

**🗑️ CSS mort** — Classes définies en CSS mais jamais utilisées en HTML. Supprimer sauf si intentionnel (utilitaires, états dynamiques ajoutés par JS).

**✅ OK** — Tout le reste, pas d'action nécessaire.

## Quand déclencher cette vérification

- Après avoir renommé/déplacé/supprimé des éléments HTML
- Après avoir ajouté de nouvelles règles CSS pour des classes qui existent déjà
- Après avoir restructuré un layout (passage de 1 ligne à 3 lignes, etc.)
- Après avoir changé un conteneur parent (div → div imbriqués, etc.)
- Quand le rendu visuel ne correspond pas à ce qui est attendu

## Ce que cette vérification a déjà évité

Bug réel : `.dt-header { display: flex }` (ancien CSS pour un header titre+icône, plus utilisé) coexistait avec `.dt-header { margin-bottom: 0.85rem }` (nouveau CSS pour un conteneur 3 lignes). Le `display: flex` ancien forçait les 3 lignes sur une seule, car les `div` enfants devenaient des flex items au lieu de blocs. Sans cette vérification, le bug est invisible dans le code — il faut inspecter visuellement pour le voir.