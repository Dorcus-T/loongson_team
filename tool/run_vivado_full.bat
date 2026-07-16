@echo off
REM Vivado Full Project Timing Analysis

set "VIVADO=E:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat"

if not exist "%VIVADO%" (
    echo [ERROR] Vivado not found: %VIVADO%
    pause
    exit /b 1
)

set "TOOLDIR="
if exist "Z:\home\dorcus_t\chiplab\IP\myCPU\tool\" (
    set "TOOLDIR=Z:\home\dorcus_t\chiplab\IP\myCPU\tool"
) else if exist "\wsl.localhost\Ubuntu-22.04\home\dorcus_t\chiplab\IP\myCPU\tool\" (
    set "TOOLDIR=\wsl.localhost\Ubuntu-22.04\home\dorcus_t\chiplab\IP\myCPU\tool"
)

if "%TOOLDIR%"=="" (
    echo [ERROR] Cannot find tool directory
    pause
    exit /b 1
)

pushd "%TOOLDIR%" 2>/dev/null
if errorlevel 1 (
    echo [ERROR] Cannot access: %TOOLDIR%
    pause
    exit /b 1
)

REM log 扔进 runs/ 避免污染 tool/
set "LOG_DIR=%TOOLDIR%\runs"
if not exist "%LOG_DIR%" mkdir "%LOG_DIR%"

echo ============================================================
echo Vivado Full Project Timing Analysis
echo ============================================================
echo.

call "%VIVADO%" -mode batch -source vivado_full.tcl -notrace ^
  -log "%LOG_DIR%/vivado_full.log" ^
  -journal "%LOG_DIR%/vivado_full.jou"

echo.
echo ============================================================
echo Latest full-project runs:
dir /b /ad runs\full_* 2>/dev/null
echo ============================================================

popd
pause
