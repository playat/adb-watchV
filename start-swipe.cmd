@echo off
setlocal
title adb watchV hotkey

rem =====================================================================
rem  Double-click this file to start the watcher (Alt+F1 / Alt+F2 / Alt+F3).
rem
rem  While its window has focus, pressing "r" disconnects the device and
rem  restarts the script. That key is NOT a global hotkey: the script only
rem  reads its own console buffer, so other apps keep their "r".
rem
rem  It first lists the devices already in adb and lets you pick one
rem  with the arrow keys (the last entry is "connect a new device").
rem  If nothing is connected it runs three connect attempts, asking for
rem  a bit more each time:
rem      1) mDNS auto-discovery  -> pick -> adb connect
rem      2) manual IP:port       -> adb connect
rem      3) pairing IP:port + code -> adb pair -> adb connect again
rem
rem  Needs a real console window (arrow keys + typed input), so run it
rem  by double-clicking, not by piping it into something.
rem
rem  Optional arguments (run from a console, e.g.):
rem     start-watchV.cmd -Setup                  skip the menu, go to connect attempts
rem     start-watchV.cmd -Device 192.168.1.100:5555
rem     start-watchV.cmd -ConsoleOnly            only listen while focused
rem =====================================================================

set "SCRIPT=%~dp0adb-watchV-hotkey.ps1"

if not exist "%SCRIPT%" (
    echo [ERROR] adb-watchV-hotkey.ps1 not found next to this launcher.
    echo         Both files must sit in the same folder.
    pause
    exit /b 1
)

rem Marks "we are launched by this launcher" so the script can hand the
rem restart back to us (see Restart-Watcher in the .ps1).
set "ADBWATCH_LAUNCHER=1"

:run
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*

set "RC=%ERRORLEVEL%"

rem 97 = the script asked for a restart (pressed "r" in its window).
rem We stay alive and run it again, so the window and its history survive.
if "%RC%"=="97" (
    echo.
    echo [restart] restarting the watcher...
    echo ------------------------------------------------------------
    goto run
)

if not "%RC%"=="0" (
    echo.
    echo [ERROR] script exited with code %RC%. Window kept open so you can read the message.
    pause
)

endlocal
