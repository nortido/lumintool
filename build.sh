#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/private/tmp}/lumintool-clang"
export SWIFTPM_MODULECACHE_OVERRIDE="${TMPDIR:-/private/tmp}/lumintool-module"
build_root="${TMPDIR:-/private/tmp}/lumintool-release"
cache_root="${TMPDIR:-/private/tmp}/lumintool-cache"
swift build -c release --disable-sandbox --cache-path "$cache_root" --scratch-path "$build_root"
bin_dir=$(swift build -c release --disable-sandbox --cache-path "$cache_root" --scratch-path "$build_root" --show-bin-path)
app_dir="$build_root/LuminTool.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$bin_dir/LuminTool" "$app_dir/Contents/MacOS/LuminTool"
iconset_dir="$build_root/LuminTool.iconset"
mkdir -p "$iconset_dir"
for icon_size in 16 32 128 256 512; do
    sips -z "$icon_size" "$icon_size" Assets/LuminTool.png --out "$iconset_dir/icon_${icon_size}x${icon_size}.png" >/dev/null
    icon_double=$((icon_size * 2))
    sips -z "$icon_double" "$icon_double" Assets/LuminTool.png --out "$iconset_dir/icon_${icon_size}x${icon_size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset_dir" -o "$app_dir/Contents/Resources/LuminTool.icns"
cp -R Resources/en.lproj Resources/ru.lproj "$app_dir/Contents/Resources/"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.nortido.LuminTool</string>
<key>CFBundleName</key><string>LuminTool</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>ru</string></array>
<key>CFBundleExecutable</key><string>LuminTool</string>
<key>CFBundleIconFile</key><string>LuminTool.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.5.0</string>
<key>CFBundleVersion</key><string>15</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>LuminTool gets illuminance from your sensors on your home network.</string>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST
xattr -dr com.apple.FinderInfo "$app_dir" 2>/dev/null || true
xattr -dr com.apple.ResourceFork "$app_dir" 2>/dev/null || true
sign_identity="LuminTool Code Signing"
identities=$(security find-identity -p codesigning 2>/dev/null || true)
if [[ "$identities" == *"\"$sign_identity\""* ]]; then
    codesign --force --timestamp=none --sign "$sign_identity" "$app_dir"
else
    print -u2 -r -- "warning: signing identity \"$sign_identity\" not found, signing ad-hoc"
    codesign --force --sign - "$app_dir"
fi
codesign --verify --deep --strict "$app_dir"
touch "$app_dir"
mkdir -p "$PWD/build"
ditto -c -k --norsrc --noextattr --keepParent "$app_dir" "$PWD/build/LuminTool-1.5.0.zip"
print -r -- "$PWD/build/LuminTool-1.5.0.zip"
