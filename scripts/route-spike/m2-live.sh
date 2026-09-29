#!/bin/zsh
# M2 live test of app routing (docs/superpowers/specs/2026-09-29-eq-app-routing.md), with the user
# present. It runs a second eq daemon from build/EQ.app beside the installed one, with no main path
# (EQ_MAIN_PATH=off) and a scratch config whose one rule routes SpikeTone → [BE-RCA, speakers].
# SpikeTone plays on the MacBook speakers by UID; the route should carry it to BE-RCA only.
#
#   m2-live.sh [--yes] [--fallback]
#
# Measures, as M0 test 1 did for L1 (+186.8 ms to BE-RCA):
#   clicks  — SpikeTone stamps each click as it hands it to the speakers; the route's status
#             `lastOnset` says when its tap captured it and when its output sent it to BE-RCA.
#             out−click is what the route adds on top of BE-RCA's own latency.
#   sine    — a 1 kHz tone at −20 dBFS for SINE_SECONDS (60); an unmuted tap on BE-RCA's output
#             (routespike observe) counts glitches and dropouts and measures the pitch; the route's
#             underruns, overruns and servo correction come from the status.
#   kill    — the test daemon is killed with -9 while the tone plays: the tone must come back on
#             the speakers (M0: a private muted tap gives the audio back).
#   --fallback asks you to switch BE-RCA off and on again (this also moves the installed daemon's
#             driver target, as switching it off by hand always does).
#
# Changes nothing lasting: it never sets the default output or the mode, never touches the driver or
# ~/.config/eq, never signals the installed daemon, and reads only its status file. Everything it
# starts stops on exit, Ctrl-C and SIGTERM.
# On a terminal it asks on /dev/tty. Without one, pass --yes once the user has agreed; questions then
# appear as "ASK <n> …" and wait for "<n> <answer>" in the answers file printed at the start.
# SPEAKERS / BT pick the devices (default: builtin / BE-RCA).
set -uo pipefail
here=${0:a:h}
repo=${here:h:h}
app=$repo/build/EQ.app
eq=$app/Contents/MacOS/eq
spike=$here/build/routespike
tone=$here/build/SpikeTone.app/Contents/MacOS/spiketone
tone_bundle=com.servitola.eq.spike.tone

yes=0
fallback=0
for arg in "$@"; do
  case $arg in
    --yes) yes=1 ;;
    --fallback) fallback=1 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done
[[ -x $eq ]] || { echo "no build at $app: scripts/build-app.sh --identity \"Developer ID Application: …\"" >&2; exit 2 }
codesign -dvv "$app" 2>&1 | grep '^Authority=Developer ID Application' >/dev/null || {
  echo "$app is not Developer-ID signed, so the System Audio Recording grant would not apply to it" >&2; exit 2 }
[[ -x $spike && -x $tone ]] || { echo "spike not built: run $here/build.sh" >&2; exit 2 }
if [[ ! -t 0 ]] && (( ! yes )); then
  echo "no terminal to confirm on: get the user's go-ahead, then pass --yes" >&2
  exit 2
fi

S=${SPEAKERS:-builtin}
BT=${BT:-BE-RCA}
SINE_SECONDS=${SINE_SECONDS:-60}
CLICKS=6
stamp=$(date +%Y%m%d-%H%M%S)
results=$here/build/results
mkdir -p "$results"
log=$results/m2-$stamp.log
answers=$results/m2-answers-$stamp.txt
: > "$answers"
scratch=$(mktemp -d /tmp/eq-m2.XXXXXX)
say() { print -r -- "$*" | tee -a "$log" }

# The installed daemon is only read about, from its status file.
real_status=${HOME}/.cache/eq/status.json
field() { /usr/bin/python3 -c 'import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: print("-"); sys.exit()
v=d
for k in sys.argv[2].split("."): v=v.get(k) if isinstance(v,dict) else None
print("-" if v is None else v)' "$1" "$2"; }
real_mode=$(field "$real_status" mode)
real_pid=$(field "$real_status" pid)
if [[ $real_mode == tap ]] && ps -p "$real_pid" >/dev/null 2>&1; then
  echo "the installed daemon (pid $real_pid) runs in tap mode: its main tap would stack with the route's. Switch it to driver mode first." >&2
  exit 2
fi

devices=$("$spike" devices)
uid_of() { /usr/bin/python3 -c 'import re,sys
spec=sys.argv[1]; hits=[]
for line in sys.stdin:
    m=re.match(r"^[ *] '"'"'(.*)'"'"' \[(.*)\] (\S+) ", line)
    if not m or "refused" in line: continue
    name,uid,transport=m.groups()
    if (spec=="builtin" and transport=="built-in") or spec.lower() in name.lower() or spec==uid: hits.append(uid)
print(hits[0] if len(hits)==1 else "")' "$1" <<<"$devices"; }
default_uid() { "$spike" devices | sed -n 's/^\* .* \[\(.*\)\] .*/\1/p' }
SPK_UID=$(uid_of "$S")
BT_UID=$(uid_of "$BT")
[[ -n $SPK_UID && -n $BT_UID ]] || { print -r -- "$devices" >&2; echo "cannot pick exactly one device for '$S' and one for '$BT'" >&2; exit 2 }
default_before=$(default_uid)

tone_pid=
observer_pid=
daemon_pid=
stop_all() {
  [[ -n $tone_pid ]] && kill "$tone_pid" 2>/dev/null
  [[ -n $observer_pid ]] && kill "$observer_pid" 2>/dev/null
  if [[ -n $daemon_pid ]] && kill -0 "$daemon_pid" 2>/dev/null; then
    kill -TERM "$daemon_pid"
    for _ in {1..30}; do kill -0 "$daemon_pid" 2>/dev/null || break; sleep 0.1; done
    kill -0 "$daemon_pid" 2>/dev/null && kill -KILL "$daemon_pid"
  fi
  tone_pid= observer_pid= daemon_pid=
}
finish() {
  stop_all
  [[ -f $scratch/daemon.log ]] && cp "$scratch/daemon.log" "$results/m2-daemon-$stamp.log"
  local after=$(default_uid)
  [[ $after == "$default_before" ]] || say "WARNING: the default output changed during the run ($default_before → $after); this script never sets it"
  rm -rf "$scratch"
}
trap finish EXIT
trap 'say "interrupted"; exit 130' INT TERM

n_asked=0
ask() {
  n_asked=$((n_asked + 1))
  local reply=
  if [[ -t 0 ]]; then
    print -n -- $'\a'"  >>> $1 [$2] " > /dev/tty
    read -r reply < /dev/tty
  else
    say "ASK $n_asked $1 [$2]  (reply: echo '$n_asked <answer>' >> $answers)"
    for _ in {1..3000}; do
      reply=$(sed -n "s/^$n_asked //p" "$answers" | head -1)
      [[ -n $reply ]] && break
      sleep 0.2
    done
  fi
  say "  ANSWER $1 → ${reply:-(none)}"
  REPLY=$reply
}

say "M2 live routing test, $(date '+%F %T'); log $log"
say "installed daemon: pid $real_pid, mode $real_mode — not signalled, not changed"
say "route: SpikeTone ($tone_bundle) → [$BT_UID, $SPK_UID]; SpikeTone plays on $SPK_UID"
say "default output now: $default_before (checked again at the end)"
say ""
say "What this does:"
say "  - Starts $eq daemon with EQ_MAIN_PATH=off and its own config, status and log in $scratch."
say "    It has no main tap and makes no mode changes; its only tap is a private muted one on SpikeTone,"
say "    its only output an IO proc on $BT (mixed with whatever else plays there)."
say "  - SpikeTone plays clicks, then a 1 kHz tone at -20 dBFS, to the speakers. Routed, you hear them on $BT only."
say "  - An unmuted tap on $BT's output measures the tone; it changes nothing you hear."
say "  - Keep both devices at a moderate volume and every other sound off (the measurements hear it too)."
say "  Takes about $((SINE_SECONDS / 60 + 2)) min. Answers file: $answers"
if (( ! yes )); then
  read -r "reply?    Enter = run, q = quit: " </dev/tty
  [[ $reply == q ]] && exit 0
fi

cat > "$scratch/eq.json" <<JSON
{
  "version": 1,
  "enabled": true,
  "default": {"preamp": 0, "bands": [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]},
  "devices": {},
  "presets": {},
  "mode": "tap",
  "experimental": {"routes": true},
  "routes": [{"app": "$tone_bundle", "outputs": ["$BT_UID", "$SPK_UID"]}]
}
JSON
# Only the test daemon gets the scratch paths: the spike asks the installed eq for its status.
test_status=$scratch/status.json
start_daemon() {
  EQ_CONFIG=$scratch/eq.json EQ_STATUS=$test_status EQ_MAIN_PATH=off "$eq" daemon >> "$scratch/daemon.log" 2>&1 &
  daemon_pid=$!
  for _ in {1..50}; do
    [[ $(field "$test_status" pid) == "$daemon_pid" ]] && return 0
    sleep 0.1
  done
  return 1
}
start_daemon || { say "the test daemon never wrote its status:"; cat "$scratch/daemon.log" | tee -a "$log"; exit 1 }
say "test daemon pid $daemon_pid up"

refresh() { kill -USR1 "$daemon_pid" 2>/dev/null; sleep 0.25 }
route() { /usr/bin/python3 - "$test_status" "$tone_bundle" "$1" <<'PY'
import json, sys
routes = json.load(open(sys.argv[1])).get("routes") or []
r = next((r for r in routes if r["app"] == sys.argv[2]), None)
key = sys.argv[3]
if r is None: print("-")
elif key == "target": print((r.get("target") or {}).get("name", "-"))
else:
    v = r.get(key)
    print("-" if v is None else json.dumps(v))
PY
}

say ""
say "### 1. clicks: added latency"
"$tone" --device "$SPK_UID" --mode clicks --count $CLICKS --interval 1.5 --lead 2 --freq 1000 --amp 0.2 \
  --seconds $((2 + CLICKS * 2 + 2)) > "$scratch/clicks.txt" 2>&1 &
tone_pid=$!
sleep 1
refresh
say "  route: $(route target) ($(route reason)), eq holds $(route latencyMs) ms, $BT's own output latency $(route deviceLatencyMs) ms"
seen=0
: > "$scratch/added.txt"
while (( seen < CLICKS )) && kill -0 "$tone_pid" 2>/dev/null; do
  if (( $(grep -c '^click ' "$scratch/clicks.txt") > seen )); then
    seen=$((seen + 1))
    clicked=$(grep '^click ' "$scratch/clicks.txt" | sed -n "${seen}p" | awk '{print $2}')
    sleep 0.8
    refresh
    /usr/bin/python3 - "$test_status" "$tone_bundle" "$clicked" "$scratch/added.txt" <<'PY' | tee -a "$log"
import json, sys
routes = json.load(open(sys.argv[1])).get("routes") or []
r = next((r for r in routes if r["app"] == sys.argv[2]), {})
onset, clicked = r.get("lastOnset"), float(sys.argv[3])
if not onset or abs(onset["tapHostSeconds"] - clicked) > 0.5:
    print(f"  click at {clicked:.3f}: the route saw no onset for it")
else:
    tap, out = (onset["tapHostSeconds"] - clicked) * 1000, (onset["outputHostSeconds"] - clicked) * 1000
    print(f"  click: tap−click {tap:.1f} ms, out−click {out:.1f} ms, out−tap {out - tap:.1f} ms")
    open(sys.argv[4], "a").write(f"{out:.1f}\n")
PY
  else
    sleep 0.1
  fi
done
wait "$tone_pid" 2>/dev/null
tone_pid=
added=$(sort -n "$scratch/added.txt" | awk '{v[NR]=$1} END {if (NR) print v[int((NR+1)/2)]; else print "-"}')
say "RESULT m2-clicks dst=$BT added_ms=$added clicks=$(wc -l < "$scratch/added.txt" | tr -d ' ')/$CLICKS (L1 in M0: 186.8)"

say ""
say "### 2. sine: ${SINE_SECONDS} s of 1 kHz at -20 dBFS, routed to $BT"
"$tone" --device "$SPK_UID" --freq 1000 --amp 0.1 --seconds $((SINE_SECONDS + 900)) > "$scratch/sine.txt" 2>&1 &
tone_pid=$!
sleep 3
"$spike" observe --device "$BT_UID" --seconds "$SINE_SECONDS" --freq 1000 > "$scratch/observe.txt" 2>&1 &
observer_pid=$!
wait "$observer_pid"
observer_pid=
tee -a "$log" < "$scratch/observe.txt"
refresh
say "RESULT m2-sine route=$(route target)/$(route reason) latency_ms=$(route latencyMs) underruns=$(route underruns) overruns=$(route overruns) dropouts=$(route dropouts) correction_ppm=$(route correctionPpm)"
ask "Was the tone on $BT only, and clean? c=clean on $BT, k=crackle or dropouts, s=also or only on the speakers" "c/k/s"
say "RESULT m2-heard sine=$REPLY"

say ""
say "### 3. kill -9 of the test daemon while the tone plays"
kill -KILL "$daemon_pid"
wait "$daemon_pid" 2>/dev/null
daemon_pid=
sleep 1.5
ask "The test daemon was just killed. Where is the tone now? s=speakers, b=$BT, n=nowhere" "s/b/n"
say "RESULT m2-kill heard_after=$REPLY (expected s)"
kill "$tone_pid" 2>/dev/null
wait "$tone_pid" 2>/dev/null
tone_pid=

if (( fallback )); then
  say ""
  say "### 4. fallback: $BT off and on again"
  start_daemon || { say "the test daemon did not come back"; exit 1 }
  "$tone" --device "$SPK_UID" --freq 1000 --amp 0.1 --seconds 600 > /dev/null 2>&1 &
  tone_pid=$!
  sleep 2
  refresh
  say "  route: $(route target) ($(route reason))"
  ask "Switch $BT off now, then answer: did the tone move to the speakers within about 2 s?" "y/n"
  refresh
  say "RESULT m2-fallback-away route=$(route target)/$(route reason) heard=$REPLY"
  ask "Switch $BT on again, wait until macOS shows it connected, then answer: did the tone move back to $BT within about 3 s?" "y/n"
  refresh
  say "RESULT m2-fallback-back route=$(route target)/$(route reason) heard=$REPLY"
fi

say ""
say "== results"
grep -h '^RESULT' "$log" | tee "$results/m2-summary-$stamp.txt"
say "log: $log"
