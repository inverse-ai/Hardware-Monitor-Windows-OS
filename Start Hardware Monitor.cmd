@echo off
rem Starts the Hardware Monitor:
rem   1) the always-on-top desktop widget, and
rem   2) the web dashboard (opened in an Edge app window).
rem To stop: exit the widget from its tray icon, and close the
rem "Hardware Monitor Server" window.
cd /d "%~dp0"

rem 1) Desktop widget - launched hidden via the VBS (no console window).
start "" wscript.exe "%~dp0Hardware Widget.vbs"

rem 2) Stats server for the dashboard (minimized console).
start "Hardware Monitor Server" /min powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0server.ps1"

rem 3) Give the server ~2s to start, then open the dashboard (Edge app window;
rem    fall back to the default browser). ping is used as the delay because it
rem    works even when the script is launched non-interactively.
ping -n 3 127.0.0.1 >nul
start "" msedge --app=http://localhost:8787/
if errorlevel 1 start "" http://localhost:8787/
