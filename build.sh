#!/bin/sh
# Builds build/Earshot.app, universal (Apple Silicon and Intel), ad-hoc signed.
# With a version, also writes the release archive the Homebrew cask installs:
#
#   ./build.sh            # build/Earshot.app, version "dev"
#   ./build.sh 1.0.0      # also dist/earshot-1.0.0.zip and its SHA-256
set -eu
cd "$(dirname "$0")"

version="${1:-dev}"
app=build/Earshot.app
rm -rf build
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" build/tmp

# Must agree with LSMinimumSystemVersion in Info.plist.
for arch in arm64 x86_64; do
    swiftc -O -target "$arch-apple-macos14.0" Sources/*.swift -o "build/tmp/Earshot-$arch"
done
lipo -create build/tmp/Earshot-arm64 build/tmp/Earshot-x86_64 -output "$app/Contents/MacOS/Earshot"

swiftc scripts/make-icon.swift -o build/tmp/make-icon
build/tmp/make-icon "$app/Contents/Resources/AppIcon.icns"
sed "s/__VERSION__/$version/g" Info.plist > "$app/Contents/Info.plist"
codesign --force --sign - --identifier com.gabrielbelli.Earshot "$app"
rm -rf build/tmp
echo "built $app ($version)"

[ "$version" = dev ] && exit 0
mkdir -p dist
# ditto keeps the bundle intact and, with --norsrc, leaves this machine's extended attributes behind.
ditto -c -k --norsrc --keepParent "$app" "dist/earshot-$version.zip"
shasum -a 256 "dist/earshot-$version.zip"
