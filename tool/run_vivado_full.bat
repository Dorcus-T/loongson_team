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

REM temp log location, Tcl will move it to correct dir later
set "TMPLOG=%RUNDIR%\vivado_full_temp.log"
set "TMPJOU=%RUNDIR%\vivado_full_temp.jou"

echo ============================================================
echo Vivado Full Project Timing Analysis
echo Project: loongson.xpr
echo ============================================================
echo.

call "%VIVADO%" -mode batch -source vivado_full.tcl -notrace -log "%TMPLOG%" -journal "%TMPJOU%"

REM move log/jou into the latest run directory
for /f "delims=" %%d in ('dir /b /ad /o-n "%RUNDIR%\full_*" 2^>nul') do (
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
dir /b /ad "%RUNDIR%\full_*" 2>nul
echo ============================================================

popd
pause
