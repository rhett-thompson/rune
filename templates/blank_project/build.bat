@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "scriptDirectory=%~dp0"
set rawArguments=%*
set "runeRoot=%RUNE_ROOT%"
set "run=0"
set "release=0"
:parse
if "%~1"=="" goto parsed
if /i "%~1"=="--rune-root" goto rune_root
if /i "%~1"=="-RuneRoot" goto rune_root
if /i "%~1"=="--run" goto run
if /i "%~1"=="-Run" goto run
if /i "%~1"=="--release" goto release
if /i "%~1"=="-Release" goto release
if "%~1"=="--" goto arguments
if /i "%~1"=="--help" goto help
if /i "%~1"=="-h" goto help
echo Unknown option: %~1 1>&2
exit /b 2
:rune_root
if "%~2"=="" (echo %~1 needs an engine directory. 1>&2 & exit /b 2)
set "runeRoot=%~2"
shift
shift
goto parse
:run
set "run=1"
shift
goto parse
:release
set "release=1"
shift
goto parse
:arguments
goto parsed
:parsed
if not defined runeRoot (
    echo Pass --rune-root ^<engine-directory^>, or set RUNE_ROOT to your Rune checkout. 1>&2
    exit /b 1
)
for %%D in ("%runeRoot%") do set "engineRoot=%%~fD"
if not exist "%engineRoot%\rune\core\core.odin" (
    echo Rune engine was not found at "%engineRoot%". 1>&2
    exit /b 1
)
where odin >nul 2>nul
if errorlevel 1 (echo Odin was not found on PATH. 1>&2 & exit /b 1)
pushd "%scriptDirectory%" || exit /b 1
if not exist build mkdir build
if not exist build (popd & exit /b 1)
set "optimization="
if "%release%"=="1" set "optimization=-o:speed"
odin build . "-collection:rune=%engineRoot%\rune" -out:build/game.exe %optimization%
set "result=%errorlevel%"
if not "%result%"=="0" (
    echo Game build failed ^(exit %result%^). 1>&2
    popd
    exit /b %result%
)
echo Built "%CD%\build\game.exe"
if "%run%"=="0" (popd & exit /b 0)
set "executable=%CD%\build\game.exe"
call :run_game
set "result=%errorlevel%"
if not "%result%"=="0" echo Game exited with code %result%. 1>&2
popd
exit /b %result%
:run_game
rem Preserve the raw tail: CMD treats equals signs as delimiters in %%1.
rem Delayed expansion here keeps quoted paths, metacharacters, and literal !
rem intact because values expanded through !variables! are not rescanned.
setlocal EnableDelayedExpansion
set "quoted=0"
set "tokenStart=1"
set "gameArguments="
:scan_arguments
if not defined rawArguments goto launch_game
if "!quoted!!tokenStart!"=="01" (
    if "!rawArguments:~0,3!"=="-- " (
        set "gameArguments=!rawArguments:~3!"
        goto launch_game
    )
    if "!rawArguments!"=="--" goto launch_game
)
set "character=!rawArguments:~0,1!"
set "withoutQuote=!character:"=!"
if not defined withoutQuote set /a quoted=1-quoted >nul
set "tokenStart=0"
if "!quoted!!character!"=="0 " set "tokenStart=1"
set "rawArguments=!rawArguments:~1!"
goto scan_arguments
:launch_game
"!executable!" !gameArguments!
set "result=!errorlevel!"
endlocal & exit /b %result%
:help
echo Usage: build.bat [--rune-root ^<directory^>] [--release] [--run] [-- ^<game arguments^>]
echo RUNE_ROOT can also point to your Rune checkout.
exit /b 0
