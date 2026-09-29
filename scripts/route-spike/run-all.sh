#!/bin/zsh
# Runs the M0 app-routing spike (docs/superpowers/specs/2026-09-29-eq-app-routing.md) with the user
# present. Build first: scripts/route-spike/build.sh.
#   run-all.sh [--yes] [check l1 exclude bundle dual start kill format music]   (default: all, in that order)
# On a terminal it asks before each test and the spike asks listening questions on /dev/tty.
# Without one (an agent runs it) pass --yes once the user has agreed; each question then appears in
# the log as "ASK <n> …" and the test holds, sound included, until "<n> <answer>" is appended to the
# answers file printed at the start.
# SPEAKERS / BT pick the two devices (default: builtin / BE-RCA); SINE_SECONDS the L1 soak (60).
set -uo pipefail
here=${0:a:h}
spike=$here/build/routespike
[[ -x $spike && -d $here/build/SpikeTone.app ]] || { echo "not built: run $here/build.sh" >&2; exit 2 }

yes=0
tests=()
for arg in "$@"; do
  case $arg in
    --yes) yes=1 ;;
    check|l1|exclude|bundle|dual|start|kill|format|music) tests+=$arg ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done
(( ${#tests} )) || tests=(check l1 exclude bundle dual start kill format music)
if [[ ! -t 0 ]] && (( ! yes )); then
  echo "no terminal to confirm on: get the user's go-ahead, then pass --yes" >&2
  exit 2
fi

S=${SPEAKERS:-builtin}
BT=${BT:-BE-RCA}
SINE_SECONDS=${SINE_SECONDS:-60}
stamp=$(date +%Y%m%d-%H%M%S)
results=$here/build/results
mkdir -p "$results"
log=$results/run-$stamp.log
export ROUTESPIKE_ANSWERS=$results/answers-$stamp.txt
: > "$ROUTESPIKE_ANSWERS"

say() { print -r -- "$*" | tee -a "$log" }
trap '"$spike" cleanup >>"$log" 2>&1' EXIT
trap 'say "interrupted"; exit 130' INT TERM

eqstatus=$(eq status --json 2>/dev/null || true)
field() { /usr/bin/python3 -c 'import json,sys
try: d=json.loads(sys.stdin.read())
except Exception: print("-"); sys.exit()
v=d
for k in sys.argv[1].split("."): v=v.get(k) if isinstance(v,dict) else None
print("-" if v is None else v)' "$1" <<<"$eqstatus"; }
mode=$(field mode); state=$(field state); target=$(field driver.target.name)
if pgrep -f 'MacOS/eq daemon' >/dev/null && [[ $mode != driver ]]; then
  echo "the eq daemon runs in '$mode' mode: its main tap sits on the default output and would stack with the spike's taps." >&2
  echo "Switch to driver mode or stop it (launchctl bootout gui/\$UID/com.servitola.eq.daemon), then rerun." >&2
  exit 2
fi

say "M0 app-routing spike, $(date '+%F %T'); log $log"
say "eq: mode $mode, state $state, driver target $target"
"$spike" devices | tee -a "$log"
say ""
say "What this does and does not do:"
say "  - Plays test tones from its own SpikeTone.app processes, straight to '$S' and '$BT' by UID, at -20 dBFS"
say "    (clicks at -14 dBFS). Keep both devices at a moderate volume and every other sound off."
say "  - Never changes the default output, never touches the EQ driver or 'BE-RCA · EQ', never taps eq itself."
say "  - Every tap and aggregate is destroyed on exit, Ctrl-C and SIGTERM; 'routespike cleanup' runs at the end."
say "  - Some tests use a muting tap on '$S' that does not replay: other sound on '$S' drops for ~10 s."
say "    coreaudiod and the driver service are excluded from it, so driver-mode playback is not muted."
[[ $target == *Speakers* ]] && say "  ! The driver plays on the speakers: its audio is protected by the exclusion above, but listen for it."
say "  Takes about 10 min plus answers. Answers file: $ROUTESPIKE_ANSWERS"
say ""
"$spike" cleanup >>"$log" 2>&1

confirm() {
  say ""
  say "### $1"
  say "    $2"
  (( yes )) && return 0
  read -r "reply?    Enter = run, s = skip, q = quit: " </dev/tty
  [[ $reply == q ]] && exit 0
  [[ $reply != s ]]
}
spikerun() {
  "$spike" "$@" --ask 2>&1 | tee -a "$log"
  local st=${pipestatus[1]}
  (( st == 0 )) || say "    (exit $st)"
  return $st
}

for t in $tests; do
  case $t in
    check)
      confirm "0. capture check" "A 1 s quiet beep on $S; confirms the EQ permission applies to this binary." || continue
      spikerun check --source $S || exit 1 ;;
    l1)
      confirm "1. L1 latency and quality (4 runs, ~5.5 min)" \
        "Clicks then ${SINE_SECONDS} s of 1 kHz played to one device and routed to the other: $S→$BT and $BT→$S, drift compensation on/off. Listen for crackle; you will be asked." || continue
      for pair in "$S $BT" "$BT $S"; do
        for drift in 1 0; do
          spikerun l1 --source ${pair%% *} --target ${pair##* } --drift $drift --sine-seconds $SINE_SECONDS
        done
      done ;;
    exclude)
      confirm "2. live exclusion edit (2 runs, ~25 s)" \
        "1 kHz and 2 kHz tones on $S. Run 1 only measures. Run 2 mutes $S: you should hear 1 kHz only from ~3 s to ~6 s." || continue
      spikerun exclude --source $S
      spikerun exclude --source $S --mute ;;
    bundle)
      confirm "3. bundleIDs taps (4 runs, ~45 s)" \
        "Short 1/2/3 kHz tones on $S from SpikeTone and its helper. A muted tap that catches them silences them; nothing to answer." || continue
      for restore in 0 1; do
        spikerun bundle --source $S --restore $restore
        spikerun bundle --source $S --restore $restore --pre
      done ;;
    dual)
      confirm "4. route tap + main tap together (2 runs, ~20 s)" \
        "1 kHz routed $S→$BT while a main-style tap mutes $S. You should hear 1 kHz on $BT only." || continue
      spikerun dual --source $S --target $BT
      spikerun dual --source $S --target $BT --route-first ;;
    start)
      confirm "5. start loss/leak (4 runs, ~25 s)" \
        "1 kHz on $S, routed to $BT. Listen for a short blip on $S when the route starts." || continue
      for mute in muted mwt; do
        spikerun start --source $S --target $BT --mute $mute
        spikerun start --source $S --target $BT --mute $mute --tap-first
      done ;;
    kill)
      confirm "6. kill -9 of the route's owner (3 runs, ~45 s)" \
        "1 kHz on $S routed to $BT by a child process, which is then killed with -9. Say where you hear the tone at each question." || continue
      spikerun kill --source $S --target $BT --mute muted
      spikerun kill --source $S --target $BT --mute muted --public
      spikerun kill --source $S --target $BT --mute mwt --public ;;
    format)
      confirm "7. tap format across rates (2 runs, ~20 s)" \
        "A quiet 1 kHz tone rendered at 48 kHz to $BT and at 44.1 kHz to $S; nothing to answer." || continue
      spikerun format --source $BT --target $S
      spikerun format --source $S --target $BT ;;
    music)
      confirm "8. Apple Music (~20 s)" \
        "Play an Apple Music catalogue track in Music (not a local file). The tap only listens; it does not mute Music." || continue
      spikerun music ;;
  esac
done

"$spike" cleanup | tee -a "$log"
say ""
say "== results"
grep -h '^RESULT' "$log" | tee "$results/summary-$stamp.txt"
say "log: $log"
