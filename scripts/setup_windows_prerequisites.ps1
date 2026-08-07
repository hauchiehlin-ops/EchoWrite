# ==============================================================================
# EchoWrite Windows 開發與打包環境一鍵檢查與自動安裝腳本 (PowerShell)
# ==============================================================================

Write-Host "==============================================================================" -ForegroundColor Cyan
Write-Host "🔍 正在檢查 EchoWrite Windows 建置環境與前置依賴..." -ForegroundColor Cyan
Write-Host "==============================================================================" -ForegroundColor Cyan

# 檢查系統管理員權限（若需安裝軟體）
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

function Test-CommandExists ($cmd) {
    return [bool](Get-Command $cmd -ErrorAction SilentlyContinue)
}

$needRestart = $false

# 1. 檢查 .NET 8 SDK
Write-Host "`n[1/4] 檢查 .NET 8.0 SDK..." -NoNewline
$dotnetInstalled = $false
if (Test-CommandExists "dotnet") {
    $sdks = dotnet --list-sdks 2>$null
    if ($sdks -match "8\.") {
        $dotnetInstalled = $true
        Write-Host " [OK] 已安裝 .NET 8 SDK" -ForegroundColor Green
    }
}

if (-not $dotnetInstalled) {
    Write-Host " [MISSING] 未偵測到 .NET 8 SDK，準備自動安裝..." -ForegroundColor Yellow
    if (Test-CommandExists "winget") {
        Write-Host "📦 透過 winget 下載安裝 Microsoft .NET 8 SDK..." -ForegroundColor Cyan
        winget install Microsoft.DotNet.SDK.8 --silent --accept-package-agreements --accept-source-agreements
    } else {
        Write-Host "🌐 透過官方安裝檔下載 .NET 8 SDK..." -ForegroundColor Cyan
        $installer = "$env:TEMP\dotnet-sdk-8-win-x64.exe"
        Invoke-WebRequest -Uri "https://dotnetcli.azureedge.net/dotnet/Sdk/8.0.401/dotnet-sdk-8.0.401-win-x64.exe" -OutFile $installer
        Start-Process -FilePath $installer -ArgumentList "/install /quiet /norestart" -Wait
        Remove-Item $installer -Force -ErrorAction SilentlyContinue
    }
    $needRestart = $true
}

# 2. 檢查 Rust 與 cargo
Write-Host "`n[2/4] 檢查 Rust 編譯工具鏈 (rustup & cargo)..." -NoNewline
$rustInstalled = $false
if (Test-CommandExists "cargo" -and Test-CommandExists "rustup") {
    $rustInstalled = $true
    Write-Host " [OK] 已安裝 Rust" -ForegroundColor Green
}

if (-not $rustInstalled) {
    Write-Host " [MISSING] 未偵測到 Rust，準備自動下載安裝..." -ForegroundColor Yellow
    $rustupInit = "$env:TEMP\rustup-init.exe"
    Invoke-WebRequest -Uri "https://win.rustup.rs/x86_64" -OutFile $rustupInit
    Write-Host "📦 正在靜默安裝 Rust (預設配置)..." -ForegroundColor Cyan
    Start-Process -FilePath $rustupInit -ArgumentList "-y --default-toolchain stable" -Wait
    Remove-Item $rustupInit -Force -ErrorAction SilentlyContinue

    # 加入當前 Session 的 PATH
    $env:PATH = "$env:USERPROFILE\.cargo\bin;" + $env:PATH
    $needRestart = $true
}

# 確保 MSVC target 安裝
if (Test-CommandExists "rustup") {
    Write-Host "⚙️ 設定 Rust Windows MSVC target (x86_64-pc-windows-msvc)..." -ForegroundColor Cyan
    rustup target add x86_64-pc-windows-msvc | Out-Null
}

# 3. 檢查 Visual Studio C++ 生成工具 (MSVC)
Write-Host "`n[3/4] 檢查 Visual Studio C++ 建置工具 (MSVC Linker)..." -NoNewline
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vcInstalled = $false

if (Test-Path $vswhere) {
    $vcPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($vcPath) {
        $vcInstalled = $true
        Write-Host " [OK] 已安裝 Visual Studio C++ 建置工具" -ForegroundColor Green
    }
}

if (-not $vcInstalled) {
    Write-Host " [MISSING] 未偵測到 C++ MSVC 編譯工具，準備自動安裝..." -ForegroundColor Yellow
    if (Test-CommandExists "winget") {
        Write-Host "📦 透過 winget 安裝 Visual Studio 2022 Build Tools (含 C++ 工作負載)..." -ForegroundColor Cyan
        winget install Microsoft.VisualStudio.2022.BuildTools --override "--passive --config https://aka.ms/vs/17/release/vs_buildtools.exe --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended" --accept-package-agreements --accept-source-agreements
    } else {
        Write-Host "🌐 下載 Visual Studio 2022 Build Tools 安裝器..." -ForegroundColor Cyan
        $vsInstaller = "$env:TEMP\vs_buildtools.exe"
        Invoke-WebRequest -Uri "https://aka.ms/vs/17/release/vs_buildtools.exe" -OutFile $vsInstaller
        Start-Process -FilePath $vsInstaller -ArgumentList "--quiet --wait --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended" -Wait
        Remove-Item $vsInstaller -Force -ErrorAction SilentlyContinue
    }
    $needRestart = $true
}

# 4. 檢查並確保安裝 Microsoft Visual C++ 2015-2022 Redistributable (x64)
Write-Host "`n[4/4] 檢查 Visual C++ 運行庫 (VCRedist x64)..." -NoNewline
$vcRedistInstalled = $false
$uninstallKeys = @(
    "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall",
    "HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
)
foreach ($key in $uninstallKeys) {
    if (Test-Path $key) {
        $found = Get-ItemProperty "$key\*" | Where-Object { $_.DisplayName -match "Microsoft Visual C\+\+ 20(15|17|19|22).*Redistributable.*x64" }
        if ($found) {
            $vcRedistInstalled = $true
            break
        }
    }
}

if ($vcRedistInstalled) {
    Write-Host " [OK] 已安裝 Visual C++ x64 運行庫" -ForegroundColor Green
} else {
    Write-Host " [MISSING] 未偵測到 VC++ 運行庫，正在自動安裝..." -ForegroundColor Yellow
    if (Test-CommandExists "winget") {
        winget install Microsoft.VCRedist.2015+.x64 --silent --accept-package-agreements --accept-source-agreements
    } else {
        $vcRedistExe = "$env:TEMP\vc_redist.x64.exe"
        Invoke-WebRequest -Uri "https://aka.ms/vs/17/release/vc_redist.x64.exe" -OutFile $vcRedistExe
        Start-Process -FilePath $vcRedistExe -ArgumentList "/install /quiet /norestart" -Wait
        Remove-Item $vcRedistExe -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "`n==============================================================================" -ForegroundColor Green
Write-Host "🎉 環境檢查與配置已就緒！" -ForegroundColor Green
Write-Host "==============================================================================" -ForegroundColor Green

if ($needRestart) {
    Write-Host "⚠️ 注意：剛才已安裝新的編譯工具，建議【關閉此終端機並重新開啟】以套用新的環境變數。" -ForegroundColor Yellow
} else {
    Write-Host "💡 您的 Windows 電腦已具備所有必要工具，可直接執行以下指令進行打包：" -ForegroundColor White
    Write-Host "   .\scripts\package_windows_release.bat" -ForegroundColor Cyan
}
