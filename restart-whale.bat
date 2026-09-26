@echo off
powershell -NoProfile -Command "Get-CimInstance Win32_Process -Filter 'Name=''powershell.exe'''" | Where-Object { $_.CommandLine -like '*whale-pet.ps1*' -and $_.ProcessId -ne $PID } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }"
timeout /t 1 /nobreak >nul
start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0whale-pet.ps1"
echo Whale pet restarted.
timeout /t 2 /nobreak >nul
