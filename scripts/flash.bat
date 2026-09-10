@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%..") do set "SDK_ROOT=%%~fI"

rem Firmware dir: defaults to the SDK output dir build\result.
rem Override with QPI_FW_DIR to flash an external firmware package
rem (e.g. a vendor test build) without copying it into the SDK.
set "FW_DIR=%SDK_ROOT%\build\result"
if defined QPI_FW_DIR set "FW_DIR=%QPI_FW_DIR%"

set "QFIL_DIR=%SDK_ROOT%\tools\qfil"

set "FS_TYPE=%~1"
if "%FS_TYPE%"=="" set "FS_TYPE=ufs"

set "FIREHOSE=prog_firehose_Qcm6490_ddr.elf"
set "SAHARA=%QFIL_DIR%\QSaharaServer.exe"
set "FHLOADER=%QFIL_DIR%\fh_loader.exe"

echo ==========================================
echo [simple-h1] Windows QFIL Backend Flash
echo   FW_DIR : %FW_DIR%
echo   QFIL   : %QFIL_DIR%
echo   STORAGE: %FS_TYPE%
echo ==========================================
echo.

if not exist "%SAHARA%"   ( echo [ERROR] missing backend: %SAHARA%   & exit /b 1 )
if not exist "%FHLOADER%" ( echo [ERROR] missing backend: %FHLOADER% & exit /b 1 )

if not exist "%FW_DIR%" (
    echo [ERROR] firmware dir not found: %FW_DIR%
    echo         run first: SKIP_KERNEL=1 ./scripts/build-all.sh
    echo         or set QPI_FW_DIR to an external firmware package
    exit /b 1
)

for %%F in ("%FIREHOSE%" "efi.bin" "system.img" "dtb.bin") do (
    if not exist "%FW_DIR%\%%~F" (
        echo [ERROR] firmware missing %%~F
        echo         dir: %FW_DIR%
        echo         run ./scripts/build-all.sh, or check QPI_FW_DIR
        exit /b 1
    )
)

set "PART_DIR=%FW_DIR%\partition_%FS_TYPE%"
if not exist "%PART_DIR%" (
    echo [ERROR] partition dir missing: %PART_DIR%
    exit /b 1
)

echo [1/3] Looking for Qualcomm 9008 EDL device ...
set "PORT="
set "PS_CMD=$d=Get-CimInstance Win32_PnPEntity | Where-Object { $_.DeviceID -like '*VID_05C6&PID_9008*' } | Select-Object -First 1; if($d -and $d.Name -match '(COM\d+)'){ $matches[1] }"
for /f "usebackq delims=" %%P in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "%PS_CMD%"`) do set "PORT=%%P"

if "%PORT%"=="" (
    echo [ERROR] no 9008 EDL device found
    echo         check:
    echo          - device in EDL: on a running system run  adb shell reboot edl
    echo          - panic state: power cycle while holding the EDL keys
    echo          - Qualcomm USB driver installed ^(QPST / LIBUSB driver package^)
    exit /b 1
)

rem Windows requires the \\.\COMn form for COM10 and above; a bare "COM10"
rem fails to open (QSaharaServer: port_connect Failed to open com port handle).
set "PORTARG=\\.\%PORT%"
echo       detected: %PORT%  ^(using %PORTARG%^)
echo.

pushd "%FW_DIR%" || exit /b 1

echo [2/3] Sahara: push firehose programmer ^(%FIREHOSE%^) ...
"%SAHARA%" -p "%PORTARG%" -s 13:%FIREHOSE% -v 1
if errorlevel 1 (
    echo [ERROR] Sahara failed
    popd
    exit /b 1
)
echo.

echo [3/3] Firehose: full flash ^(LUN 0-5 rawprogram + patch^) ...
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
    echo [ERROR] no rawprogram/patch xml found
    popd
    exit /b 1
)

"%FHLOADER%" --port="%PORTARG%" --sendxml="%XMLLIST%" --search_path="%FW_DIR%" --noprompt --memoryname=%FS_TYPE% --loglevel=1
set "RC=%ERRORLEVEL%"
popd

echo.
if not "%RC%"=="0" (
    echo [ERROR] fh_loader failed ^(rc=%RC%^)
    exit /b %RC%
)

echo ==========================================
echo [simple-h1] flash done
echo   power cycle the device to boot
echo ==========================================
endlocal
exit /b 0
