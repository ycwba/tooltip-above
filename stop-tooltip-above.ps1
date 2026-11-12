# stop-tooltip-above.ps1 — 停止 tooltip-above 常驻脚本
$ErrorActionPreference = 'SilentlyContinue'
$dir = $PSScriptRoot
Set-Content -Path (Join-Path $dir 'tooltip-above.stop') -Value 'stop' -Encoding ascii
Start-Sleep -Milliseconds 500
$procs = Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" | Where-Object {
    $_.CommandLine -match 'tooltip-above\.ps1' -and $_.CommandLine -notmatch 'stop-tooltip-above'
}
if ($procs) {
    $procs | ForEach-Object { Stop-Process -Id $_.ProcessId -Force; "已停止 PID=$($_.ProcessId)" }
} else {
    'tooltip-above 当前未在运行'
}
$pidFile = Join-Path $dir 'tooltip-above.pid'
if (Test-Path $pidFile) { Remove-Item $pidFile -Force -ErrorAction SilentlyContinue }
