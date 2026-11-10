@echo off
chcp 65001 >nul
setlocal

REM ============================================================
REM  AwayFromShorts Tauri Shell - dev launcher
REM  WebView2 fails to init when the exe path contains non-ASCII
REM  chars (Chinese folder name): os error 5 / 0x8000FFFF.
REM  The NSIS installer puts the exe under %LOCALAPPDATA%\AwayFromShorts
REM  (pure ASCII) so normal use is fine. This script is for running
REM  the exe directly from the Chinese source tree: it copies the exe
REM  to a pure-ASCII path, then launches it.
REM ============================================================

set "SRC=%~dp0src-tauri\target\release\awayfromshorts-shell.exe"
if not exist "%SRC%" (
  echo [ERROR] build output not found. Run: cd src-tauri ^&^& cargo build --release
  echo         %SRC%
  pause
  exit /b 1
)

set "DEST=%LOCALAPPDATA%\AwayFromShorts\shell"
if not exist "%DEST%" mkdir "%DEST%" >nul 2>&1
copy /Y "%SRC%" "%DEST%\awayfromshorts-shell.exe" >nul

start "" "%DEST%\awayfromshorts-shell.exe"
echo Launched from pure-ASCII path: %DEST%\awayfromshorts-shell.exe
endlocal
