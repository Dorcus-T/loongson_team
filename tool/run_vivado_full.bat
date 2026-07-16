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



set "LOGDIR=%TOOLDIR%\runs"

if not exist "%LOGDIR%" mkdir "%LOGDIR%"



echo ============================================================

echo Vivado Full Project Timing Analysis

echo Project: loongson.xpr

echo ============================================================

echo.



call "%VIVADO%" -mode batch -source vivado_full.tcl -notrace -log "%LOGDIR%/vivado_full.log" -journal "%LOGDIR%/vivado_full.jou"



echo.

echo ============================================================

echo Latest full-project runs:

dir /b /ad runs\full_* 2>nul

echo ============================================================



popd

pause

