@echo off
rem Opens the installer window. Pass -Engine 5.6, -Project "path\to\Game.uproject" or -Uninstall to run without it.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install.ps1" %*
