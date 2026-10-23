#!/bin/zsh
# Builds RigWatch.app and installs it in ~/Applications.
# RIGWATCH_APP picks another destination and RIGWATCH_SWIFT_FLAGS adds swift build flags
# (the Homebrew formula uses both).
set -e
cd "${0:a:h}"
swift build -c release ${=RIGWATCH_SWIFT_FLAGS}
APP=${RIGWATCH_APP:-~/Applications/RigWatch.app}
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/RigWatch "$APP/Contents/MacOS/RigWatch"
# App icon: every size macOS asks for, from the one 1024 px master.
SET=$(mktemp -d)/AppIcon.iconset; mkdir -p "$SET"
for s in 16 32 128 256 512; do
  sips -z $s $s Assets/AppIcon.png --out "$SET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) Assets/AppIcon.png --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>RigWatch</string>
  <key>CFBundleIdentifier</key><string>dev.rigwatch.RigWatch</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleExecutable</key><string>RigWatch</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.5.5</string>
  <key>CFBundleVersion</key><string>13</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "installed $APP"
