#!/bin/zsh
# Costruisce dist/Dolly.app (+ Dolly.zip): app nativa in Swift/SwiftUI (universale arm64 + x86_64) con dentro mpv.
# mpv è x86_64: gira nativo sui Mac Intel e, tramite Rosetta 2, sui Mac Apple Silicon.
# Per rinominare l'app basta cambiare NAME e BUNDLE_ID qui sotto.
# SDK 15.2: con il solo CommandLineTools gli SDK più recenti non trovano il plugin dei macro di SwiftUI (@State).
set -e; cd "$(dirname "$0")"
NAME="Dolly Projector"; EXE=Dolly; BUNDLE_ID=app.dollyprojector.Dolly; VERSION=${VERSION:-0.3.1}   # EXE: nome del programma dentro il pacchetto
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX15.2.sdk
A="dist/$NAME.app"; rm -rf "$A"; mkdir -p "$A/Contents/MacOS" "$A/Contents/Resources"
# target 13.0 anche per x86_64: sotto, il CommandLineTools qui installato non ha le librerie di compatibilità x86_64
swiftc -O -sdk $SDK -target arm64-apple-macos13.0 swift/*.swift -o /tmp/$EXE.arm64
swiftc -O -sdk $SDK -target x86_64-apple-macos13.0 swift/*.swift -o /tmp/$EXE.x86_64
lipo -create /tmp/$EXE.arm64 /tmp/$EXE.x86_64 -output "$A/Contents/MacOS/$EXE"
cp icon/Dolly.icns "$A/Contents/Resources/Dolly.icns"
cp -R /Applications/mpv.app "$A/Contents/Resources/mpv-x86_64.app"    # build x86_64: Mac Intel (e Apple Silicon via Rosetta se manca la nativa)
lipo -archs "$A/Contents/Resources/mpv-x86_64.app/Contents/MacOS/mpv" | grep -q x86_64 || { echo "mpv-x86_64.app non è x86_64"; exit 1; }
# build nativa arm64 (vendor/mpv-arm64.app, da laboratory.stolendata.net/~djinn/mpv_osx): sugli Apple Silicon parte in 0,5 s invece di ~20 s sotto Rosetta
ARM=${MPV_ARM64:-vendor/mpv-arm64.app}
[ -d "$ARM" ] && lipo -archs "$ARM/Contents/MacOS/mpv" | grep -q arm64 || { echo "manca l'mpv arm64: $ARM"; exit 1; }
cp -R "$ARM" "$A/Contents/Resources/mpv-arm64.app"
# versione minima di macOS = la più alta richiesta da mpv e dalle sue librerie (l'mpv attuale chiede macOS 15)
MIN_OS=$( { otool -arch x86_64 -l "$A/Contents/Resources/mpv-x86_64.app/Contents/MacOS/mpv"; for f in "$A"/Contents/Resources/mpv-x86_64.app/Contents/MacOS/lib/*.dylib "$A"/Contents/Resources/mpv-x86_64.app/Contents/Frameworks/*.dylib(N); do otool -arch x86_64 -l "$f"; done } 2>/dev/null | awk '/LC_BUILD_VERSION/{b=1} b&&/minos/{print $2; b=0}' | sort -V | tail -1 )
MIN_OS=${MIN_OS%%.*}.0; [ "${MIN_OS%%.*}" -lt 13 ] && MIN_OS=13.0
echo "macOS minimo richiesto: $MIN_OS"
cat > "$A/Contents/Info.plist" <<P
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleName</key><string>$NAME</string><key>CFBundleDisplayName</key><string>$NAME</string><key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleExecutable</key><string>$EXE</string><key>CFBundleIconFile</key><string>Dolly</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleVersion</key><string>$VERSION</string><key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>LSMinimumSystemVersion</key><string>$MIN_OS</string><key>LSApplicationCategoryType</key><string>public.app-category.video</string><key>NSHighResolutionCapable</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>Il telecomando dal telefono usa la rete locale per comandare la proiezione.</string><key>NSPrincipalClass</key><string>NSApplication</string></dict></plist>
P
codesign --force --deep -s - "$A" 2>/dev/null || true                 # firma ad-hoc; per la distribuzione pubblica servono firma Developer ID e notarizzazione
ZIP="Dolly-Projector.zip"; rm -f "dist/Dolly.zip" "dist/$ZIP"; (cd dist && ditto -c -k --keepParent "$NAME.app" "$ZIP")
du -sh "$A" "dist/$ZIP"
