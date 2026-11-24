@echo off
rem  Double-click to start adb-watchV (Python + tkinter GUI).
rem  Uses the py launcher's windowless interpreter so no console window flashes.
cd /d "%~dp0"

where pyw.exe >nul 2>&1
if not errorlevel 1 (
    start "" pyw.exe "%~dp0adb_watch_v.py"
    exit /b 0
)

where pythonw.exe >nul 2>&1
if not errorlevel 1 (
    start "" pythonw.exe "%~dp0adb_watch_v.py"
    exit /b 0
)

where python.exe >nul 2>&1
if not errorlevel 1 (
    python.exe "%~dp0adb_watch_v.py"
    exit /b %errorlevel%
)

echo Python 3 not found. Install Python 3.9+ (with tkinter) first.
pause
exit /b 1
