@echo off
rem Fetch all workspace repos and fast-forward every local branch.
rem Extra args pass through, e.g.: git-latest.cmd -TrackAll   |   git-latest.cmd -Repos fe.core,be.eskan
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0pull-all.ps1" %*
if "%~1"=="" pause
