@echo off
rem Point d'entree unique du toolkit de capture Obsidian.
rem chcp 65001 : les noms de vaults et de notes portent des accents et des
rem symboles (Reglages, 100 EUR...). Sans UTF-8, -Vault ne matche plus le titre.
chcp 65001 > nul
set TOOLDIR=%~dp0
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%TOOLDIR%obsidian_capture.ps1" %*
