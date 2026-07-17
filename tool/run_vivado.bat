@echo off
setlocal EnableExtensions
set "VIVADO=E:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat"

if not exist "%VIVADO%" (
    echo [ERROR] Vivado not found
    echo Path: %VIVADO%
    pause
    exit /b 1
)

set "TOOLDIR=Z:\home\dorcus_t\chiplab\IP\myCPU\tool"

if not exist "%TOOLDIR%\" (
    echo [ERROR] Cannot find tool directory
    echo Path: %TOOLDIR%
    pause
    exit /b 1
)

pushd "%TOOLDIR%"
if errorlevel 1 (
    echo [ERROR] Cannot pushd to: %TOOLDIR%
    pause
    exit /b 1
)

set "RUNDIR=%TOOLDIR%\runs"
if not exist "%RUNDIR%" mkdir "%RUNDIR%"

set "TMPLOG=%RUNDIR%\vivado_cpu_temp.log"
set "TMPJOU=%RUNDIR%\vivado_cpu_temp.jou"

echo ============================================================
echo Vivado CPU-only Timing Analysis
echo ============================================================
echo.

call "%VIVADO%" -mode batch -source vivado_timing.tcl -notrace -log "%TMPLOG%" -journal "%TMPJOU%"

for /f "delims=" %%d in ('dir /b /ad /o-n "%RUNDIR%\vivado_*" 2^>nul') do (
    set "LATEST=%RUNDIR%\%%d"
    goto :found
)
goto :done

:found
if exist "%TMPLOG%" move /y "%TMPLOG%" "%LATEST%\" >nul 2>nul
if exist "%TMPJOU%" move /y "%TMPJOU%" "%LATEST%\" >nul 2>nul

:done
echo.
echo ============================================================
echo Latest runs:
dir /b /ad "%RUNDIR%\vivado_*" 2>nul
echo ============================================================

popd
pause
