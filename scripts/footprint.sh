#!/bin/zsh
# scripts/footprint.sh <pid> [seconds=30]
# Read-only measurement for the before/after table in README "How it works".
# Takes ~10s (CPU) + seconds (csw) + seconds (status writes) to run.
set -euo pipefail

pid=${1:?usage: footprint.sh <pid> [seconds=30]}
seconds=${2:-30}
status_file=$HOME/.cache/eq/status.json
log_file=$HOME/projects/dotfiles/cron/logs/eq.log

footprint=$(vmmap -summary "$pid" 2>/dev/null | grep 'Physical footprint:' | head -1 \
  | awk '{v=$3; sub(/K$/, "", v); printf "%.1f MB", v/1024}')
rss=$(ps -o rss= -p "$pid" | awk '{printf "%.1f MB", $1/1024}')

cpu_samples=($(top -l 3 -s 5 -pid "$pid" -stats pid,cpu 2>/dev/null | awk -v p="$pid" '$1==p {print $2}'))
cpu=$(awk -v a="${cpu_samples[-2]}" -v b="${cpu_samples[-1]}" 'BEGIN { printf "%.2f", (a+b)/2 }')

csw_samples=($(top -l 2 -s "$seconds" -pid "$pid" -stats pid,csw 2>/dev/null | awk -v p="$pid" '$1==p {gsub(/\+$/, "", $2); print $2}'))
csw_per_sec=$(( (csw_samples[-1] - csw_samples[-2]) / seconds ))

status_changes=0
last_mtime=$(stat -f %m "$status_file" 2>/dev/null || echo 0)
for _ in $(seq 1 "$seconds"); do
  sleep 1
  mtime=$(stat -f %m "$status_file" 2>/dev/null || echo 0)
  if [[ $mtime != "$last_mtime" ]]; then status_changes=$((status_changes + 1)); fi
  last_mtime=$mtime
done

threads=$(top -l 1 -pid "$pid" -stats th 2>/dev/null | tail -1 | tr -d ' ')
log_lines=$(wc -l < "$log_file" 2>/dev/null | tr -d ' ')

printf '%-22s %s\n' 'physical footprint' "$footprint"
printf '%-22s %s\n' 'rss' "$rss"
printf '%-22s %s%%\n' 'cpu' "$cpu"
printf '%-22s %s/s\n' 'context switches' "$csw_per_sec"
printf '%-22s %s\n' 'status writes' "$status_changes"
printf '%-22s %s\n' 'threads' "$threads"
printf '%-22s %s\n' 'log lines' "$log_lines"
