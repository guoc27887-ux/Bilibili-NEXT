#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
cd "$project_dir"
if ! command -v rsvg-convert >/dev/null; then
  print -u2 'Install librsvg (brew install librsvg) to render the SVG icon sources.'
  exit 1
fi
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/bilibilinext-icons.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT

# macOS keeps transparent outer margins; iOS supplies its own system mask.
rsvg-convert -w 1024 -h 1024 Assets/Bilibili-NEXT-macOS.svg -o Assets/Bilibili-NEXT-icon.png
rsvg-convert -w 1024 -h 1024 Assets/Bilibili-NEXT-iOS.svg \
  -o Apps/iOS/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png

# Render each size directly from vector geometry for crisp small icons.
iconset="$work_dir/AppIcon.iconset"
mkdir -p "$iconset"
for points in 16 32 128 256 512; do
  rsvg-convert -w "$points" -h "$points" Assets/Bilibili-NEXT-macOS.svg \
    -o "$iconset/icon_${points}x${points}.png"
  pixels=$((points * 2))
  rsvg-convert -w "$pixels" -h "$pixels" Assets/Bilibili-NEXT-macOS.svg \
    -o "$iconset/icon_${points}x${points}@2x.png"
done
iconutil -c icns "$iconset" -o Scripts/AppIcon.icns
print 'Updated macOS PNG / ICNS and iOS AppIcon from the SVG sources.'
