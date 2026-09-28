#!/bin/zsh
# Measure the delay eq adds, for tap drift compensation {1,0} × IO buffer {512,256,128}.
# Each run starts its own daemon against a scratch config and status, then takes two readings:
#   io     — output minus input timestamp of one IO cycle (status addedLatencyMs): eq's own hold.
#   click  — scripts/click.swift plays clicks from another process and prints when each was handed
#            to the device; eq's status `lastOnset` says when the tap stamped it and when eq sent it
#            on. out−click is the whole tap path, tap−click is where the tap puts the sound
#            relative to the app that played it. Both sides share the host clock.
# Keep every other sound off while it runs: any audio in the silence before a click hides the onset.
# Usage: scripts/measure-latency.sh [path/to/eq]   (default: build/EQ.app/Contents/MacOS/eq)
set -euo pipefail
cd "${0:a:h}/.."
eq=${1:-build/EQ.app/Contents/MacOS/eq}
[[ -x $eq ]] || { echo "no binary at $eq" >&2; exit 2 }
# The scratch status file hides a running daemon from the single-instance check, and two taps would stack.
pgrep -f 'MacOS/eq daemon' >/dev/null && { echo "an eq daemon is already running — stop it first (launchctl bootout gui/\$UID/com.servitola.eq.daemon, or com.servitola.eq for a legacy plist)" >&2; exit 2 }

scratch=$(mktemp -d /tmp/eq-latency.XXXXXX)
stop_tone() {
  [[ -n ${tone_pid:-} ]] || return 0
  # Same order as smoke.sh: freeze the loop, kill its afplay, then the loop.
  kill -STOP $tone_pid 2>/dev/null || true
  pkill -P $tone_pid afplay 2>/dev/null || true
  kill -KILL $tone_pid 2>/dev/null || true
  tone_pid=
}
stop_daemon() {
  [[ -n ${pid:-} ]] || return 0
  kill $pid 2>/dev/null || true
  wait $pid 2>/dev/null || true
  pid=
}
trap 'stop_tone; stop_daemon; rm -rf "$scratch"' EXIT

xcrun swiftc -O scripts/click.swift -o "$scratch/click"

field() { /usr/bin/python3 -c 'import json,sys; v=json.load(open(sys.argv[1])).get(sys.argv[2]); print("-" if v is None else v)' "$EQ_STATUS" "$1" 2>/dev/null || echo -; }
refresh() { kill -USR1 $pid; sleep 0.3; }

for drift in ${=DRIFTS:-1 0}; do
  for frames in ${=FRAMES:-512 256 128}; do
    run=$scratch/drift$drift-io$frames
    mkdir "$run"
    export EQ_CONFIG=$run/eq.json EQ_STATUS=$run/status.json
    EQ_DRIFT_COMPENSATION=$drift EQ_IO_FRAMES=$frames "$eq" daemon >"$run/daemon.log" 2>&1 &
    pid=$!
    (while true; do afplay -v 0.2 /System/Library/Sounds/Submarine.aiff; done) &
    tone_pid=$!

    state=-
    for _ in {1..30}; do
      sleep 1
      [[ -f $EQ_STATUS ]] && state=$(field state)
      [[ $state == running ]] && break
    done
    echo "== drift $drift, IO buffer $frames requested"
    if [[ $state != running ]]; then
      echo "   daemon never reached running (state: $state)"; sed 's/^/   /' "$run/daemon.log"
      stop_tone; stop_daemon; continue
    fi
    sleep 3
    refresh
    grep -hE "path latency frames|tap latency|IO buffer" "$run/daemon.log" | tail -6 | sed 's/^/   /'
    echo "   io: eq adds $(field addedLatencyMs) ms ($(field addedLatencyFrames) frames); path estimate $(field latencyMs) ms, device $(field deviceLatencyMs) ms"

    stop_tone
    sleep 1.5
    "$scratch/click" 3 2 | while read -r _ clicked; do
      sleep 1
      refresh
      /usr/bin/python3 - "$EQ_STATUS" "$clicked" <<'EOF'
import json, sys
onset = json.load(open(sys.argv[1])).get("lastOnset")
clicked = float(sys.argv[2])
if not onset or abs(onset["tapHostSeconds"] - clicked) > 1:
    print("   click: no onset seen for this click")
else:
    tap = (onset["tapHostSeconds"] - clicked) * 1000
    out = (onset["outputHostSeconds"] - clicked) * 1000
    print(f"   click: tap−click {tap:.1f} ms, out−click {out:.1f} ms (eq adds this), out−tap {out - tap:.1f} ms")
EOF
    done || echo "   click helper stopped early (exit $?)"
    stop_daemon
  done
done
