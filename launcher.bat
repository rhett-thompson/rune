@echo off
setlocal
pushd "%~dp0"
if errorlevel 1 (
    echo Could not open the Rune directory.
    pause
    exit /b 1
)

if not exist "build\" mkdir "build"
if not exist "build\" (
    echo Could not create the build directory.
    popd
    pause
    exit /b 1
)

odin run examples/launcher -collection:rune=rune -out:build/launcher.exe
set "launcher_exit=%errorlevel%"
if not "%launcher_exit%"=="0" (
    echo Launcher failed with exit code %launcher_exit%.
    pause
)
popd
exit /b %launcher_exit%
