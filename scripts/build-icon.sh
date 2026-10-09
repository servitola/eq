#!/bin/zsh
# Compile Resources/AppIcon.icon into Resources/Assets.car and Resources/AppIcon.icns.
# Needs Xcode 26. Both outputs are committed so scripts/build-app.sh needs no Xcode: macOS 26
# draws Assets.car with Liquid Glass and puts an icns-only app into a grey plate, while
# macOS 14 and 15 read the flat renditions actool also writes into Assets.car and the icns.
set -euo pipefail
cd "${0:A:h}/.."

out=$(mktemp -d)
trap 'rm -rf $out' EXIT

# Absolute paths: actool resolves relative ones against its server's directory, not ours.
xcrun actool "$PWD/Resources/AppIcon.icon" --compile "$out" \
  --app-icon AppIcon --platform macosx --target-device mac --minimum-deployment-target 14.4 \
  --output-partial-info-plist "$out/partial.plist" --output-format human-readable-text

# Some actool failures exit 0, so check what it wrote.
for f in Assets.car AppIcon.icns; do
  [[ -s $out/$f ]] || { echo "actool did not write $f" >&2; exit 1; }
done
mv "$out/Assets.car" "$out/AppIcon.icns" Resources/
echo "wrote Resources/Assets.car and Resources/AppIcon.icns"
