@echo off
setlocal DisableDelayedExpansion
title Local OpenAI API Manager
rem Let Windows PowerShell discover its own built-in modules, even from pwsh 7.
set "PSModulePath="
set "managerShell=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "managerShell=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
"%managerShell%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Manage-Proxy.ps1" %*
set "managerExitCode=%errorlevel%"
if not "%managerExitCode%"=="0" pause
exit /b %managerExitCode%
