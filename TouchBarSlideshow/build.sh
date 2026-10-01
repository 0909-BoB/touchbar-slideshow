#!/bin/zsh
# 編譯成 ~/slideshow/Slideshow.app
set -e
cd "$(dirname "$0")"
APP=../Slideshow.app
mkdir -p "$APP/Contents/MacOS"
clang -fobjc-arc -O2 -mmacosx-version-min=11.0 -framework Cocoa -framework ImageIO main.m -o "$APP/Contents/MacOS/Slideshow"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Slideshow</string>
    <key>CFBundleIdentifier</key><string>local.bob.slideshow</string>
    <key>CFBundleName</key><string>Slideshow</string>
    <key>CFBundleDisplayName</key><string>幻燈片</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSMinimumSystemVersion</key><string>11.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF
codesign --force -s - "$APP"
echo "完成: $(cd "$APP" && pwd)"
