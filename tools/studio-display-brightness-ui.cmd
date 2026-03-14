@echo off
setlocal

set "SCRIPT=%~dp0studio-display-brightness-ui.ps1"

where pwsh >nul 2>nul
if %ERRORLEVEL%==0 (
    pwsh -NoProfile -File "%SCRIPT%" %*
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
)

endlocal
