@echo off
rem Builds dist\ForeverPrices.zip (ForeverPrices.exe + Uninstall.bat + README.txt) for friends.
cd /d "%~dp0"
if not exist .venv python -m venv .venv
.venv\Scripts\python -m pip install -q pyinstaller
.venv\Scripts\pyinstaller --noconfirm --onefile --noconsole --name ForeverPrices ^
  --add-data "..\addon\ForeverPrices;ForeverPrices" forever_prices_client.py
if errorlevel 1 exit /b 1
copy /y Uninstall.bat dist\ >nul
copy /y README.txt dist\ >nul
powershell -NoProfile -Command "Compress-Archive -Force -Path dist\ForeverPrices.exe,dist\Uninstall.bat,dist\README.txt -DestinationPath dist\ForeverPrices.zip"
echo Built dist\ForeverPrices.zip
