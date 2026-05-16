# EDIT-BLOCK SKILL

## 📌 Description

Ce skill résout le problème récurrent des **échecs d'édition de fichiers** avec l'outil `Edit` :
- "String to replace not found in file"
- Caractères spéciaux invisibles
- Chaînes non uniques
- Problèmes de tabulations vs espaces

## 🎯 Cas d'usage

Quand vous voyez cette erreur :
```
X [ERROR] String to replace not found in file
```

Utilisez ce skill pour **générer le old_string exact** à copier dans l'outil Edit.

## 🚀 Utilisation

### Commande de base
```bash
node edit-block.js <fichier> <ligne-début> <ligne-fin> <fichier-remplacement>
```

### Exemple
```bash
# 1. Créer le fichier de remplacement
echo "nouveau code" > new-code.txt

# 2. Utiliser le skill
node edit-block.js src/plugin.js 232 236 new-code.txt
```

## 📤 Sortie

Le skill affiche :
1. **Le old_string exact** avec cat -A (voir les caractères invisibles)
2. **Le new_string** à utiliser
3. **Un fichier JSON** avec la commande complète : `edit-command-<timestamp>.json`

## 💡 Conseils

- **Blocs courts** : Le skill étend automatiquement avec du contexte
- **Caractères spéciaux** : Utilisez la sortie `cat -A` pour déboguer
- **Échecs persistants** : Étendez le range de lignes (ajoutez du contexte)

## 🔧 Installation

Copiez ce dossier dans `.claude/skills/` :
```bash
cp -r edit-block ~/.claude/skills/
```

Ou clonez-le depuis un repo partagé.

## 📝 Exemple d'utilisation par une IA

```
L'utilisateur veut modifier les lignes 45-52 de src/app.js

1. Je lis les lignes exactes :
   sed -n '45,52p' src/app.js

2. Je vois qu'il y a des erreurs avec Edit

3. J'utilise le skill :
   node ~/.claude/skills/edit-block/edit-block.js src/app.js 45 52 replacement.txt

4. Le skill me donne le old_string exact à utiliser

5. J'utilise Edit avec cette chaîne exacte
```

## ⚙️ Fonctionnement interne

1. **Lecture précise** : Utilise `cat -A` pour voir TOUS les caractères
2. **Détection d'unicité** : Si le bloc est court, ajoute du contexte
3. **Génération** : Crée un fichier JSON avec la commande Edit complète
4. **Instructions** : Donne les étapes claires à suivre

---

**Version** : 1.0.0  
**Auteur** : Claude  
**Licence** : MIT
