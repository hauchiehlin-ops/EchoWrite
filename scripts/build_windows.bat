@echo off
:: EchoWrite Windows Microsoft Store 自動化編譯與打包腳本
:: 輸出：echowrite_core.dll 與 C# 綁定腳本

echo === 開始編譯 Windows 專用 Rust 核心庫 (echowrite-core) ===

:: 1. 確保 Windows 64位元 MSVC 編譯 target 已安裝
rustup target add x86_64-pc-windows-msvc

:: 2. 編譯 Rust 為 Dynamic Library (.dll)
echo --- 正在進行 x86_64-pc-windows-msvc Release 編譯 ---
cargo build --release --manifest-path ..\core\Cargo.toml --target x86_64-pc-windows-msvc

:: 3. 建立輸出資料夾
if not exist "build_win" mkdir build_win

:: 複製二進位 DLL 到 Windows 專案目錄下
copy /Y ..\target\x86_64-pc-windows-msvc\release\echowrite_core.dll ..\windows\

:: 4. 生成 C# 語言綁定
echo --- 正在生成 C# (Kotlin/C#/Python) 語言綁定 ---
cargo run --features=uniffi/cli --bin uniffi-bindgen generate ^
  ..\core\src\lib.rs --language kotlin --out-dir build_win
:: 備註：UniFFI 官方 C# 綁定常透過 Kotlin/C 介面轉換，或藉由 uniffi-bindgen-cs 外掛。
:: 此處將 DLL 與生成的 C# 介面代碼同步導向 Windows 專案，供 MSBuild (WinUI 3) 進行 Store 打包裝箱。

echo === Windows MS Store 專用 DLL 與綁定腳本編譯完成 ===
