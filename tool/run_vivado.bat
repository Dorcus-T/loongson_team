@echo off
REM Vivado CPU-only Timing Analysis

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

set "LOG_DIR=%TOOLDIR%\runs"
if not exist "%LOG_DIR%" mkdir "%LOG_DIR%"

echo ============================================================
echo Vivado CPU-only Timing Analysis
echo ============================================================
echo.

call "%VIVADO%" -mode batch -source vivado_timing.tcl -notrace ^
  -log "%LOG_DIR%/vivado_cpu_only.log" ^
  -journal "%LOG_DIR%/vivado_cpu_only.jou"

echo.
echo ============================================================
echo Latest CPU-only runs:
dir /b /ad runs\vivado_* 2>/dev/null
echo ============================================================

popd
pause
