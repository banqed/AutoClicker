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
# Sign with a stable local identity if one exists, so the Accessibility grant
# survives rebuilds. Ad-hoc signing ties the grant to the binary hash instead.
IDENTITY="${SIGN_IDENTITY:-Tyler Local Code Signing}"
if security find-identity -p codesigning | grep -q "$IDENTITY"; then
  codesign --force --sign "$IDENTITY" $APP
else
  echo "warning: '$IDENTITY' not found, ad-hoc signing (Accessibility resets each build)"
  codesign --force --sign - $APP
fi
echo "Built $PWD/$APP"
