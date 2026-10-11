@echo off
setlocal
pushd "%~dp0"
if errorlevel 1 (
    echo Could not open the Rune directory.
    pause
    exit /b 1
)

if "%RUNE_EXAMPLES_PREBUILT%"=="1" goto prebuilt
where odin >nul 2>nul
if errorlevel 1 goto prebuilt

if exist "third_party\r3d-odin\r3d\" (
    call tools\prepare_r3d.bat
    if errorlevel 1 (popd & exit /b 1)
)
if not exist "build\" mkdir "build"
if not exist "build\" (
    echo Could not create the build directory.
    popd
    pause
    exit /b 1
)

rem R3D/Assimp uses bundled /GL zlib; MSVC supports its LTCG objects.
odin run examples/launcher -o:none -collection:rune=rune -linker:msvc -out:build/launcher.exe
set "launcher_exit=%errorlevel%"
goto finished

:prebuilt
if not exist "build\launcher.exe" (
    echo Missing build\launcher.exe. Build the examples first, or install Odin.
    popd
    exit /b 127
)
set "RUNE_EXAMPLES_PREBUILT=1"
build\launcher.exe
set "launcher_exit=%errorlevel%"

:finished
if not "%launcher_exit%"=="0" (
    echo Launcher failed with exit code %launcher_exit%.
    pause
)
popd
exit /b %launcher_exit%
