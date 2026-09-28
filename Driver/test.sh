#!/bin/zsh
# Runs the plug-in's tests that need no coreaudiod.
#   Driver/test.sh               core: ring, clock servo, timeline checks, latency, target state machine,
#                                the settings record, per-target settings, EQ processing, writer checks
#   Driver/test.sh --host-idle   also loads build/EQDriver.driver into a fake host without ever
#                                starting IO: configuration changes with Perform run inside Request,
#                                on another thread while Request waits, after it returns, or never (the
#                                plug-in must send it again); a stored target of this device's
#                                own UID; the kill file; settings writes from this process and from
#                                pid 1, and the meter
#   Driver/test.sh --host        the same, then a full run that opens IO on the built-in output and
#                                plays silence for about 25 s
set -euo pipefail
cd "${0:a:h}"
mkdir -p build/test-obj
sanitize=(-O2 -g -Wall -Wextra -Werror -fsanitize=address,undefined -I../Sources/EQCore/include)
for core in EQCore EQDriverProtocol; do
  xcrun clang -std=c11 $sanitize -c ../Sources/EQCore/$core.c -o build/test-obj/$core.o
done
xcrun clang++ -std=c++17 $sanitize Tests/CoreTests.cpp build/test-obj/EQCore.o build/test-obj/EQDriverProtocol.o \
  -o build/core-tests -framework CoreFoundation -framework Security
build/core-tests

case ${1:-} in
  --host|--host-idle) ;;
  "") exit 0 ;;
  *) echo "unknown option: $1" >&2; exit 2 ;;
esac
[[ -d build/EQDriver.driver ]] || ./build.sh --adhoc
xcrun clang -std=c11 -O2 -Wall -Wextra -Werror -I../Sources/EQCore/include -c ../Sources/EQCore/EQDriverProtocol.c \
  -o build/test-obj/harness-protocol.o
xcrun clang -std=c11 -O2 -Wall -Wextra -Werror -I../Sources/EQCore/include -c ../Sources/EQCore/EQCore.c \
  -o build/test-obj/harness-core.o
xcrun clang++ -std=c++17 -O2 -g -Wall -Wextra -Werror -I../Sources/EQCore/include Tests/HostHarness.cpp \
  build/test-obj/harness-protocol.o build/test-obj/harness-core.o -o build/host-harness \
  -framework CoreAudio -framework CoreFoundation -framework Security
codesign --force --sign - --identifier com.servitola.eq build/host-harness
for mode in sync wait async drop; do
  build/host-harness build/EQDriver.driver --idle $mode
done
build/host-harness build/EQDriver.driver --idle sync self
killed=build/killed/EQDriver.driver
rm -rf build/killed && mkdir -p build/killed && ditto build/EQDriver.driver $killed
touch $killed/Contents/Resources/disabled
build/host-harness $killed --killed
[[ $1 == --host ]] && build/host-harness build/EQDriver.driver
exit 0
