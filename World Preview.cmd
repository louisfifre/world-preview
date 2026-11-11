@echo off
rem Opens the world preview with the PowerShell every Windows has, and leaves no console window behind.
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0scripts\start.ps1" %*
