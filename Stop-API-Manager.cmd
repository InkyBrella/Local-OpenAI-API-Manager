@echo off
setlocal DisableDelayedExpansion
title Stop Local OpenAI API Manager
rem Use Windows PowerShell's own built-in modules.
set "PSModulePath="
set "managerShell=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "managerShell=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
"%managerShell%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Stop-Proxy.ps1" -Pause %*
exit /b %errorlevel%
