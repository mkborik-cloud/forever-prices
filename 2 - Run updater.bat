@echo off
cd /d "%~dp0"
title ForeverPrices updater
python updater.py --loop
pause
