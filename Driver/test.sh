#!/bin/zsh
# Runs the plug-in core's tests: ring, clock servo, timeline checks, latency, target state machine.
set -euo pipefail
cd "${0:a:h}"
mkdir -p build
xcrun clang++ -std=c++17 -O2 -g -Wall -Wextra -Werror -fsanitize=address,undefined \
  Tests/CoreTests.cpp -o build/core-tests
build/core-tests

