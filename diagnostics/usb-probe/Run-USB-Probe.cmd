@echo off
chcp 65001 >nul
python "%~dp0usb_probe.py" --seconds 180 --wait 600 --output "%~dp0..\..\out\usb-probe"
echo.
pause
