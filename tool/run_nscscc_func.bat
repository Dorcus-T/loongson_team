@echo off
chcp 65001 >nul
setlocal

set CHIPLAB_HOME=Z:\home\dorcus_t\chiplab
set WSL_CHIPLAB=/home/dorcus_t/chiplab
set TEST=nscscc_func_verilator
set PC_TRACE=
set DUMP_WAVE=
set DIFFTEST=--disable-trace-comp
set DIFF_FLAG=

:parse_args
if /i "%1"=="-v" set PC_TRACE=--show-pc-info
if /i "%1"=="-w" set DUMP_WAVE=--dump-waveform 1
if /i "%1"=="-d" (
    set DIFFTEST=
    set DIFF_FLAG=--diff
)
shift
if not "%1"=="" goto parse_args

echo ===============================================================
echo   %TEST% Verilator Simulation
if "%PC_TRACE%"=="--show-pc-info" echo   (verbose: per-cycle PC enabled)
if "%DUMP_WAVE%"=="--dump-waveform 1" echo   (waveform: fst enabled)
if "%DIFFTEST%"=="" echo   (difftest: NEMU compare enabled)
echo ===============================================================
echo.

echo [1/4] Building test program...
wsl -d Ubuntu-22.04 -e bash -c "export CHIPLAB_HOME=%WSL_CHIPLAB% && export PATH=%WSL_CHIPLAB%/toolchains/loongson-gnu-toolchain-8.3-x86_64-loongarch32r-linux-gnusf-v2.0/bin:$PATH && cd %WSL_CHIPLAB%/software/examples/%TEST% && make"
if errorlevel 1 (
    echo ERROR: Build failed!
    pause
    exit /b 1
)
echo    Build OK.
echo.

echo [2/4] Configuring simulation...
wsl -d Ubuntu-22.04 -e bash -c "export CHIPLAB_HOME=%WSL_CHIPLAB% && cd %WSL_CHIPLAB%/sims/verilator/run_prog && rm -f config-software.mak && chmod +x configure.sh && bash ./configure.sh --run %TEST% %DIFFTEST% --output-uart-info"
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
wsl -d Ubuntu-22.04 -e bash -c "export CHIPLAB_HOME=%WSL_CHIPLAB% && export PATH=%WSL_CHIPLAB%/toolchains/loongson-gnu-toolchain-8.3-x86_64-loongarch32r-linux-gnusf-v2.0/bin:$PATH && cd %WSL_CHIPLAB%/sims/verilator/run_prog && rm -rf ./obj/%TEST%_obj && mkdir -p ./obj/%TEST%_obj && cp -r %WSL_CHIPLAB%/software/examples/%TEST%/obj ./obj/%TEST%_obj/ && rm -rf ./tmp && mkdir -p ./tmp && cp ./obj/%TEST%_obj/obj/rom.vlog ./tmp/ && cat ./tmp/rom.vlog > ./tmp/ram.dat && ln -sf ../Makefile_run ./tmp/Makefile_run && cd ./tmp && timeout 1800 ../output --dump-delay 0 %DUMP_WAVE% --time-limit 0 %PC_TRACE% %DIFF_FLAG% && if [ -f logs/simu_trace.fst ]; then cp logs/simu_trace.fst ../../../../../IP/myCPU/tool/; fi"
echo.
echo ===============================================================
echo   Simulation finished.
if "%DUMP_WAVE%"=="--dump-waveform 1" echo   Waveform: tool\simu_trace.fst (gtkwave)
echo   Logs  : %CHIPLAB_HOME%\sims\verilator\run_prog\tmp\uart_output.txt
echo ===============================================================
pause
