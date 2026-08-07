# ==============================================================================
# EchoWrite Windows Microsoft Store (MSIX) / Release Packaging Script
# ==============================================================================
param (
    [string]$AppVersion = "2.1.0",
    [string]$BuildNumber = "12",
    [string]$Publisher = "CN=EchoWrite",
    [string]$PublisherDisplayName = "EchoWrite Team"
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = (Resolve-Path "$ScriptDir\..").Path
$DistDir = "$RootDir\dist\windows"
$PublishDir = "$DistDir\EchoWrite-win-x64"

Write-Host "==============================================================================" -ForegroundColor Cyan
Write-Host "🚀 EchoWrite Windows 一鍵編譯與打包 (Version: $AppVersion, Build: $BuildNumber)" -ForegroundColor Cyan
Write-Host "==============================================================================" -ForegroundColor Cyan

Set-Location $RootDir

# 1. 檢查 Rust Target
Write-Host "`n[1/5] 檢查 Rust Windows x86_64 MSVC 工具鏈..." -ForegroundColor Yellow
rustup target add x86_64-pc-windows-msvc

# 2. 編譯 Rust 核心 DLL
Write-Host "`n[2/5] 編譯 Rust 核心動態庫 (echowrite_core.dll)..." -ForegroundColor Yellow
cargo build --release --manifest-path "$RootDir\core\Cargo.toml" --target x86_64-pc-windows-msvc

$CoreDll = "$RootDir\target\x86_64-pc-windows-msvc\release\echowrite_core.dll"
if (-not (Test-Path $CoreDll)) {
    Write-Error "找不到編譯產出之 DLL: $CoreDll"
}
Copy-Item -Path $CoreDll -Destination "$RootDir\windows\" -Force

# 3. 準備輸出目錄
Write-Host "`n[3/5] 準備輸出目錄..." -ForegroundColor Yellow
if (Test-Path $DistDir) {
    Remove-Item -Recurse -Force $DistDir
}
New-Item -ItemType Directory -Path $PublishDir -Force | Out-Null

# 4. 發布 .NET 8 桌面應用
Write-Host "`n[4/5] 發布獨立 .NET 8 桌面應用程式 (win-x64)..." -ForegroundColor Yellow
dotnet publish "$RootDir\windows\EchoWrite.csproj" `
    -c Release `
    -r win-x64 `
    --self-contained true `
    -p:PublishSingleFile=false `
    -p:Version=$AppVersion `
    -p:FileVersion="$AppVersion.$BuildNumber" `
    -p:AssemblyVersion="$AppVersion.$BuildNumber" `
    -o $PublishDir

Copy-Item -Path $CoreDll -Destination $PublishDir -Force

# 5. 打包 ZIP
Write-Host "`n[5/5] 打包為 ZIP 壓縮發行檔案..." -ForegroundColor Yellow
$ZipPath = "$DistDir\EchoWrite-v$AppVersion-Windows-x64.zip"
Compress-Archive -Path "$PublishDir\*" -DestinationPath $ZipPath -Force

Write-Host "`n==============================================================================" -ForegroundColor Green
Write-Host "✅ Windows 打包完成！" -ForegroundColor Green
Write-Host "==============================================================================" -ForegroundColor Green
Write-Host "📁 免安裝執行目錄: $PublishDir" -ForegroundColor White
Write-Host "📦 壓縮檔輸出路徑: $ZipPath" -ForegroundColor White
Write-Host "`n💡 提示: 您可以直接將此目錄運行於 Windows，或使用 MSIX Packaging Tool / msix 打包上架 Microsoft Partner Center！" -ForegroundColor Cyan
