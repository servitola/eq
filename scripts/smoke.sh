#!/bin/zsh
# Launch the daemon against a scratch config, wait for a live tap, edit a band through the
# CLI, confirm the daemon picked it up and frames keep flowing, then stop it.
# Usage: scripts/smoke.sh [path/to/eq]   (default: build/EQ.app/Contents/MacOS/eq)
set -euo pipefail
cd "${0:a:h}/.."
eq=${1:-build/EQ.app/Contents/MacOS/eq}
[[ -x $eq ]] || { echo "no binary at $eq" >&2; exit 2 }
# The scratch status file hides a running daemon from the single-instance check, and two taps would stack.
pgrep -f 'MacOS/eq daemon' >/dev/null && { echo "an eq daemon is already running — stop com.servitola.eq first (launchctl bootout gui/\$UID/com.servitola.eq)" >&2; exit 2 }

scratch=$(mktemp -d /tmp/eq-smoke.XXXXXX)
export EQ_CONFIG=$scratch/eq.json EQ_STATUS=$scratch/status.json
trap 'kill ${pid:-} 2>/dev/null || true; rm -rf "$scratch"' EXIT

"$eq" init >/dev/null
"$eq" daemon >"$scratch/daemon.log" 2>&1 &
pid=$!

state=
for _ in {1..30}; do
  sleep 1
  state=$("$eq" status --json 2>/dev/null | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["state"])' 2>/dev/null || true)
  [[ $state == running ]] && break
done
if [[ $state != running ]]; then
  echo "daemon never reached running (state: ${state:-none})"; cat "$scratch/daemon.log"; "$eq" status || true
  exit 1
fi

frames1=$("$eq" status --json | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["framesProcessed"])')
"$eq" set 1khz -3 >/dev/null
sleep 2
grep -q "config reloaded" "$scratch/daemon.log" || { echo "daemon did not reload the config"; cat "$scratch/daemon.log"; exit 1 }
"$eq" | grep -q -- '-3.0' || { echo "CLI does not show the new gain"; cat "$scratch/daemon.log"; exit 1 }
sleep 6
frames2=$("$eq" status --json | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["framesProcessed"])')
(( frames2 > frames1 )) || { echo "frames did not advance ($frames1 → $frames2) — is anything playing? the tap only delivers frames while audio plays"; cat "$scratch/daemon.log"; exit 1 }

rss=$(ps -o rss= -p $pid | tr -d ' ')
(( rss / 1024 <= 30 )) || { echo "RSS $((rss / 1024)) MB exceeds the 30 MB budget"; exit 1 }
echo "smoke ok: running on $("$eq" status --json | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["device"]["name"])'), frames $frames1 → $frames2, RSS $((rss / 1024)) MB"
