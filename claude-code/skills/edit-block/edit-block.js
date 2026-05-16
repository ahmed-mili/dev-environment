#!/usr/bin/env node
'use strict';

/**
 * EDIT-BLOCK SKILL
 * ================
 *
 * Ce skill résout le problème des éditions de fichiers qui échouent
 * à cause de caractères spéciaux, tabulations, ou chaînes non uniques.
 *
 * PRINCIPE : Extraire le bloc EXACT à remplacer en utilisant sed/cat -A
 * pour voir tous les caractères (même invisibles), puis générer
 * un fichier de remplacement utilisable par l'outil Edit.
 *
 * USAGE :
 *   node edit-block.js <fichier> <ligne-début> <ligne-fin> <fichier-remplacement>
 *
 * EXEMPLE :
 *   node edit-block.js src/plugin.js 232 236 replacement.txt
 */

const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

// ============ FONCTIONS UTILITAIRES ============

/**
 * Affiche un message d'erreur et quitte
 */
function error(msg) {
  console.error(`❌ ERREUR: ${msg}`);
  process.exit(1);
}

/**
 * Affiche un message d'information
 */
function info(msg) {
  console.log(`ℹ️  ${msg}`);
}

/**
 * Affiche un succès
 */
function success(msg) {
  console.log(`✅ ${msg}`);
}

/**
 * Lit les lignes spécifiées d'un fichier avec cat -A pour voir les caractères invisibles
 * Retourne un objet avec le contenu exact et les détails
 */
function readBlockWithCatA(filePath, startLine, endLine) {
  try {
    // Utiliser cat -A pour voir les caractères spéciaux (^I pour tab, $ pour fin de ligne, etc.)
    const output = execSync(`cat -A "${filePath}" | sed -n '${startLine},${endLine}p'`, {
      encoding: 'utf-8',
      shell: true
    });

    return {
      lines: output.split('\n').filter(l => l !== ''), // cat -A ajoute une ligne vide à la fin
      raw: output
    };
  } catch (err) {
    error(`Impossible de lire le fichier: ${err.message}`);
  }
}

/**
 * Lit le contenu normal des lignes (sans cat -A)
 */
function readBlockNormal(filePath, startLine, endLine) {
  try {
    const output = execSync(`sed -n '${startLine},${endLine}p' "${filePath}"`, {
      encoding: 'utf-8',
      shell: true
    });

    return output;
  } catch (err) {
    error(`Impossible de lire le fichier: ${err.message}`);
  }
}

/**
 * Génère un old_string robuste en ajoutant du contexte si nécessaire
 */
function generateRobustOldString(filePath, startLine, endLine) {
  // Lire le bloc normal
  const block = readBlockNormal(filePath, startLine, endLine);

  // Lire une ligne avant et après pour le contexte
  let beforeContext = '';
  let afterContext = '';

  try {
    if (startLine > 1) {
      beforeContext = execSync(`sed -n '${startLine - 1}p' "${filePath}"`, { encoding: 'utf-8' }).trim();
    }
  } catch (e) {}

  try {
    const totalLines = parseInt(execSync(`wc -l < "${filePath}"`, { encoding: 'utf-8' }).trim());
    if (endLine < totalLines) {
      afterContext = execSync(`sed -n '${endLine + 1}p' "${filePath}"`, { encoding: 'utf-8' }).trim();
    }
  } catch (e) {}

  // Si le bloc est petit (moins de 3 lignes), ajouter du contexte pour le rendre unique
  const lineCount = endLine - startLine + 1;
  if (lineCount < 3 && (beforeContext || afterContext)) {
    // Étendre le bloc avec du contexte
    const newStart = Math.max(1, startLine - 1);
    const newEnd = endLine + 1;
    return {
      oldString: readBlockNormal(filePath, newStart, newEnd),
      extended: true,
      newStart,
      newEnd
    };
  }

  return {
    oldString: block,
    extended: false,
    newStart: startLine,
    newEnd: endLine
  };
}

// ============ LOGIQUE PRINCIPALE ============

function main() {
  const args = process.argv.slice(2);

  if (args.length < 4) {
    console.log(`
╔══════════════════════════════════════════════════════════════════╗
║                    EDIT-BLOCK SKILL v1.0                         ╜
╠══════════════════════════════════════════════════════════════════╣
║                                                                  ║
║  Résout les problèmes d'édition de fichiers avec l'outil Edit.   ║
║                                                                  ║
║  USAGE:                                                          ║
║    node edit-block.js <fichier> <début> <fin> <remplacement>    ║
║                                                                  ║
║  EXEMPLE:                                                        ║
║    node edit-block.js src/app.js 45 52 nouveau-code.txt          ║
║                                                                  ║
║  SORTIE:                                                         ║
║    - Affiche le old_string exact à utiliser                      ║
║    - Copie le new_string dans le presse-papier                  ║
║    - Crée un fichier edit-command.txt avec la commande complète ║
║                                                                  ║
╚══════════════════════════════════════════════════════════════════╝
`);
    process.exit(0);
  }

  const [filePath, startLineStr, endLineStr, replacementFile] = args;
  const startLine = parseInt(startLineStr, 10);
  const endLine = parseInt(endLineStr, 10);

  // Vérifications
  if (!fs.existsSync(filePath)) {
    error(`Fichier non trouvé: ${filePath}`);
  }

  if (!fs.existsSync(replacementFile)) {
    error(`Fichier de remplacement non trouvé: ${replacementFile}`);
  }

  if (isNaN(startLine) || isNaN(endLine) || startLine < 1 || endLine < startLine) {
    error(`Lignes invalides: début=${startLine}, fin=${endLine}`);
  }

  info(`Lecture de ${filePath} lignes ${startLine}-${endLine}`);

  // Lire le bloc avec cat -A pour debug
  const debugInfo = readBlockWithCatA(filePath, startLine, endLine);
  info(`Caractères visibles avec cat -A:`);
  console.log('---');
  debugInfo.lines.forEach((line, i) => {
    console.log(`L${startLine + i}: ${line}`);
  });
  console.log('---');

  // Générer le old_string robuste
  const { oldString, extended, newStart, newEnd } = generateRobustOldString(filePath, startLine, endLine);

  if (extended) {
    info(`Bloc étendu aux lignes ${newStart}-${newEnd} pour garantir l'unicité`);
  }

  // Lire le contenu de remplacement
  const newString = fs.readFileSync(replacementFile, 'utf-8');

  // Afficher les résultats
  console.log('\n' + '='.repeat(70));
  console.log('OLD_STRING (copier dans l\'outil Edit):');
  console.log('='.repeat(70));
  console.log(oldString);
  console.log('='.repeat(70));
  console.log('\nNEW_STRING (déjà dans le fichier replacement):');
  console.log('='.repeat(70));
  console.log(newString);
  console.log('='.repeat(70));

  // Créer un fichier de commande pour référence
  const outputDir = path.join(process.env.USERPROFILE || process.env.HOME || '.', '.claude', 'edit-block-output');
  if (!fs.existsSync(outputDir)) {
    fs.mkdirSync(outputDir, { recursive: true });
  }

  const timestamp = Date.now();
  const commandFile = path.join(outputDir, `edit-command-${timestamp}.json`);

  const editCommand = {
    tool: "Edit",
    file_path: path.resolve(filePath),
    old_string: oldString,
    new_string: newString
  };

  fs.writeFileSync(commandFile, JSON.stringify(editCommand, null, 2), 'utf-8');

  success(`Commande d'édition sauvegardée dans: ${commandFile}`);

  // Instructions finales
  console.log(`
📋 INSTRUCTIONS POUR L'AGENT:
═══════════════════════════════════════════════════════════════════════

1. Utilisez cet old_string EXACT:
   (copiez tout entre les marqueurs ci-dessus)

2. Utilisez ce new_string:
   (contenu du fichier: ${replacementFile})

3. Assurez-vous que:
   - Les tabulations sont préservées (utilisez \\t si besoin)
   - Les retours à la ligne sont cohérents
   - La chaîne old_string est UNIQUE dans le fichier

4. Si l'édition échoue encore:
   - Étendez le bloc old_string avec plus de lignes de contexte
   - Ou utilisez le fichier: ${commandFile}

═══════════════════════════════════════════════════════════════════════
`);
}

// Lancer le skill
main();
