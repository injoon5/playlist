#!/usr/bin/env bash
# Build "Playlist Gen.app" into macos/build/.
#
#   macos/build-app.sh            # release build
#   macos/build-app.sh --open     # build, then launch
#
# The bundle records this repository's path (PlaylistGenProjectRoot) so the
# app finds the Python backend wherever you move the .app. Override it in
# the app's Settings (⌘,) if you move the repository.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"
app="$here/build/Playlist Gen.app"

swift build --package-path "$here" -c release --product PlaylistGen
bin="$(swift build --package-path "$here" -c release --show-bin-path)/PlaylistGen"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/PlaylistGen"

# App icon: compile the Icon Composer document (Resources/AppIcon.icon) into
# Assets.car (Liquid Glass renditions) + AppIcon.icns.
icon_out="$(mktemp -d)"
xcrun actool "$here/Resources/AppIcon.icon" --compile "$icon_out" --platform macosx \
    --minimum-deployment-target 27.0 --app-icon AppIcon \
    --output-partial-info-plist "$icon_out/partial.plist" >/dev/null
cp "$icon_out/Assets.car" "$icon_out/AppIcon.icns" "$app/Contents/Resources/"
rm -rf "$icon_out"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Playlist Gen</string>
    <key>CFBundleDisplayName</key><string>Playlist Gen</string>
    <key>CFBundleIdentifier</key><string>dev.playlist-gen.app</string>
    <key>CFBundleExecutable</key><string>PlaylistGen</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>0.3.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>27.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>PlaylistGenProjectRoot</key><string>$repo</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$app" >/dev/null
echo "Built $app"

if [[ "${1:-}" == "--open" ]]; then
    open "$app"
fi
