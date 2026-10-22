@echo off
rem Lifeline Recomp launcher for Windows. Add THIS file to Steam as a non-Steam game (the Linux launcher.sh).
rem It runs launcher.ps1 next to it with Windows PowerShell; arguments are passed through (e.g. --fullscreen).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0launcher.ps1" %*
exit /b %ERRORLEVEL%
