#!/bin/bash

# Change to exactly the root directory of the repository safely
cd "$(dirname "$0")/.." || exit

# Configuration
APP_NAME="Deks"
APP_DIR="$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ICON_SOURCE="assets/deks-icon-512.png"
ICON_SET="assets/DeksIcon.iconset"
ICNS_FILE="assets/AppIcon.icns"

echo "🔨 Building Deks Release Executable..."
swift build -c release

echo "📦 Creating App Bundle Structure..."
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

echo "🎨 Compiling AppIcon.icns from $ICON_SOURCE..."
if [ -f "$ICON_SOURCE" ]; then
    mkdir -p "$ICON_SET"
    sips -z 16 16     "$ICON_SOURCE" --out "$ICON_SET/icon_16x16.png" > /dev/null
    sips -z 32 32     "$ICON_SOURCE" --out "$ICON_SET/icon_16x16@2x.png" > /dev/null
    sips -z 32 32     "$ICON_SOURCE" --out "$ICON_SET/icon_32x32.png" > /dev/null
    sips -z 64 64     "$ICON_SOURCE" --out "$ICON_SET/icon_32x32@2x.png" > /dev/null
    sips -z 128 128   "$ICON_SOURCE" --out "$ICON_SET/icon_128x128.png" > /dev/null
    sips -z 256 256   "$ICON_SOURCE" --out "$ICON_SET/icon_128x128@2x.png" > /dev/null
    sips -z 256 256   "$ICON_SOURCE" --out "$ICON_SET/icon_256x256.png" > /dev/null
    sips -z 512 512   "$ICON_SOURCE" --out "$ICON_SET/icon_256x256@2x.png" > /dev/null
    sips -z 512 512   "$ICON_SOURCE" --out "$ICON_SET/icon_512x512.png" > /dev/null
    cp "$ICON_SOURCE" "$ICON_SET/icon_512x512@2x.png"
    
    iconutil -c icns "$ICON_SET" -o "$ICNS_FILE"
    rm -rf "$ICON_SET"
    
    cp "$ICNS_FILE" "$RESOURCES_DIR/"
else
    echo "⚠️ Warning: $ICON_SOURCE not found! The app will not have a custom icon."
fi

echo "📋 Writing Info.plist..."
cat > "$CONTENTS_DIR/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Deks</string>
    <key>CFBundleIdentifier</key>
    <string>com.neelbansal.deks</string>
    <key>CFBundleName</key>
    <string>Deks</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/> <!-- Runs as accessory without polluting dock -->
</dict>
</plist>
EOF

echo "🚀 Copying compiled binary into bundle..."
cp .build/release/Deks "$MACOS_DIR/"

echo "✅ Success! Packed tightly into Deks.app."
echo "You can now drag Deks.app into your /Applications folder, or simply double click to run!"
