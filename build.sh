#!/bin/zsh
# Builds AutoClicker.app next to this script.
set -e
cd "$(dirname "$0")"
APP=AutoClicker.app
rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp Fonts/ChicagoFLF.ttf $APP/Contents/Resources/
swiftc -O -swift-version 5 -parse-as-library AutoClicker.swift -o $APP/Contents/MacOS/AutoClicker
cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>AutoClicker</string>
  <key>CFBundleIdentifier</key><string>com.tylerhooper.autoclicker</string>
  <key>CFBundleExecutable</key><string>AutoClicker</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>ATSApplicationFontsPath</key><string>.</string>
</dict></plist>
PLIST
codesign --force --sign - $APP
echo "Built $PWD/$APP"
