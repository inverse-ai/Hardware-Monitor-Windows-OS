@echo off
rem Starts the stats server (minimized console) and opens the monitor
rem in an Edge app window (no browser chrome - looks like a desktop widget).
cd /d "%~dp0"
start "Hardware Monitor Server" /min powershell -NoProfile -ExecutionPolicy Bypass -File server.ps1
timeout /t 2 /nobreak >nul
start "" msedge --app=http://localhost:8787/
if errorlevel 1 start "" http://localhost:8787/
