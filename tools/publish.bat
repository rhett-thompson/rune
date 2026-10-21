@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "runeRoot=%~dp0.."
for %%D in ("%runeRoot%") do set "runeRoot=%%~fD"
if not exist "%runeRoot%\build" mkdir "%runeRoot%\build"
if not exist "%runeRoot%\build" exit /b 1
:chooseWorkspace
set "publishWorkspace=%runeRoot%\build\.rune-publish-tool-%RANDOM%-%RANDOM%"
if exist "%publishWorkspace%" goto chooseWorkspace
mkdir "%publishWorkspace%"
if errorlevel 1 exit /b 1
call "%runeRoot%\tools\odin.bat" build "%runeRoot%\tools\publisher" "-collection:rune=%runeRoot%\rune" -linker:msvc "-out:%publishWorkspace%\rune-publish.exe"
if errorlevel 1 goto buildFailed
"%publishWorkspace%\rune-publish.exe" --rune-root "%runeRoot%" %*
set "publishResult=%errorlevel%"
goto cleanup
:buildFailed
set "publishResult=%errorlevel%"
:cleanup
del /q "%publishWorkspace%\rune-publish.exe" >nul 2>nul
rmdir "%publishWorkspace%" >nul 2>nul
exit /b %publishResult%
