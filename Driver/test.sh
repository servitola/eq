#!/bin/zsh
# Runs the plug-in's tests that need no coreaudiod.
#   Driver/test.sh          core: ring, clock servo, timeline checks, latency, target state machine
#   Driver/test.sh --host   also loads build/EQDriver.driver into a fake host; this opens IO on the
#                           built-in output and plays silence for about 25 s
set -euo pipefail
cd "${0:a:h}"
mkdir -p build
xcrun clang++ -std=c++17 -O2 -g -Wall -Wextra -Werror -fsanitize=address,undefined \
  Tests/CoreTests.cpp -o build/core-tests
build/core-tests

if [[ ${1:-} == --host ]]; then
  [[ -d build/EQDriver.driver ]] || ./build.sh --adhoc
  xcrun clang++ -std=c++17 -O2 -g -Wall -Wextra -Werror Tests/HostHarness.cpp -o build/host-harness \
    -framework CoreAudio -framework CoreFoundation
  build/host-harness build/EQDriver.driver
  killed=build/killed/EQDriver.driver
  rm -rf build/killed && mkdir -p build/killed && ditto build/EQDriver.driver $killed
  touch $killed/Contents/Resources/disabled
  build/host-harness $killed --killed
fi
