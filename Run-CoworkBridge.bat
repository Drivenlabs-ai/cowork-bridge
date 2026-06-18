@echo off
chcp 65001 >nul
REM ==========================================================================
REM  Cowork Bridge - lanceur
REM  Double-clique ce fichier pour ouvrir l'installeur / le panneau de gestion.
REM  Lance PowerShell en mode STA (requis par l'interface) avec la politique
REM  d'execution contournee uniquement pour ce script (rien n'est modifie sur
REM  la machine de maniere durable).
REM ==========================================================================
setlocal
set "SCRIPT=%~dp0Install-CoworkBridge.ps1"

powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%SCRIPT%"
if errorlevel 1 (
    echo.
    echo Une erreur est survenue. Voir le message ci-dessus.
    pause
)
endlocal
