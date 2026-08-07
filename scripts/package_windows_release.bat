@echo off
setlocal enabledelayedexpansion

:: ==============================================================================
:: EchoWrite Windows 一鍵編譯、發布與 Microsoft Store 上架打包腳本
:: ==============================================================================

set "APP_NAME=EchoWrite"
if "%APP_VERSION%"=="" set "APP_VERSION=2.1.0"
if "%BUILD_NUMBER%"=="" set "BUILD_NUMBER=12"

set "SCRIPT_DIR=%~dp0"
set "ROOT_DIR=%SCRIPT_DIR%.."
set "DIST_DIR=%ROOT_DIR%\dist\windows"
set "PUBLISH_DIR=%DIST_DIR%\EchoWrite-win-x64"

echo ==============================================================================
echo 🚀 開始執行 EchoWrite Windows 一鍵打包 (版本: %APP_VERSION% Build %BUILD_NUMBER%)
echo ==============================================================================

cd /d "%ROOT_DIR%"

:: 1. 檢查並安裝 Rust 編譯目標
echo [1/5] 檢查 Rust Windows x86_64 MSVC 工具鏈...
rustup target add x86_64-pc-windows-msvc
if errorlevel 1 (
    echo [ERROR] rustup target add 失敗，請確認已安裝 Rust 與 Visual Studio C++ 工具。
    exit /b 1
)

:: 2. 編譯 Rust 核心動態庫 (echowrite_core.dll)
echo [2/5] 編譯 Rust 核心引擎 (Release 模式)...
cargo build --release --manifest-path "%ROOT_DIR%\core\Cargo.toml" --target x86_64-pc-windows-msvc
if errorlevel 1 (
    echo [ERROR] Rust 核心編譯失敗！
    exit /b 1
)

set "CORE_DLL=%ROOT_DIR%\target\x86_64-pc-windows-msvc\release\echowrite_core.dll"
if not exist "%CORE_DLL%" (
    echo [ERROR] 找不到編譯產出之 DLL: %CORE_DLL%
    exit /b 1
)

:: 複製 DLL 至 Windows 專案根目錄
copy /Y "%CORE_DLL%" "%ROOT_DIR%\windows\" >nul

:: 3. 清理並建立 dist 輸出目錄
echo [3/5] 準備發布輸出目錄...
if exist "%DIST_DIR%" rd /s /q "%DIST_DIR%"
mkdir "%PUBLISH_DIR%"

:: 4. 使用 .NET SDK 發布獨立免安裝執行檔 (Self-Contained win-x64)
echo [4/5] 發布 .NET 8 Windows 桌面應用程式 (win-x64)...
dotnet publish "%ROOT_DIR%\windows\EchoWrite.csproj" ^
    -c Release ^
    -r win-x64 ^
    --self-contained true ^
    -p:PublishSingleFile=false ^
    -p:Version=%APP_VERSION% ^
    -p:FileVersion=%APP_VERSION%.%BUILD_NUMBER% ^
    -p:AssemblyVersion=%APP_VERSION%.%BUILD_NUMBER% ^
    -o "%PUBLISH_DIR%"

if errorlevel 1 (
    echo [ERROR] dotnet publish 失敗！請確認已安裝 .NET 8 SDK。
    exit /b 1
)

:: 確保 echowrite_core.dll 確實存在於發布目錄中
copy /Y "%CORE_DLL%" "%PUBLISH_DIR%\" >nul

:: 5. 壓縮為綠色發布包 (ZIP)
echo [5/5] 打包為 ZIP 壓縮發行包...
set "ZIP_PATH=%DIST_DIR%\EchoWrite-v%APP_VERSION%-Windows-x64.zip"
powershell -NoProfile -Command "Compress-Archive -Path '%PUBLISH_DIR%\*' -DestinationPath '%ZIP_PATH%' -Force"

echo ==============================================================================
echo ✅ Windows 打包成功！
echo ==============================================================================
echo 📁 綠色獨立執行檔目錄: %PUBLISH_DIR%
echo 📦 壓縮發行檔案路徑:   %ZIP_PATH%
echo.
echo 💡 上架 Microsoft Store 指引:
echo 1. 可使用 Microsoft MSIX Packaging Tool 將 %PUBLISH_DIR% 轉換為 .msix 安裝包。
echo 2. 或登入 Microsoft Partner Center (合作夥伴中心) 直接提交 .msix 套件上架！
echo ==============================================================================
