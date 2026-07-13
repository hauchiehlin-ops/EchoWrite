#!/bin/bash
set -e

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "=== 1/3 建置 Apple 平台 ==="
bash "$ROOT_DIR/scripts/build_apple.sh"

echo "=== 2/3 建置 Android 平台 ==="
if bash "$ROOT_DIR/scripts/build_android.sh"; then
  :
else
  echo "Android build skipped or failed; continuing with remaining steps."
fi

echo "=== 3/3 建置 Windows 平台 ==="
if command -v cmd.exe >/dev/null 2>&1; then
  if cmd.exe /c "\"$ROOT_DIR\\scripts\\build_windows.bat\""; then
    :
  else
    echo "Windows build skipped or failed; continuing."
  fi
elif command -v cmd >/dev/null 2>&1; then
  if cmd /c "\"$ROOT_DIR\\scripts\\build_windows.bat\""; then
    :
  else
    echo "Windows build skipped or failed; continuing."
  fi
else
  echo "Windows build skipped: this host does not have a Windows command shell."
fi

echo "=== 全平台一鍵建置完成 ==="
