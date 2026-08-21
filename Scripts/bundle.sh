#!/bin/bash
# Assembles Process Compose for macOS.app around the release binary.
set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

APP_NAME="Process Compose for macOS.app"

if [ "${1:-}" = "--name" ]; then
	echo "$APP_NAME"
	exit 0
fi

VERSION="${PROCESS_COMPOSE_MACOS_VERSION:-0.2.0}"
APP="build/$APP_NAME"

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/process-compose-macos "$APP/Contents/MacOS/process-compose-macos"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleDisplayName</key>
	<string>Process Compose for macOS</string>
	<key>CFBundleExecutable</key>
	<string>process-compose-macos</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>me.thales.process-compose-macos</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>Process Compose for macOS</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>${VERSION}</string>
	<key>CFBundleVersion</key>
	<string>${VERSION}</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.developer-tools</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
PLIST

# Ad-hoc signature: enough for a locally built app, and it keeps the firewall
# from re-prompting on every rebuild.
codesign --force --sign - "$APP" > /dev/null

echo "built $APP"
