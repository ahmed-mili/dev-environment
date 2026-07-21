@echo off
chcp 65001 > nul
set PYTHONIOENCODING=utf-8
set TOOLDIR=%USERPROFILE%\.claude\tools\obsidian-screenshot
set PYTHONPATH=%TOOLDIR%\packages;%TOOLDIR%\packages\win32;%TOOLDIR%\packages\win32\lib;%TOOLDIR%\packages\pythonwin
set PATH=%TOOLDIR%\packages\pywin32_system32;%PATH%
rem Python : celui de l'installeur natif s'il est la, sinon celui du PATH.
set PY=%USERPROFILE%\.local\bin\python3.14.exe
if not exist "%PY%" set PY=python
"%PY%" "%TOOLDIR%\obsidian_tools.py" %*
