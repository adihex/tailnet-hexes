#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
case "$(uname -m)" in
    arm64) target=aarch64-macos.14.0 ;;
    x86_64) target=x86_64-macos.14.0 ;;
    *) printf 'Unsupported Mac architecture\n' >&2; exit 1 ;;
esac
optimize=${1:-ReleaseSafe}
case "$optimize" in
    Debug|ReleaseSafe|ReleaseFast|ReleaseSmall) ;;
    *) printf 'Usage: %s [Debug|ReleaseSafe|ReleaseFast|ReleaseSmall]\n' "$0" >&2; exit 1 ;;
esac
zig build -Doptimize="$optimize" -Dtarget="$target"
app=zig-out/Hexes.app
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp zig-out/bin/hexes "$app/Contents/MacOS/hexes"
cp resources/Info.plist "$app/Contents/Info.plist"
cp resources/Hexes.icns "$app/Contents/Resources/Hexes.icns"
codesign --force --sign - --identifier net.adihex.hexes "$app"
printf 'Built %s/%s (%s)\n' "$(pwd)" "$app" "$optimize"
