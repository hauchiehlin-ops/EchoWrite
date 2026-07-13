@echo off
:: EchoWrite Windows Microsoft Store 自動化編譯與打包腳本
:: 輸出：echowrite_core.dll 與 C# 綁定腳本

set "ROOT_DIR=%~dp0.."
pushd "%ROOT_DIR%"

echo === 開始編譯 Windows 專用 Rust 核心庫 (echowrite-core) ===

:: 1. 確保 Windows 64位元 MSVC 編譯 target 已安裝
rustup target add x86_64-pc-windows-msvc

:: 2. 編譯 Rust 為 Dynamic Library (.dll)
echo --- 正在進行 x86_64-pc-windows-msvc Release 編譯 ---
cargo build --release --manifest-path "%ROOT_DIR%\core\Cargo.toml" --target x86_64-pc-windows-msvc

:: 3. 建立輸出資料夾
if not exist "build_win" mkdir build_win

:: 複製二進位 DLL 到 Windows 專案目錄下
copy /Y "%ROOT_DIR%\target\x86_64-pc-windows-msvc\release\echowrite_core.dll" "%ROOT_DIR%\windows\"

:: 4. 建置 Windows C# 專案
echo --- 正在建置 EchoWrite.csproj ---
dotnet build "%ROOT_DIR%\windows\EchoWrite.csproj" -c Release

echo === Windows MS Store 專用 DLL 與 C# 專案編譯完成 ===
popd
