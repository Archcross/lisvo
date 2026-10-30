#!/bin/zsh
# 組成發佈用的壓縮檔 build/Lisvo-版本.zip，上傳到 GitHub Releases。
#
# 先跑 build-app.sh 重新建置（release 設定），再用 ditto 壓縮：ditto 會保留簽署與擴充屬性，
# 用 zip 指令壓縮會弄壞 App 的簽署。版本號讀 Resources/Info.plist 的 CFBundleShortVersionString。
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

"$ROOT/scripts/build-app.sh" release

APP="$ROOT/build/Lisvo.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ZIP="$ROOT/build/Lisvo-$VERSION.zip"

rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
echo "$ZIP"
shasum -a 256 "$ZIP"
