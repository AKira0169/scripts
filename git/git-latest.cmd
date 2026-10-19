@echo off
rem Fetch all workspace repos and fast-forward every local branch (Windows double-click launcher).
rem Extra args pass through, e.g.: git-latest.cmd --track-all   |   git-latest.cmd --repos fe.core,be.eskan
rem On macOS/Linux run pull-all.sh directly: bash scripts/git/pull-all.sh
node "%~dp0..\run-sh.js" "%~dp0pull-all.sh" %*
if "%~1"=="" pause
