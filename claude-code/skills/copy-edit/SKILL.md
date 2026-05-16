---
name: copy-edit
description: Prépare un bloc de remplacement précis et copie le résultat dans le presse-papier Windows.
---

Ce skill est utilisé pour fournir uniquement le bloc de code spécifique à remplacer, évitant ainsi d'envoyer des fichiers complets et facilitant l'application manuelle.

## Processus d'exécution :

1. **Analyse** : Lire le fichier cible pour identifier précisément les lignes à modifier.
2. **Isolation** : Extraire le bloc de code actuel (Old String) et préparer le bloc de remplacement (New String).
3. **Export Robuste (MÉTHODE FORCÉE)** : 
   - Écrire le bloc de remplacement dans un fichier temporaire (ex: `.claude/temp_clip.txt`).
   - Utiliser la commande `clip < ".claude/temp_clip.txt"` pour envoyer le contenu au presse-papier Windows.
   - Supprimer le fichier temporaire.

## Instructions pour Claude :

- Ne propose JAMAIS le fichier entier avec ce skill.
- Le résultat doit être UNIQUEMENT le bloc de code à coller.
- **INTERDICTION ABSOLUE** d'utiliser `echo "..." | clip`. Cette méthode échoue avec les caractères spéciaux et les retours à la ligne.
- **OBLIGATION** d'utiliser la redirection de fichier : `clip < "chemin/du/fichier"`.
- **Surtout, accompagne TOUJOURS l'envoi au presse-papier d'une réponse texte indiquant précisément :**
    - Le fichier concerné.
    - Les numéros de lignes à remplacer.
    - Le bloc de code exact à supprimer (Old String).
    - Le bloc de code exact à coller (New String).
- Informe l'utilisateur que le bloc de remplacement est dans son presse-papier.

**Slogan : "Sûr, précis, instantané."**
