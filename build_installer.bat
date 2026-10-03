@echo off
setlocal
echo Ejecutando generador de instalador de Flux para Windows...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\build_installer.ps1" %*
if %ERRORLEVEL% NEQ 0 (
    echo.
    echo Ocurrio un error durante la generacion del instalador.
    pause
    exit /b %ERRORLEVEL%
)
pause
