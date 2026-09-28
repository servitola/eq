#!/bin/zsh
# Runs the plug-in's tests that need no coreaudiod.
#   Driver/test.sh               core: ring, clock servo, timeline checks, latency, target state machine
#   Driver/test.sh --host-idle   also loads build/EQDriver.driver into a fake host without ever
#                                starting IO: configuration changes with Perform run inside Request,
#                                on another thread while Request waits, and after it returns; kill file
#   Driver/test.sh --host        the same, then a full run that opens IO on the built-in output and
#                                plays silence for about 25 s
set -euo pipefail
cd "${0:a:h}"
mkdir -p build
xcrun clang++ -std=c++17 -O2 -g -Wall -Wextra -Werror -fsanitize=address,undefined \
  Tests/CoreTests.cpp -o build/core-tests
build/core-tests

case ${1:-} in
  --host|--host-idle) ;;
  "") exit 0 ;;
  *) echo "unknown option: $1" >&2; exit 2 ;;
esac
[[ -d build/EQDriver.driver ]] || ./build.sh --adhoc
xcrun clang++ -std=c++17 -O2 -g -Wall -Wextra -Werror Tests/HostHarness.cpp -o build/host-harness \
  -framework CoreAudio -framework CoreFoundation
for mode in sync wait async; do
  build/host-harness build/EQDriver.driver --idle $mode
done
killed=build/killed/EQDriver.driver
rm -rf build/killed && mkdir -p build/killed && ditto build/EQDriver.driver $killed
touch $killed/Contents/Resources/disabled
build/host-harness $killed --killed
[[ $1 == --host ]] && build/host-harness build/EQDriver.driver
exit 0
