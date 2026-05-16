#!/usr/bin/env node
'use strict';

/**
 * RELEASE SKILL
 * Automates Git release workflow for Obsidian plugins
 *
 * Usage: node release.js v1.3.0-beta
 */

const { execSync } = require('child_process');

function log(step, message) {
  console.log(`[${step}/6] ${message}...`);
}

function run(cmd, errorMessage) {
  try {
    execSync(cmd, { stdio: 'inherit' });
    return true;
  } catch (err) {
    if (errorMessage) {
      console.error(errorMessage);
    }
    return false;
  }
}

function main() {
  const version = process.argv[2];

  if (!version) {
    console.log('Usage: /release v0.9.1-beta');
    console.log('   or: node release.js v1.3.0');
    process.exit(1);
  }

  console.log(`\n🚀 Starting release ${version}\n`);

  // 1. Build
  log(1, 'Build');
  if (!run('npm run build', 'Build failed')) {
    process.exit(1);
  }

  // 2. Git Add
  log(2, 'Git add');
  if (!run('git add .')) {
    process.exit(1);
  }

  // 3. Git Commit (only if there are changes)
  log(3, 'Git commit');
  const hasChanges = execSync('git diff --cached --quiet', { encoding: 'utf-8' }) === '';
  if (hasChanges) {
    console.log('No changes to commit.');
  } else {
    if (!run(`git commit -m "release ${version}"`, 'Commit failed')) {
      process.exit(1);
    }
  }

  // 4. Git Push
  log(4, 'Git push');
  if (!run('git push', 'Push failed')) {
    process.exit(1);
  }

  // 5. Create Tag
  log(5, 'Create tag');
  if (!run(`git tag ${version}`, `Tag ${version} already exists or creation failed`)) {
    process.exit(1);
  }

  // 6. Push Tag
  log(6, 'Push tag');
  if (!run(`git push origin ${version}`, 'Push tag failed')) {
    process.exit(1);
  }

  console.log(`\n✅ Version ${version} released successfully!`);
  console.log('GitHub Actions will create the release automatically.\n');
}

main();
