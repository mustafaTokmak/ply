#!/bin/sh
# Builds dist/Ply.app (universal) and dist/Ply-<version>.zip on a Mac.
# Signing: set PLY_SIGN_IDENTITY="Developer ID Application: ..." to sign for distribution
# (PLY_KEYCHAIN=<path> to use a keychain other than the default). To notarize, set either
# PLY_NOTARY_PROFILE=<notarytool keychain profile>, or an App Store Connect API key:
# PLY_NOTARY_KEY=<AuthKey_XXX.p8 path> PLY_NOTARY_KEY_ID=<key id> PLY_NOTARY_ISSUER=<issuer id>.
# Without PLY_SIGN_IDENTITY the app is ad-hoc signed.
set -e
cd "$(dirname "$0")/.."
VERSION=$(sed -n 's/.*static let version = "\([0-9][0-9.]*\)".*/\1/p' Sources/PlyShared/Shared.swift | head -1)
ARCHS=${PLY_ARCHS:-"--arch arm64 --arch x86_64"}
echo "Building Ply $VERSION ($ARCHS)"
swift build -c release $ARCHS
BIN=$(swift build -c release $ARCHS --show-bin-path)
APP=dist/Ply.app
rm -rf dist && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Library/LaunchServices" "$APP/Contents/Resources"
cp "$BIN/PlyApp" "$APP/Contents/MacOS/Ply"
cp "$BIN/ply" "$APP/Contents/Helpers/ply"
cp "$BIN/ply-helper" "$APP/Contents/Library/LaunchServices/app.ply.helper"
if [ ! -f Resources/AppIcon.icns ]; then
  swift scripts/make-icon.swift build/Ply.iconset >/dev/null && iconutil -c icns build/Ply.iconset -o Resources/AppIcon.icns
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Ply</string>
  <key>CFBundleDisplayName</key><string>Ply</string>
  <key>CFBundleIdentifier</key><string>app.ply.Ply</string>
  <key>CFBundleExecutable</key><string>Ply</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
PLIST
IDENTITY=${PLY_SIGN_IDENTITY:--}
OPTS=""
[ "$IDENTITY" != "-" ] && OPTS="--options runtime --timestamp"
[ -n "$PLY_KEYCHAIN" ] && OPTS="$OPTS --keychain $PLY_KEYCHAIN"
for f in "$APP/Contents/Library/LaunchServices/app.ply.helper" "$APP/Contents/Helpers/ply" "$APP"; do
  codesign --force $OPTS --sign "$IDENTITY" "$f"
done
codesign --verify --strict "$APP"
ZIP="dist/Ply-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
if [ -n "$PLY_NOTARY_KEY" ]; then
  NOTARY_AUTH="--key $PLY_NOTARY_KEY --key-id $PLY_NOTARY_KEY_ID --issuer $PLY_NOTARY_ISSUER"
elif [ -n "$PLY_NOTARY_PROFILE" ]; then
  NOTARY_AUTH="--keychain-profile $PLY_NOTARY_PROFILE"
fi
if [ -n "$NOTARY_AUTH" ] && [ "$IDENTITY" != "-" ]; then
  xcrun notarytool submit "$ZIP" $NOTARY_AUTH --wait
  xcrun stapler staple "$APP"
  rm "$ZIP" && ditto -c -k --keepParent "$APP" "$ZIP"
fi
shasum -a 256 "$ZIP"
echo "Built $APP and $ZIP (signed with: $IDENTITY)"
