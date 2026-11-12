@echo off
rem 双击启动 tooltip-above: 把鼠标悬浮信息框移到光标右上角
rem 可选参数: 0=右上角(默认)  1=左上角  2=正上方
set MODE=%~1
if "%MODE%"=="" set MODE=0
start "" /min pwsh -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0tooltip-above.ps1" -Mode %MODE%
exit /b 0
