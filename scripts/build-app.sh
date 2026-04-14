#!/bin/bash

# Change to exactly the root directory of the repository safely
cd "$(dirname "$0")/.." || exit

# Configuration
APP_NAME="Deks"
APP_DIR="$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
APP_VERSION="${DEKS_VERSION:-0.2.0}"
ICON_SOURCE="assets/deks-icon-512.png"
ICON_SET="assets/DeksIcon.iconset"
ICNS_FILE="assets/AppIcon.icns"
SIGN_IDENTITY="${DEKS_SIGN_IDENTITY:--}"

if [ "$SIGN_IDENTITY" = "-" ]; then
    if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "valid identities found"; then
        echo "⚠️  No code-signing identity detected."
        echo "⚠️  Deks will be ad-hoc signed, and macOS Accessibility trust may need re-toggle after rebuilds."
    fi
fi

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
    <string>$APP_VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$APP_VERSION</string>
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

echo "🔏 Signing app bundle with identity: $SIGN_IDENTITY"
codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_DIR"

echo "🔍 Verifying signature..."
codesign --verify --deep --strict "$APP_DIR"

echo "✅ Success! Packed tightly into Deks.app (version $APP_VERSION)."
echo "You can now copy Deks.app into /Applications, replacing in place to preserve Accessibility permissions when possible."
