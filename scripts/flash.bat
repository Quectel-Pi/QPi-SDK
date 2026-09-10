@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%..") do set "SDK_ROOT=%%~fI"
set "FW_DIR=%SDK_ROOT%\build\output"
set "QFIL_DIR=%SDK_ROOT%\tools\qfil"

set "FS_TYPE=%~1"
if "%FS_TYPE%"=="" set "FS_TYPE=ufs"

set "FIREHOSE=prog_firehose_Qcm6490_ddr.elf"
set "SAHARA=%QFIL_DIR%\QSaharaServer.exe"
set "FHLOADER=%QFIL_DIR%\fh_loader.exe"

echo ==========================================
echo [simple-h1] Windows QFIL 后端烧录
echo   固件目录: %FW_DIR%
echo   后端工具: %QFIL_DIR%
echo   存储类型: %FS_TYPE%
echo ==========================================
echo.

if not exist "%SAHARA%"   ( echo [ERROR] 缺少后端: %SAHARA%   & exit /b 1 )
if not exist "%FHLOADER%" ( echo [ERROR] 缺少后端: %FHLOADER% & exit /b 1 )

if not exist "%FW_DIR%" (
    echo [ERROR] 固件目录不存在: %FW_DIR%
    echo         请先运行打包: SKIP_KERNEL=1 ./scripts/build-all.sh  或  ./scripts/build-all.sh
    exit /b 1
)

for %%F in ("%FIREHOSE%" "efi.bin" "system.img" "dtb.bin") do (
    if not exist "%FW_DIR%\%%~F" (
        echo [ERROR] 固件缺少 %%~F
        echo         请先运行 ./scripts/build-all.sh
        exit /b 1
    )
)

set "PART_DIR=%FW_DIR%\partition_%FS_TYPE%"
if not exist "%PART_DIR%" (
    echo [ERROR] 缺少分区目录: %PART_DIR%
    exit /b 1
)

echo [1/3] 查找 Qualcomm 9008 EDL 设备 (需先让设备进入 EDL 模式)...
set "PORT="
for /f "usebackq delims=" %%P in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "$d=Get-CimInstance Win32_PnPEntity ^| Where-Object { $_.DeviceID -like '*VID_05C6^&PID_9008*' } ^| Select-Object -First 1; if($d -and $d.Name -match '(COM\d+)'){ $matches[1] }"`) do set "PORT=%%P"

if "%PORT%"=="" (
    echo [ERROR] 未检测到 9008 EDL 设备。
    echo         请确认:
    echo           - 设备已进入 EDL: 正常运行的系统执行  adb shell reboot edl
    echo           - panic 状态: 断电重新上电, 按住 EDL 组合键
    echo           - 已安装 Qualcomm USB 驱动 (QPST/LIBUSB 驱动包)
    exit /b 1
)
echo       已检测到: %PORT%
echo.

pushd "%FW_DIR%" || exit /b 1

echo [2/3] Sahara: 推送 firehose 程序 (%FIREHOSE%)...
"%SAHARA%" -p %PORT% -s 13:%FIREHOSE% -v 1
if errorlevel 1 (
    echo [ERROR] Sahara 推送失败
    popd
    exit /b 1
)
echo.

echo [3/3] Firehose: 全盘烧录 (LUN 0-5 rawprogram + patch)...
set "XMLLIST="
for %%L in (0 1 2 3 4 5) do (
    if exist "partition_%FS_TYPE%\rawprogram%%L.xml" (
        if defined XMLLIST (
            set "XMLLIST=!XMLLIST!,partition_%FS_TYPE%\rawprogram%%L.xml"
        ) else (
            set "XMLLIST=partition_%FS_TYPE%\rawprogram%%L.xml"
        )
    )
    if exist "partition_%FS_TYPE%\patch%%L.xml" (
        set "XMLLIST=!XMLLIST!,partition_%FS_TYPE%\patch%%L.xml"
    )
)

if "%XMLLIST%"=="" (
    echo [ERROR] 未找到任何 rawprogram/patch xml
    popd
    exit /b 1
)

"%FHLOADER%" --port=%PORT% --sendxml="%XMLLIST%" --search_path="%FW_DIR%" --noprompt --memoryname=%FS_TYPE% --loglevel=1
set "RC=%ERRORLEVEL%"
popd

echo.
if not "%RC%"=="0" (
    echo [ERROR] fh_loader 烧录失败 (rc=%RC%)
    exit /b %RC%
)

echo ==========================================
echo [simple-h1] 烧录完成
echo   请断电重新上电启动设备
echo ==========================================
endlocal
exit /b 0
