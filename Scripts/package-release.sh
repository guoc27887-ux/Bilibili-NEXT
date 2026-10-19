#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
cd "$project_dir"
Scripts/build-app.sh
app_dir="$project_dir/../Bilibili NEXT.app"
output_dir="${OUTPUT_DIR:-$project_dir/..}"
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app_dir/Contents/Info.plist")"
stem="Bilibili-NEXT-$version-macOS-arm64"
mkdir -p "$output_dir"
codesign --verify --deep --strict "$app_dir"
ditto -c -k --sequesterRsrc --keepParent "$app_dir" "$output_dir/$stem.zip"
stage_dir="$(mktemp -d "${TMPDIR:-/tmp}/bilibili-next-release.XXXXXX")"
trap 'rm -rf "$stage_dir"' EXIT
mkdir -p "$stage_dir/dmg"
ditto "$app_dir" "$stage_dir/dmg/Bilibili NEXT.app"
ln -s /Applications "$stage_dir/dmg/Applications"
hdiutil create -volname 'Bilibili NEXT' -srcfolder "$stage_dir/dmg" -format UDZO -ov "$output_dir/$stem.dmg"
# Archive only committed source. Never package local build products, account data or media.
git archive --format=zip --prefix="Bilibili-NEXT-$version/" -o "$output_dir/Bilibili-NEXT-source-$version.zip" HEAD
(cd "$output_dir" && shasum -a 256 "$stem.zip" "$stem.dmg" "Bilibili-NEXT-source-$version.zip" > "Bilibili-NEXT-$version-SHA256SUMS.txt")
printf '%s\n' "$output_dir/$stem.zip" "$output_dir/$stem.dmg"
