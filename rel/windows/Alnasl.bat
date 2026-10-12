@echo off
rem Starts Alnasl with a console window: the launcher for when something is
rem wrong and you want to read what the program says. Alnasl.exe beside this
rem file is the one to double-click otherwise.
rem
rem The data goes where Alnasl.exe puts it, outside this folder, so that a
rem new version unzipped beside the old one finds it: see "Where your data
rem lives" in the README. ALNASL_DATA, when it is set, is left alone.
setlocal
if "%ALNASL_DATA%"=="" set ALNASL_DATA=%LOCALAPPDATA%\AlnaslData
if "%PORT%"=="" set PORT=4040
rem What the release writes when it starts goes beside the data, not in here.
if "%RELEASE_TMP%"=="" set RELEASE_TMP=%ALNASL_DATA%\tmp
rem Erlang distribution off (see rel/env.bat.eex). `set
rem RELEASE_DISTRIBUTION=sname` before this file gives a node that
rem `bin\alnasl.bat remote` can attach to, for one session.
if "%RELEASE_DISTRIBUTION%"=="" set RELEASE_DISTRIBUTION=none
echo Starting Alnasl on http://localhost:%PORT%
echo Data: %ALNASL_DATA%
echo Close this window to stop it. The boards are not read while it is stopped.
echo.
"%~dp0bin\alnasl.bat" start
endlocal
