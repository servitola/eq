#!/bin/zsh
# Build EQDriver.driver and the probe into Driver/build.
#   Driver/build.sh           Developer ID, hardened runtime, secure timestamp
#   Driver/build.sh --adhoc   ad-hoc signature, for a quick local build
set -euo pipefail
cd "${0:a:h}"

identity="Developer ID Application: Vladislav Konovalov (NZNV266K59)"
while (( $# )); do
  case $1 in
    --adhoc) identity=-; shift ;;
    --identity) identity=$2; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

version=${APP_VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}
[[ -n $version ]] || version=0.0.0-dev
build=$(git rev-list --count HEAD 2>/dev/null || echo 1)

flags=(-std=c++17 -O2 -g -Wall -Wextra -Werror -fvisibility=hidden -fvisibility-inlines-hidden
       -arch arm64 -arch x86_64 -mmacosx-version-min=14.4)

bundle=build/EQDriver.driver
rm -rf "$bundle"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
xcrun clang++ $flags -bundle Source/Driver.cpp -o "$bundle/Contents/MacOS/EQDriver" \
  -framework CoreAudio -framework CoreFoundation -framework IOKit
rm -rf build/EQDriver.dSYM
mv "$bundle/Contents/MacOS/EQDriver.dSYM" build/
sed -e "s/__VERSION__/$version/" -e "s/__BUILD__/$build/" Info.plist > "$bundle/Contents/Info.plist"
plutil -lint -s "$bundle/Contents/Info.plist"

xcrun clang -std=c17 -O2 -Wall -Wextra -Werror -arch arm64 -arch x86_64 -mmacosx-version-min=14.4 \
  Probe/probe.c -o build/probe -framework CoreAudio -framework CoreFoundation

sign=(codesign --force --sign "$identity")
[[ $identity == - ]] || sign+=(--options runtime --timestamp)
$sign --identifier com.servitola.eq.driver "$bundle"
$sign --identifier com.servitola.eq.probe build/probe
codesign --verify --strict "$bundle" build/probe
echo "built $bundle and build/probe ($version, build $build, identity: $identity)"
