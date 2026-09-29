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
# eq installs the driver it bundles when this is higher than the installed one's, so only commits
# that change what goes into the bundle count: a release that leaves it alone asks for no password.
# The files are the ones compiled in below, not all of Sources/EQCore (the resampler is the
# daemon's); + 1 keeps the count above revision 14, shipped when the whole folder still counted.
core=(../Sources/EQCore/EQCore.c ../Sources/EQCore/EQDriverProtocol.c
      ../Sources/EQCore/include/EQCore.h ../Sources/EQCore/include/EQDriverProtocol.h)
revision=$(( $(git rev-list --count HEAD -- Source Info.plist build.sh $core 2>/dev/null || echo 0) + 1 ))
protocol=$(awk '$1 == "#define" && $2 == "EQC_BLOB_VERSION" { print $3 }' ../Sources/EQCore/include/EQDriverProtocol.h)
[[ $protocol =~ ^[0-9]+$ ]] || { echo "no EQC_BLOB_VERSION in EQDriverProtocol.h" >&2; exit 1; }

common=(-O2 -g -Wall -Wextra -Werror -fvisibility=hidden -arch arm64 -arch x86_64 -mmacosx-version-min=14.4
        -I../Sources/EQCore/include)
flags=(-std=c++17 -fvisibility-inlines-hidden $common)
# Writes to the settings property are taken only from eq signed by the same team as the plug-in:
# the certificate's OU, which the "(...)" in a Development identity's name is not.
if [[ $identity != - ]]; then
  team=$(security find-certificate -c "$identity" -p | openssl x509 -noout -subject -nameopt multiline |
    awk -F' = ' '/organizationalUnitName/ {print $2}')
  [[ $team =~ ^[A-Z0-9]+$ ]] || { echo "no team ID in the certificate for $identity" >&2; exit 1; }
  flags+=(-DEQ_CLIENT_TEAM=$team)
fi

bundle=build/EQDriver.driver
rm -rf "$bundle" build/obj
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources" build/obj
# EQCore is the daemon's own file, so both modes run the same DSP.
for core in EQCore EQDriverProtocol; do
  xcrun clang -std=c11 $common -c ../Sources/EQCore/$core.c -o build/obj/$core.o
done
xcrun clang++ $flags -bundle Source/Driver.cpp build/obj/EQCore.o build/obj/EQDriverProtocol.o \
  -o "$bundle/Contents/MacOS/EQDriver" -framework CoreAudio -framework CoreFoundation -framework IOKit -framework Security
rm -rf build/EQDriver.dSYM
mv "$bundle/Contents/MacOS/EQDriver.dSYM" build/
sed -e "s/__VERSION__/$version/" -e "s/__BUILD__/$build/" -e "s/__REVISION__/$revision/" -e "s/__PROTOCOL__/$protocol/" Info.plist > "$bundle/Contents/Info.plist"
plutil -lint -s "$bundle/Contents/Info.plist"

xcrun clang -std=c17 -O2 -Wall -Wextra -Werror -arch arm64 -arch x86_64 -mmacosx-version-min=14.4 \
  Probe/probe.c -o build/probe -framework CoreAudio -framework CoreFoundation

sign=(codesign --force --sign "$identity")
[[ $identity == - ]] || sign+=(--options runtime --timestamp)
$sign --identifier com.servitola.eq.driver "$bundle"
$sign --identifier com.servitola.eq.probe build/probe
codesign --verify --strict "$bundle" build/probe
echo "built $bundle and build/probe ($version, build $build, driver revision $revision, protocol $protocol, identity: $identity)"
