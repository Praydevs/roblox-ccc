@echo off
setlocal
cd /d "%~dp0"
title Vexora desktop agent

if not exist alt-cookie.txt (
    echo.
    echo Missing alt-cookie.txt
    echo Create a text file next to this launcher, put the alt's full .ROBLOSECURITY value in it, save, and run this again.
    echo.
    pause
    exit /b 1
)

set "KEY=%VEXORA_API_KEY%"
if "%KEY%"=="" set /p KEY=Paste the claimer API key from the dashboard: 
if "%KEY%"=="" (
    echo No API key entered.
    pause
    exit /b 1
)

python --version >nul 2>&1
if errorlevel 1 (
    echo Python was not found. Install Python 3 from python.org and tick "Add to PATH".
    pause
    exit /b 1
)

python "%~dp0vexora-agent.py" --site https://elow.cc --key "%KEY%"
echo.
echo The agent stopped. Press any key to close.
pause >nul
