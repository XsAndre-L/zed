@echo off

REM =========================================================
REM  Xide -- Windows Bundle Script
REM  Usage:  bundle.cmd [release|dev]
REM  Output: dist\Xide\  ready to zip and share
REM
REM  To use the 'xide' command from any terminal, add
REM  the dist\Xide folder to your PATH.
REM =========================================================

set PROFILE=%1
if "%PROFILE%"=="" set PROFILE=release

if /I "%PROFILE%"=="release" (
    set CARGO_FLAGS=--release
    set TARGET_DIR=target\release
    echo [Xide] Building RELEASE...
) else (
    set CARGO_FLAGS=
    set TARGET_DIR=target\debug
    echo [Xide] Building DEV...
)

REM ---- Build main editor ----
cargo build -p xide %CARGO_FLAGS%
if errorlevel 1 (
    echo [Xide] BUILD FAILED.
    exit /b 1
)

REM ---- Build CLI separately (different binary name, no collision) ----
cargo build -p cli %CARGO_FLAGS%
if errorlevel 1 (
    echo [Xide] CLI BUILD FAILED.
    exit /b 1
)

REM ---- Prepare output directory ----
set DIST=dist\Xide
echo [Xide] Creating %DIST%...
if exist "%DIST%" rmdir /s /q "%DIST%"
mkdir "%DIST%"

REM ---- Copy everything flat into one folder ----
echo [Xide] Copying files...
copy /y "%TARGET_DIR%\xide.exe"         "%DIST%\xide.exe"        >nul
copy /y "%TARGET_DIR%\xide-cli.exe"     "%DIST%\xide-cli.exe"    >nul
copy /y "%TARGET_DIR%\OpenConsole.exe"  "%DIST%\OpenConsole.exe" >nul
copy /y "%TARGET_DIR%\conpty.dll"       "%DIST%\conpty.dll"      >nul

REM ---- Done ----
echo.
echo [Xide] Bundle ready at: %DIST%\
echo.
echo   xide.exe          -- the editor  (double-click OR run from terminal)
echo   xide-cli.exe      -- CLI proxy   (optional: rename to xide.exe, put folder on PATH)
echo   OpenConsole.exe   -- terminal support (must stay next to xide.exe)
echo   conpty.dll        -- terminal support (must stay next to xide.exe)
echo.
echo   To make 'xide' work from any terminal:
echo   1. Add this folder to your system PATH
echo   2. Rename xide-cli.exe to xide.exe  (and rename the editor to xide-editor.exe)
echo      OR just run xide.exe directly - it opens the GUI just fine.
echo.
