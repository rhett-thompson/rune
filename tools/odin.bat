@echo off
setlocal EnableExtensions DisableDelayedExpansion
rem All Rune wrappers share this kernel-held lock. Leave the file in place:
rem deleting a lock file can let later callers lock a different file.
if not defined TEMP (echo TEMP is not set. 1>&2 & exit /b 1)
where odin.exe >nul 2>nul
if errorlevel 1 (echo Odin was not found on PATH. 1>&2 & exit /b 1)

:retry
set "odinLockAcquired="
rem Save stderr before suppressing the expected sharing error on contention.
rem The native compiler inherits handle 9, keeping the lock if CMD is killed.
(
    (
        set "odinLockAcquired=1"
        odin.exe %* 2>&3
        call set "odinResult=%%errorlevel%%"
    ) 9>"%TEMP%\rune-odin-compile.lock"
) 3>&2 2>nul
if defined odinLockAcquired exit /b %odinResult%
if not defined odinWaiting echo Waiting for another Rune Odin command to finish... 1>&2
set "odinWaiting=1"
rem Unlike timeout, ping also waits when stdin is redirected by a build runner.
ping -n 2 127.0.0.1 >nul 2>nul
goto retry
