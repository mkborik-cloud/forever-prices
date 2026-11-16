@echo off
rem Builds dist\ForeverPrices.zip for friends:
rem   ForeverPrices\         the addon, copied into Interface\AddOns by hand
rem   ForeverPrices.exe      downloads prices in the background
rem   Uninstall.bat, README.txt
cd /d "%~dp0"
if not exist .venv python -m venv .venv
.venv\Scripts\python -m pip install -q pyinstaller
.venv\Scripts\pyinstaller --noconfirm --onefile --noconsole --name ForeverPrices forever_prices_client.py
if errorlevel 1 exit /b 1
if exist dist\package rmdir /s /q dist\package
mkdir dist\package
xcopy /e /i /q ..\addon\ForeverPrices dist\package\ForeverPrices >nul
copy /y dist\ForeverPrices.exe dist\package\ >nul
copy /y Uninstall.bat dist\package\ >nul
copy /y README.txt dist\package\ >nul
powershell -NoProfile -Command "Compress-Archive -Force -Path dist\package\* -DestinationPath dist\ForeverPrices.zip"
echo Built dist\ForeverPrices.zip
