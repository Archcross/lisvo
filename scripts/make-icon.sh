#!/bin/zsh
# 從 Resources/Icon/AppIcon.svg 產生 Resources/AppIcon.icns（App 圖示）。
#
# 只有改了圖示才需要跑；產出的 .icns 放進版本控制，build-app.sh 直接拿來用，平常編譯不需要 rsvg-convert。
# 需要 rsvg-convert（brew install librsvg）；iconutil 是 macOS 內建的。
set -euo pipefail
cd "${0:A:h:h}"

if ! command -v rsvg-convert >/dev/null; then
  echo "找不到 rsvg-convert，請先執行：brew install librsvg" >&2
  exit 1
fi

SOURCE="Resources/Icon/AppIcon.svg"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"

# iconutil 要的檔名與尺寸：每個點數尺寸各一張 1x、一張 2x。
for size in 16 32 128 256 512; do
  rsvg-convert -w "$size" -h "$size" "$SOURCE" -o "$ICONSET/icon_${size}x${size}.png"
  rsvg-convert -w "$((size * 2))" -h "$((size * 2))" "$SOURCE" -o "$ICONSET/icon_${size}x${size}@2x.png"
done

iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
echo "完成：$(pwd)/Resources/AppIcon.icns"
