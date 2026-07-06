@echo off
chcp 65001 > nul
set PYTHONIOENCODING=utf-8
set PYTHONPATH=C:\Users\Ahmed\.claude\tools\obsidian-screenshot\packages;C:\Users\Ahmed\.claude\tools\obsidian-screenshot\packages\win32;C:\Users\Ahmed\.claude\tools\obsidian-screenshot\packages\win32\lib;C:\Users\Ahmed\.claude\tools\obsidian-screenshot\packages\pythonwin
set PATH=C:\Users\Ahmed\.claude\tools\obsidian-screenshot\packages\pywin32_system32;%PATH%
C:\Users\Ahmed\.local\bin\python3.14.exe C:\Users\Ahmed\.claude\tools\obsidian-screenshot\obsidian_tools.py %*
