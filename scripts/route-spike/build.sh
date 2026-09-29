#!/bin/zsh
# Builds build/routespike (signed exactly like EQ.app, so its System Audio Recording grant applies)
# and build/SpikeTone.app with a nested SpikeToneHelper.app, the separate "apps" the tests route.
set -euo pipefail
here=${0:a:h}
repo=${here:h:h}
out=$here/build
identity=${IDENTITY:-"Developer ID Application: Vladislav Konovalov (NZNV266K59)"}
rm -rf "$out"
mkdir -p "$out/plist"

# No Info.plist may sit next to the binary: codesign would then seal the directory as a bundle.
sed -e 's/__VERSION__/0/' -e 's/__BUILD__/0/' -e 's|<string>eq</string>|<string>routespike</string>|' \
  "$repo/Resources/Info.plist" > "$out/plist/spike.plist"
plutil -lint -s "$out/plist/spike.plist"
xcrun swiftc -O -swift-version 5 \
  "$here/main.swift" "$here/Audio.swift" "$here/Analysis.swift" "$here/Tests.swift" \
  -o "$out/routespike" \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$out/plist/spike.plist"
sign=(codesign -f -s "$identity" -o runtime --entitlements "$repo/Resources/eq.entitlements" -i com.servitola.eq)
"${sign[@]}" --timestamp "$out/routespike" 2>/dev/null || "${sign[@]}" --timestamp=none "$out/routespike"

xcrun swiftc -O -swift-version 5 "$here/Tone.swift" -o "$out/plist/spiketone"
tone_plist() {
  cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>spiketone</string>
	<key>CFBundleIdentifier</key><string>$1</string>
	<key>CFBundleName</key><string>$2</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>0</string>
	<key>CFBundleVersion</key><string>0</string>
	<key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
}
app=$out/SpikeTone.app
helper=$app/Contents/Frameworks/SpikeToneHelper.app
mkdir -p "$app/Contents/MacOS" "$helper/Contents/MacOS"
tone_plist com.servitola.eq.spike.tone SpikeTone > "$app/Contents/Info.plist"
tone_plist com.servitola.eq.spike.tone.helper SpikeToneHelper > "$helper/Contents/Info.plist"
cp "$out/plist/spiketone" "$app/Contents/MacOS/spiketone"
cp "$out/plist/spiketone" "$helper/Contents/MacOS/spiketone"
codesign -f -s - "$helper"
codesign -f -s - "$app"

codesign --verify --strict "$out/routespike"
codesign --verify --strict --deep "$app"
codesign -dv "$out/routespike" 2>&1 | grep -E '^(Identifier|TeamIdentifier|Info.plist|CodeDirectory|Timestamp|Signed Time)'
echo "built $out/routespike and $app"
