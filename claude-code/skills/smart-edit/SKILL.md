---
name: smart-edit
description: Modifie des fichiers de manière fiable en évitant toute erreur de remplacement de chaîne et les hallucinations de variables.
---

# Règle absolue : Réécriture Atomique & Validation

N'utilise JAMAIS Edit ou str_replace directement sur un fichier existant pour des modifications complexes.
La seule méthode autorisée est la suivante :

1. **Read** $\rightarrow$ lire le fichier complet et analyser toutes les variables et fonctions déclarées.
2. **Think & Map** $\rightarrow$ 
   - Appliquer les changements en mémoire.
   - **VÉRIFICATION CRITIQUE** : S'assurer qu'aucune variable inexistante (hallucination) n'a été introduite. Chaque variable utilisée doit être soit déclarée dans le fichier, soit passée en argument (ex: `ctx`, `view`).
3. **Write** $\rightarrow$ réécrire le fichier entier en une seule opération.
4. **Verify** $\rightarrow$ lancer systématiquement le build/lint/test. Si le build échoue, analyser l'erreur et recommencer le cycle Read $\rightarrow$ Think $\rightarrow$ Write.

## Pourquoi ?
- **Lutte contre les erreurs de syntaxe** : Évite les erreurs de type `ReferenceError` (ex: variables mal nommées lors de la reconstruction).
- **Fiabilité de l'indentation** : Évite les échecs de `Edit` dus aux tabulations/espaces.
- **Intégrité du fichier** : Évite les états corrompus dus à des remplacements partiels.

## Exceptions autorisées
Edit est acceptable uniquement si :
- Le fichier fait moins de 20 lignes **ET**
- La modification est limitée à une seule ligne clairement identifiable.

Dans tous les autres cas $\rightarrow$ **Atomic Write + Build Verification obligatoire**.
