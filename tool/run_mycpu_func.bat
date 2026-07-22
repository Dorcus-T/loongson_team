@echo off
chcp 65001 >nul
setlocal

set WSL_FUNC=/home/dorcus_t/chiplab/software/examples/mycpu_func
set WSL_CHIPLAB=/home/dorcus_t/chiplab
set PC_TRACE=
set DUMP_WAVE=
set DIFFTEST=--disable-trace-comp

:parse_args
if /i "%1"=="-v" set PC_TRACE=--show-pc-info
if /i "%1"=="-w" set DUMP_WAVE=--dump-waveform 1
if /i "%1"=="-d" set DIFFTEST=
shift
if not "%1"=="" goto parse_args

echo ===============================================================
echo   mycpu_env/func Verilator Simulation (EXP=0, 79 tests)
if "%PC_TRACE%"=="--show-pc-info" echo   (verbose: per-cycle PC)
if "%DUMP_WAVE%"=="--dump-waveform 1" echo   (waveform: fst)
if "%DIFFTEST%"=="" echo   (difftest: golden_trace.txt)
echo ===============================================================
echo.

echo [1/4] Building test program...
wsl -d Ubuntu-22.04 -e bash -c "export PATH=/home/dorcus_t/chiplab/toolchains/loongson-gnu-toolchain-8.3-x86_64-loongarch32r-linux-gnusf-v2.0/bin:$PATH; cd %WSL_FUNC%; make EXP=0"
if errorlevel 1 (echo ERROR: Build failed! && pause && exit /b 1)
echo    Build OK.
echo.

echo [2/4] Configuring simulation...
wsl -d Ubuntu-22.04 -e bash -c "export CHIPLAB_HOME=%WSL_CHIPLAB%; cd %WSL_CHIPLAB%/sims/verilator/run_prog; rm -f config-software.mak; chmod +x configure.sh; bash ./configure.sh --run nscscc_func %DIFFTEST% --output-uart-info"
if errorlevel 1 (echo ERROR: Configure failed! && pause && exit /b 1)
echo    Configure OK.
echo.

echo [3/4] Compiling Verilator model + testbench...
wsl -d Ubuntu-22.04 -e bash -c "export CHIPLAB_HOME=%WSL_CHIPLAB%; cd %WSL_CHIPLAB%/sims/verilator/run_prog; make compile"
if errorlevel 1 (echo ERROR: Compile failed! && pause && exit /b 1)
echo    Compile OK.
echo.

echo [4/4] Running simulation...
wsl -d Ubuntu-22.04 -e bash -c "export CHIPLAB_HOME=%WSL_CHIPLAB%; RUN_DIR=%WSL_CHIPLAB%/sims/verilator/run_prog; rm -rf $RUN_DIR/obj/mycpu_func_obj; mkdir -p $RUN_DIR/obj/mycpu_func_obj; cp -r %WSL_FUNC%/obj $RUN_DIR/obj/mycpu_func_obj/; cp %WSL_FUNC%/golden_trace.txt $RUN_DIR/obj/mycpu_func_obj/obj/ 2>/dev/null; rm -rf $RUN_DIR/tmp; mkdir -p $RUN_DIR/tmp; cp %WSL_FUNC%/obj/rom.vlog $RUN_DIR/tmp/; cat $RUN_DIR/tmp/rom.vlog > $RUN_DIR/tmp/ram.dat; cp %WSL_FUNC%/golden_trace.txt $RUN_DIR/tmp/ 2>/dev/null; cd $RUN_DIR/tmp; ln -sf ../Makefile_run .; timeout 1800 ../output --dump-delay 0 %DUMP_WAVE% --time-limit 0 %PC_TRACE% --end-pc 1c000100; if [ -f logs/simu_trace.fst ]; then cp logs/simu_trace.fst %WSL_CHIPLAB%/IP/myCPU/tool/; fi"
echo.
echo ===============================================================
echo   Simulation finished.
if "%DUMP_WAVE%"=="--dump-waveform 1" echo   Waveform: tool\simu_trace.fst
echo ===============================================================
pause
