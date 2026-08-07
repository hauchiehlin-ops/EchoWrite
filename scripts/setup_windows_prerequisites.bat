@echo off
setlocal

echo ==============================================================================
echo 🚀 EchoWrite Windows 前置環境檢查與自動安裝
echo ==============================================================================

:: 呼叫 PowerShell 執行自動檢查與靜默安裝
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup_windows_prerequisites.ps1"

pause
