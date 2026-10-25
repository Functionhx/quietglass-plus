#!/bin/bash
# Samples CPU %, Energy Impact and idle wakeups for QuietGlass plus the system
# processes that do camera/screen-capture work on its behalf.
# Usage: scripts/measure-power.sh [seconds=40] [label]
set -euo pipefail
seconds="${1:-40}"; label="${2:-run}"
names=(QuietGlass appleh16camerad cameracaptured WindowServer replayd)
pids=()
for n in "${names[@]}"; do p="$(pgrep -x "$n" | head -1 || true)"; [[ -n "$p" ]] && pids+=(-pid "$p"); done
top -l $((seconds / 2 + 1)) -s 2 "${pids[@]}" -stats pid,command,cpu,power,idlew 2>/dev/null |
  awk -v label="$label" '
    /^PID/ { sample++; next }
    sample > 1 && NF >= 5 && $1 ~ /^[0-9]+$/ {
      cmd=$2; cpu[cmd]+=$3; pw[cmd]+=$4; if (!(cmd in first)) first[cmd]=$5; last[cmd]=$5; cnt[cmd]++ }
    END {
      printf "== %s (%d samples)\n%-16s %7s %8s %9s\n", label, sample-1, "process", "CPU%", "Energy", "Wakeups/s"
      for (c in cnt) { w=(cnt[c] > 1) ? (last[c]-first[c])/((cnt[c]-1)*2) : 0
        printf "%-16s %7.1f %8.1f %9.0f\n", c, cpu[c]/cnt[c], pw[c]/cnt[c], w; tc+=cpu[c]/cnt[c]; tp+=pw[c]/cnt[c]; tw+=w }
      printf "%-16s %7.1f %8.1f %8.0f\n", "TOTAL", tc, tp, tw }'
