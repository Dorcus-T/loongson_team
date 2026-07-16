@echo off
chcp 65001 >nul
setlocal

set CHIPLAB_HOME=Z:\home\dorcus_t\chiplab
set WSL_CHIPLAB=/home/dorcus_t/chiplab
set TEST=nscscc_func

echo ===============================================================
echo   %TEST% Verilator Simulation
echo ===============================================================
echo.

echo [1/4] Building test program...
wsl -d Ubuntu-22.04 -e bash -c "export CHIPLAB_HOME=%WSL_CHIPLAB% && export PATH=%WSL_CHIPLAB%/toolchains/loongson-gnu-toolchain-8.3-x86_64-loongarch32r-linux-gnusf-v2.0/bin:$PATH && cd %WSL_CHIPLAB%/software/examples/%TEST% && make clean 2>/dev/null; make"
if errorlevel 1 (
    echo ERROR: Build failed!
    pause
    exit /b 1
)
echo    Build OK.
echo.

echo [2/4] Configuring simulation...
wsl -d Ubuntu-22.04 -e bash -c "export CHIPLAB_HOME=%WSL_CHIPLAB% && cd %WSL_CHIPLAB%/sims/verilator/run_prog && rm -f config-software.mak && chmod +x configure.sh && bash ./configure.sh --run %TEST% --disable-trace-comp --output-uart-info"
if errorlevel 1 (
    echo ERROR: Configure failed!
    pause
    exit /b 1
)
echo    Configure OK.
echo.

echo [3/4] Compiling Verilator model + testbench...
wsl -d Ubuntu-22.04 -e bash -c "export CHIPLAB_HOME=%WSL_CHIPLAB% && cd %WSL_CHIPLAB%/sims/verilator/run_prog && make compile"
if errorlevel 1 (
    echo ERROR: Compile failed!
    pause
    exit /b 1
)
echo    Compile OK.
echo.

echo [4/4] Running simulation...
wsl -d Ubuntu-22.04 -e bash -c "export CHIPLAB_HOME=%WSL_CHIPLAB% && export PATH=%WSL_CHIPLAB%/toolchains/loongson-gnu-toolchain-8.3-x86_64-loongarch32r-linux-gnusf-v2.0/bin:$PATH && cd %WSL_CHIPLAB%/sims/verilator/run_prog && rm -rf ./obj/%TEST%_obj && mkdir -p ./obj/%TEST%_obj && cp -r %WSL_CHIPLAB%/software/examples/%TEST%/obj ./obj/%TEST%_obj/ && rm -rf ./tmp && mkdir -p ./tmp && cp ./obj/%TEST%_obj/obj/rom.vlog ./tmp/ && cat ./tmp/rom.vlog > ./tmp/ram.dat && ln -sf ../Makefile_run ./tmp/Makefile_run && cd ./tmp && timeout 600 ../output --dump-delay 0 --dump-waveform 0 --time-limit 0"
echo.
echo ===============================================================
echo   Simulation finished.
echo   Logs: %CHIPLAB_HOME%\sims\verilator\run_prog\tmp\uart_output.txt
echo ===============================================================
pause
