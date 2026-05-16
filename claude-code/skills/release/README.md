# Release Skill

## Description

Automates the release process for Obsidian plugins or any Git-based project.

## Usage

```bash
/release v1.3.0-beta
```

Or use the command directly:
```bash
node ~/.claude/skills/release/release.js v1.3.0-beta
```

## Steps Performed

1. **Build** - Runs `npm run build`
2. **Git Add** - Stages all changes
3. **Git Commit** - Commits with message "release VERSION" (if changes exist)
4. **Git Push** - Pushes to origin/main
5. **Create Tag** - Creates Git tag with version
6. **Push Tag** - Pushes tag to trigger GitHub Actions release

## Requirements

- Git configured with push access
- npm project with build script
- GitHub Actions workflow for releases (optional)

## Example

```bash
# Release a beta version
/release v1.3.0-beta

# Release a stable version  
/release v1.3.0
```
