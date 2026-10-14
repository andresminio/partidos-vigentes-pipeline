@echo off
rem Cierre mensual: poner el Excel nuevo en data\ y hacer doble clic en este archivo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run_cierre.ps1"
pause
