@echo off
setlocal

set "ROUTER=%~dp0godot-nvim-router.ps1"

powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass ^
  -File "%ROUTER%" ^
  -FilePath "%~1" ^
  -Line "%~2" ^
  -Column "%~3"

exit /b %ERRORLEVEL%
