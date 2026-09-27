#!/bin/zsh
# Launch the daemon against a scratch config, wait for a live tap, pull 2 s of `eq stream`
# to prove the meter socket works end to end, edit a band through the CLI, confirm the
# daemon picked it up and frames keep flowing while counting status.json writes over 20 s
# (the eq set + at most one heartbeat should land ≤ 2), run doctor and an import, then hold
# 12 s of silence to prove the watchdog stays quiet.
# EQ_SMOKE_TONE=1: the script plays its own tone and stops it for the silence window.
# Without it the caller supplies the audio and must stop playback when the script prints
# "silence window"; the script never touches an afplay it did not start.
# Usage: [EQ_SMOKE_TONE=1] scripts/smoke.sh [path/to/eq]   (default: build/EQ.app/Contents/MacOS/eq)
set -euo pipefail
cd "${0:a:h}/.."
eq=${1:-build/EQ.app/Contents/MacOS/eq}
[[ -x $eq ]] || { echo "no binary at $eq" >&2; exit 2 }
# The scratch status file hides a running daemon from the single-instance check, and two taps would stack.
pgrep -f 'MacOS/eq daemon' >/dev/null && { echo "an eq daemon is already running — stop com.servitola.eq first (launchctl bootout gui/\$UID/com.servitola.eq)" >&2; exit 2 }

scratch=$(mktemp -d /tmp/eq-smoke.XXXXXX)
export EQ_CONFIG=$scratch/eq.json EQ_STATUS=$scratch/status.json
stop_tone() {
  [[ -n ${tone_pid:-} ]] || return 0
  # Freeze the loop before killing its afplay, or it starts the next one; killing the loop
  # first instead would orphan the playing afplay out of reach of pkill -P.
  kill -STOP $tone_pid 2>/dev/null || true
  pkill -P $tone_pid afplay 2>/dev/null || true
  kill -KILL $tone_pid 2>/dev/null || true
  tone_pid=
}
trap 'stop_tone; kill ${pid:-} 2>/dev/null || true; rm -rf "$scratch"' EXIT

# Every CLI call goes through a symlink, as brew installs it, so Build.version must resolve through it.
binary=${eq:a}
mkdir "$scratch/bin"
ln -s "$binary" "$scratch/bin/eq"
eq=$scratch/bin/eq

"$eq" init >/dev/null
"$binary" daemon >"$scratch/daemon.log" 2>&1 &
pid=$!
if [[ ${EQ_SMOKE_TONE:-} == 1 ]]; then
  (while true; do afplay -v 0.2 /System/Library/Sounds/Submarine.aiff; done) &
  tone_pid=$!
fi

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

# Runs during the tone, ahead of the status-write window below — nothing pins it there.
# `|| true` on the kill: under `set -e`, an already-exited stream (e.g. the daemon closed the
# socket first) would fail the kill and take the whole script down with it.
( "$eq" stream >"$scratch/stream.jsonl" 2>"$scratch/stream.err" & sp=$!; sleep 2; kill $sp 2>/dev/null || true; wait $sp 2>/dev/null || true )
stream_lines=$(wc -l < "$scratch/stream.jsonl" | tr -d ' ')
(( stream_lines >= 20 )) || { echo "stream produced $stream_lines lines/2s, want >= 20"; cat "$scratch/daemon.log"; echo "--- stream stderr ---"; cat "$scratch/stream.err"; exit 1 }
/usr/bin/python3 -c 'import json,sys; d=json.loads(open(sys.argv[1]).readline()); assert len(d["in"]) == 10 and len(d["out"]) == 10 and len(d["gains"]) == 10, d' "$scratch/stream.jsonl" \
  || { echo "stream line missing 10-element in/out/gains"; cat "$scratch/stream.err"; exit 1 }
grep -q "meter: 1 client" "$scratch/daemon.log" || { echo "daemon log missing meter: 1 client"; cat "$scratch/daemon.log"; exit 1 }
sleep 1
grep -q "meter: 0 clients" "$scratch/daemon.log" || { echo "daemon log missing meter: 0 clients"; cat "$scratch/daemon.log"; exit 1 }

frames1=$("$eq" status --json | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["framesProcessed"])')
status_mtime=$(stat -f %m "$EQ_STATUS")
status_writes=0
"$eq" set 1khz -3 >/dev/null
for _ in {1..20}; do
  sleep 1
  mtime=$(stat -f %m "$EQ_STATUS")
  if [[ $mtime != "$status_mtime" ]]; then
    status_writes=$((status_writes + 1))
    status_mtime=$mtime
  fi
done
(( status_writes <= 2 )) || { echo "status writes $status_writes/20s exceeds the ≤2 budget"; cat "$scratch/daemon.log"; exit 1 }
grep -q "config reloaded" "$scratch/daemon.log" || { echo "daemon did not reload the config"; cat "$scratch/daemon.log"; exit 1 }
"$eq" | grep -q -- '-3.0' || { echo "CLI does not show the new gain"; cat "$scratch/daemon.log"; exit 1 }
frames2=$("$eq" status --json | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["framesProcessed"])')
(( frames2 > frames1 )) || { echo "frames did not advance ($frames1 → $frames2) — is anything playing? the tap only delivers frames while audio plays"; cat "$scratch/daemon.log"; exit 1 }

EQ_SMOKE=1 "$eq" doctor --json | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d["ok"] else 1)' \
  || { echo "doctor not ok"; "$eq" doctor; cat "$scratch/daemon.log"; exit 1 }
EQ_SMOKE=1 "$eq" doctor --json | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(1 if any("this eq v" in c["detail"] for c in d["checks"]) else 0)' \
  || { echo "the symlinked CLI reports a different version than the daemon"; EQ_SMOKE=1 "$eq" doctor; exit 1 }

"$eq" import "$PWD/Tests/eqTests/Fixtures/Sony WH-1000XM4 ParametricEQ.txt" >/dev/null && sleep 1 && "$eq" | grep -q lowShelf \
  || { echo "import did not land"; exit 1 }

if [[ -n ${tone_pid:-} ]]; then
  stop_tone
  echo "silence window: tone stopped for 12 s"
else
  echo "silence window: stop playback now and keep it stopped until this script exits"
fi
sleep 12
grep -q "IO stalled" "$scratch/daemon.log" && { echo "watchdog fired on silence"; cat "$scratch/daemon.log"; exit 1 }

rss=$(ps -o rss= -p $pid | tr -d ' ')
(( rss / 1024 <= 30 )) || { echo "RSS $((rss / 1024)) MB exceeds the 30 MB budget"; exit 1 }
callbacks=$("$eq" status --json | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["callbacks"])')
echo "smoke ok: running on $("$eq" status --json | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["device"]["name"])'), frames $frames1 → $frames2, callbacks $callbacks, RSS $((rss / 1024)) MB, status writes $status_writes/20s, stream $stream_lines lines/2s"
