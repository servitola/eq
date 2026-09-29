#!/bin/zsh
# Build EQ.app from the SwiftPM package.
#   scripts/build-app.sh                      ad-hoc signed, identifier-pinned requirement
#   scripts/build-app.sh --identity "<name>"  Developer ID, hardened runtime, entitlements
# Ad-hoc signatures pin the designated requirement to the cdhash, so every rebuild would look
# like a new app to TCC and lose the System Audio Recording grant; the explicit requirement
# below keeps it for local builds, Developer ID keeps it for released ones.
set -euo pipefail
cd "${0:a:h}/.."

identity=-
while (( $# )); do
  case $1 in
    --identity) identity=$2; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

version=${APP_VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}
[[ -n $version ]] || version=0.0.0-dev
build=$(git rev-list --count HEAD 2>/dev/null || echo 1)

swift build -c release --arch arm64
bin=$(swift build -c release --arch arm64 --show-bin-path)/eq

app=build/EQ.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$bin" "$app/Contents/MacOS/eq"
sed -e "s/__VERSION__/$version/" -e "s/__BUILD__/$build/" Resources/Info.plist > "$app/Contents/Info.plist"

# Made by the binary just built, so they always match its commands; the cask links them into
# Homebrew's completion and man directories. Before signing: the signature seals Resources.
resources=$app/Contents/Resources
mkdir -p "$resources/completions" "$resources/man"
"$app/Contents/MacOS/eq" completions zsh > "$resources/completions/_eq"
"$app/Contents/MacOS/eq" completions bash > "$resources/completions/eq.bash"
"$app/Contents/MacOS/eq" completions fish > "$resources/completions/eq.fish"
"$app/Contents/MacOS/eq" man > "$resources/man/eq.1"
# Where SMAppService.agent(plistName:) looks; eq registers it on first use.
mkdir -p "$app/Contents/Library/LaunchAgents"
cp Resources/com.servitola.eq.daemon.plist "$app/Contents/Library/LaunchAgents/"
# `eq mode driver` installs it from here. PlugIns, not Resources: codesign validates a bundle there
# as nested code, and the app's signature seals it either way.
if [[ $identity == - ]]; then Driver/build.sh --adhoc; else Driver/build.sh --identity "$identity"; fi
mkdir -p "$app/Contents/PlugIns"
ditto Driver/build/EQDriver.driver "$app/Contents/PlugIns/EQDriver.driver"

if [[ $identity == - ]]; then
  codesign --force --sign - --identifier com.servitola.eq \
    --requirements '=designated => identifier "com.servitola.eq"' "$app"
else
  codesign --force --sign "$identity" --options runtime --timestamp \
    --entitlements Resources/eq.entitlements "$app"
fi
codesign --verify --strict --deep "$app"
echo "built $app ($version, build $build, identity: $identity)"
