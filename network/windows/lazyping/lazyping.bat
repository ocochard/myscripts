@echo off
::::::::::::::::::::::::::::::::::::::
:: Lazy-ping v0.3
:: License : Public domain
:: Author: Olivier Cochard-Labbé <olivier@cochard.me>
:: Multithreading code based on this example:
:: http://caseelse.net/2008/05/22/multithreading-in-batch-script-part-1-an-example/
::::::::::::::::::::::::::::::::::::::

VERIFY OTHER 2>nul
SETLOCAL ENABLEEXTENSIONS
IF ERRORLEVEL 1 echo Unable to enable extensions
SETLOCAL ENABLEDELAYEDEXPANSION

::::::::::::::::::::::::::::::::::::::
:: Set variables
::::::::::::::::::::::::::::::::::::::

set LOGFILE=c:\lazy-ping.log
set ERRORLOGFILE=c:\lazy-ping-error.log
set maxthread=A B C D E
:: For 10 threads, use:
:: set maxthread=A B C D E F G H I J
set runningthread=0
set childtemplate=lazy-ping_thread.cmd

set strlen=0
for %%A in (%drivestring%) do SET /A strlen+=1

::::::::::::::::::::::::::::::::::::::
:: Initialize log file
::::::::::::::::::::::::::::::::::::::

echo Lazy-ping log file > %LOGFILE%
date /t >> %LOGFILE%
time /t >> %LOGFILE%
echo Lazy-ping ERROR log file > %ERRORLOGFILE%
echo ALL THESES IP are not reacheable!!! > %ERRORLOGFILE%
date /t >> %ERRORLOGFILE%
time /t >> %ERRORLOGFILE%

::::::::::::::::::::::::::::::::::::::
:: Input check
::::::::::::::::::::::::::::::::::::::

if {%1}=={} goto _help
set FICHIER=%1

::::::::::::::::::::::::::::::::::::::
:: File check
::::::::::::::::::::::::::::::::::::::

if NOT exist %FICHIER% (
    echo No input file found !
    goto :EOF
)

::::::::::::::::::::::::::::::::::::::
:: Clean existing file
::::::::::::::::::::::::::::::::::::::

@for %%D in (%maxthread%) do (
   @if exist ping-%%D.bat (
        echo deleting ping-%%D.bat  >> %LOGFILE%
        @del ping-%%D.bat
   )
  )
echo List of IP tested  >> %LOGFILE%

::::::::::::::::::::::::::::::::::::::
:: Generate ping threaded tool
::::::::::::::::::::::::::::::::::::::

echo @echo off > lazy-ping_thread.cmd
echo ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: >> lazy-ping_thread.cmd
echo :: This tool is a part of lazy-ping >> lazy-ping_thread.cmd
echo :: Set variables above. >> lazy-ping_thread.cmd
echo ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: >> lazy-ping_thread.cmd
echo set ERRORLOGFILE=c:\lazy-ping-error.log >> lazy-ping_thread.cmd
echo. >> lazy-ping_thread.cmd
echo set ip=%%2 >> lazy-ping_thread.cmd
echo. >> lazy-ping_thread.cmd
echo Title Thread %%~n0 pinging %%IP%% >> lazy-ping_thread.cmd
echo. >> lazy-ping_thread.cmd
echo ^<nul (set/p z=Running) >> lazy-ping_thread.cmd
echo echo. >> lazy-ping_thread.cmd
echo ping -n 1 -w 1000 %%IP%% >> lazy-ping_thread.cmd
echo if errorlevel 1 echo %%IP%% ^>^> %%ERRORLOGFILE%% >> lazy-ping_thread.cmd
echo echo. >> lazy-ping_thread.cmd
echo. >> lazy-ping_thread.cmd
echo Del %%0 >> lazy-ping_thread.cmd

::::::::::::::::::::::::::::::::::::::
:: Start the main loop for each value in the given file
::::::::::::::::::::::::::::::::::::::

FOR /F "delims=" %%A IN (%FICHIER%) DO (
 call SET /A runningthread+=1
 echo.
 call set IP=%%A
 call :_Threaded-ping %%A
)
goto :EOF

::::::::::::::::::::::::::::::::::::::
:: Help function
::::::::::::::::::::::::::::::::::::::

:_help
echo Lazy Ping v0.3
echo Ping all IP addresses included in the given file
echo.
echo Usage: lazy-ping.cmd [file-name-containing-ip-addresses]
echo.
echo All errors are stored in the file:
echo %ERRORLOGFILE%
echo All logs are stored in the file:
echo %LOGFILE%
echo.
goto :EOF

::::::::::::::::::::::::::::::::::::::
:: Threaded loop
::::::::::::::::::::::::::::::::::::::
:_Threaded-ping
  echo Ping thread #%runningthread%: %IP%

   set newthread=
  @for %%D in (%maxthread%) do (
   @if NOT exist ping-%%D.bat (
    @if NOT exist ping-%%D.bat\nul (call set newthread=%%D)
    @if exist ping-%%D.bat\nul Echo %%D: already running. Skipping.
   )
  )

  if NOT DEFINED newthread (
   <nul (set/p z=.)
   ping -n 2 localhost >nul
   goto _Threaded-ping
  ) ELSE (
   @echo new thread = '%newthread%'
   type %childtemplate% > ping-%newthread%.bat
   echo %IP%  >> %LOGFILE%
   START "%runningthread% -- ping-%newthread%.bat" /min %comspec% /c ping-%newthread%.bat %runningthread% %IP%
