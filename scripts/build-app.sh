#!/bin/zsh
# 編譯並組成 build/Lisvo.app，只能在這台 Mac 上執行。
#
# 簽署：鑰匙圈裡有名為「Lisvo Local Signing」的自簽程式碼簽署憑證時用它簽，否則用臨時簽署（ad-hoc）。
# 臨時簽署每次重新建置，macOS 都會當成新的 App，「螢幕與系統錄音」等權限要重新允許；
# 用固定憑證簽署，權限會跟著憑證走，重新建置不用再允許。也可以用 LISVO_SIGN_IDENTITY 指定其他憑證名稱。
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

CONFIG="${1:-release}"
swift build -c "$CONFIG" --product TranscriberApp
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

APP="$ROOT/build/Lisvo.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/TranscriberApp" "$APP/Contents/MacOS/Transcriber"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
[[ -f "$ROOT/Resources/AppIcon.icns" ]] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"
# 各語言的 App 名稱（例如繁體中文顯示「聽哦」）。
for lproj in "$ROOT/Resources"/*.lproj(N); do
  cp -R "$lproj" "$APP/Contents/Resources/"
done

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

IDENTITY="${LISVO_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  # 先存成變數再比對：pipefail 下接 grep -q 可能讓 security 收到 SIGPIPE，整條判斷變成失敗。
  KNOWN_IDENTITIES="$(security find-identity -p codesigning 2>/dev/null || true)"
  if [[ "$KNOWN_IDENTITIES" == *'"Lisvo Local Signing"'* ]]; then
    IDENTITY="Lisvo Local Signing"
  fi
fi
codesign --force --deep --sign "${IDENTITY:--}" "$APP"
echo "簽署：${IDENTITY:-臨時簽署（ad-hoc）}"
codesign --verify --deep --strict "$APP"
echo "$APP"
