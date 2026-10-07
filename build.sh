#!/bin/zsh
set -eu
cd "${0:A:h}"
mkdir -p build/'Voice Lab.app'/Contents/MacOS build/module-cache
cat > build/'Voice Lab.app'/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>VoiceLab</string>
<key>CFBundleIdentifier</key><string>local.ramon.voicelab</string>
<key>CFBundleName</key><string>Voice Lab</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSMicrophoneUsageDescription</key><string>Record your voice sample and short English phrases to translate and speak locally on your Mac. Nothing is uploaded.</string>
<key>VoiceLabSourceRoot</key><string>$PWD</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
xcrun swiftc -parse-as-library -swift-version 5 -module-cache-path build/module-cache -target arm64-apple-macosx15.0 -O VoiceLab.swift -o build/'Voice Lab.app'/Contents/MacOS/VoiceLab -framework SwiftUI -framework AVFoundation
codesign --force --sign - build/'Voice Lab.app'
