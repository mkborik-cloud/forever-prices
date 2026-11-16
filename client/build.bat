@echo off
rem Builds dist\SimpleAH.zip for friends:
rem   SimpleAH\         the addon, copied into Interface\AddOns by hand
rem   SimpleAH.exe      downloads prices in the background
rem   Uninstall.bat, README.txt
cd /d "%~dp0"
if not exist .venv python -m venv .venv
.venv\Scripts\python -m pip install -q pyinstaller
.venv\Scripts\pyinstaller --noconfirm --onefile --noconsole --name SimpleAH simple_ah_client.py
if errorlevel 1 exit /b 1
if exist dist\package rmdir /s /q dist\package
mkdir dist\package
xcopy /e /i /q ..\addon\SimpleAH dist\package\SimpleAH >nul
copy /y dist\SimpleAH.exe dist\package\ >nul
copy /y Uninstall.bat dist\package\ >nul
copy /y README.txt dist\package\ >nul
powershell -NoProfile -Command "Compress-Archive -Force -Path dist\package\* -DestinationPath dist\SimpleAH.zip"
echo Built dist\SimpleAH.zip
