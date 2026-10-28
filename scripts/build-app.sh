#!/bin/zsh
# 編譯並組成 build/逐字稿.app，用本機臨時簽署（ad-hoc），只能在這台 Mac 上執行。
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

CONFIG="${1:-release}"
swift build -c "$CONFIG" --product TranscriberApp
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

APP="$ROOT/build/逐字稿.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/TranscriberApp" "$APP/Contents/MacOS/Transcriber"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
[[ -f "$ROOT/Resources/AppIcon.icns" ]] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"

# SwiftPM 套件的資源包（例如 FluidAudio 的音素表）放進 Resources。
for bundle in "$BIN_DIR"/*.bundle(N); do
  cp -R "$bundle" "$APP/Contents/Resources/"
done

# 動態框架放進 Frameworks，並讓執行檔找得到。
for framework in "$BIN_DIR"/*.framework(N); do
  mkdir -p "$APP/Contents/Frameworks"
  cp -R "$framework" "$APP/Contents/Frameworks/"
done
if [[ -d "$APP/Contents/Frameworks" ]]; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Transcriber" 2>/dev/null || true
fi

codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "$APP"
