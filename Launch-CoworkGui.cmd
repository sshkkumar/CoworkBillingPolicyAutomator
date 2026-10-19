@'
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0Start-CoworkPolicyGui.ps1"
'@ | Set-Content .\Launch-CoworkGui.cmd -Encoding ASCII
