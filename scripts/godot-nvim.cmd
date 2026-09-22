@echo off
setlocal

set "ROUTER=%~dp0godot-nvim-router.ps1"

rem NOTE: keep this file pure ASCII. cmd.exe reads .cmd/.bat in the OEM code
rem page, so non-ASCII comments can break parsing (a UTF-8 comment here made
rem cmd try to execute fragments of it).
rem
rem All arguments are forwarded as-is; the PowerShell side interprets them so
rem that either Godot "Exec Flags" form works. See godot-nvim-router.ps1.
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass ^
  -File "%ROUTER%" %*

exit /b %ERRORLEVEL%
