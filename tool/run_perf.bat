@echo off
chcp 65001 >nul
setlocal

if "%1"=="" goto usage

set BENCH=%1
set WSL_PERF=/home/dorcus_t/chiplab/software/examples/nscscc_perf_verilator
set WSL_CHIPLAB=/home/dorcus_t/chiplab
set PC_TRACE=
set DUMP_WAVE=
set DIFFTEST=--disable-trace-comp

:parse_args
if "%2"=="-v" set PC_TRACE=--show-pc-info
if "%2"=="-w" set DUMP_WAVE=--dump-waveform 1
if "%2"=="-d" set DIFFTEST=
if "%3"=="-v" set PC_TRACE=--show-pc-info
if "%3"=="-w" set DUMP_WAVE=--dump-waveform 1
if "%3"=="-d" set DIFFTEST=
if "%4"=="-v" set PC_TRACE=--show-pc-info
if "%4"=="-w" set DUMP_WAVE=--dump-waveform 1
if "%4"=="-d" set DIFFTEST=

echo ===============================================================
echo   nscscc_perf/%BENCH% Verilator Simulation
if "%PC_TRACE%"=="--show-pc-info" echo   (verbose: per-cycle PC)
if "%DUMP_WAVE%"=="--dump-waveform 1" echo   (waveform: fst)
if "%DIFFTEST%"=="" echo   (difftest: enabled)
echo ===============================================================
echo.

echo [1/4] Building %BENCH%...
wsl -d Ubuntu-22.04 -e bash -c "export PATH=/home/dorcus_t/chiplab/toolchains/loongson-gnu-toolchain-8.3-x86_64-loongarch32r-linux-gnusf-v2.0/bin:$PATH; cd %WSL_PERF%; make %BENCH%"
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
wsl -d Ubuntu-22.04 -e bash -c "export CHIPLAB_HOME=%WSL_CHIPLAB%; RUN_DIR=%WSL_CHIPLAB%/sims/verilator/run_prog; rm -rf $RUN_DIR/obj/perf_%BENCH%_obj; mkdir -p $RUN_DIR/obj/perf_%BENCH%_obj; cp -r %WSL_PERF%/obj/%BENCH% $RUN_DIR/obj/perf_%BENCH%_obj/obj; rm -rf $RUN_DIR/tmp; mkdir -p $RUN_DIR/tmp; cp %WSL_PERF%/obj/%BENCH%/rom.vlog $RUN_DIR/tmp/; cat $RUN_DIR/tmp/rom.vlog > $RUN_DIR/tmp/ram.dat; cd $RUN_DIR/tmp; ln -sf ../Makefile_run .; timeout 1800 ../output --dump-delay 0 %DUMP_WAVE% --time-limit 0 %PC_TRACE%; if [ -f logs/simu_trace.fst ]; then cp logs/simu_trace.fst %WSL_CHIPLAB%/IP/myCPU/tool/; fi"
echo.
echo ===============================================================
echo   Simulation finished.
if "%DUMP_WAVE%"=="--dump-waveform 1" echo   Waveform: tool\simu_trace.fst
echo ===============================================================
pause
goto :eof

:usage
echo Usage: run_perf.bat bench [-v] [-w] [-d]
echo.
echo Benchmarks:
echo   quick_sort  select_sort  bubble_sort  dhrystone  coremark
echo   stream_copy  bitcount  crc32  sha  stringsearch
echo   inner_product  lookup_table  loop_induction
echo   minmax_sequence  my_memcmp
echo   fireye_A0  fireye_B2  fireye_C0  fireye_D1  fireye_I2
echo.
echo Options:  -v (per-cycle PC)  -w (fst waveform)  -d (difftest)
pause
exit /b 1
