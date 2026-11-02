@echo off
rem Stand-in for an agent CLI in the Windows measurement: stays alive for ten minutes, prints what it was given.
title win-measure-stub
echo win-measure-stub started %*
ping -n 600 127.0.0.1 >nul
