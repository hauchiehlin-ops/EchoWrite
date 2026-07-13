@echo off
set "ROOT_DIR=%~dp0.."
pushd "%ROOT_DIR%"

echo === 1/1 建置 Windows 平台 ===
call "%ROOT_DIR%\scripts\build_windows.bat"

echo === Windows 一鍵建置完成 ===
popd
