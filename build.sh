#!/bin/zsh
# Builds ThrottleBar.app next to this script and (re)starts it.
set -e
cd "${0:A:h}"
APP=ThrottleBar.app
mkdir -p $APP/Contents/MacOS
cat > $APP/Contents/Info.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>io.github.hsxcix.ThrottleBar</string>
  <key>CFBundleName</key><string>ThrottleBar</string>
  <key>CFBundleExecutable</key><string>ThrottleBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF
swiftc -O main.swift -lIOReport -framework IOKit -o $APP/Contents/MacOS/ThrottleBar
codesign --force --sign - $APP
pkill -x ThrottleBar 2>/dev/null || true
sleep 0.5
open -g $APP
echo "Built and started $PWD/$APP"
