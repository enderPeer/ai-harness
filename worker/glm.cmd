@echo off
where pwsh >nul 2>&1
if %errorlevel%==0 (
    pwsh -NoProfile -ExecutionPolicy Bypass -File C:\llama.cpp\glm.ps1 %*
) else (
    echo glm requires PowerShell 7 ^(pwsh^). Install with: winget install Microsoft.PowerShell
    exit /b 1
)
