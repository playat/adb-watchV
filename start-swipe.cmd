@echo off
setlocal
title adb swipe hotkey

rem =====================================================================
rem  Double-click this file to start the Shift+Up / Shift+Down swiper.
rem
rem  It first lists the devices already in adb and lets you pick one
rem  with the arrow keys (the last entry is "connect a new device").
rem  If nothing is connected it walks you through pairing:
rem      pairing IP:port -> pairing code -> adb pair
rem      -> connect IP:port -> adb connect
rem
rem  Needs a real console window (arrow keys + typed input), so run it
rem  by double-clicking, not by piping it into something.
rem
rem  Optional arguments (run from a console, e.g.):
rem     start-swipe.cmd -Setup                  skip the menu, go straight to pairing
rem     start-swipe.cmd -Device 192.168.1.100:5555
rem     start-swipe.cmd -ConsoleOnly            only listen while focused
rem =====================================================================

set "SCRIPT=%~dp0adb-swipe-hotkey.ps1"

if not exist "%SCRIPT%" (
    echo [ERROR] adb-swipe-hotkey.ps1 not found next to this launcher.
    echo         Both files must sit in the same folder.
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*

set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
    echo.
    echo [ERROR] script exited with code %RC%. Window kept open so you can read the message.
    pause
)

endlocal
