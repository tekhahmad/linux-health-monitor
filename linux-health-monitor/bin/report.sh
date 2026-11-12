#!/usr/bin/env bash
# report.sh - turn history.tsv into a daily or weekly Markdown monitoring report.
# Usage: report.sh [--days N] [--log-dir DIR] [--out FILE]
set -uo pipefail
DAYS=1; LOG_DIR="${LOG_DIR:-/var/log/health-monitor}"; OUT=""
while (( $# )); do
  case "$1" in
    --days) DAYS="$2"; shift ;;
    --log-dir) LOG_DIR="$2"; shift ;;
    --out) OUT="$2"; shift ;;
    *) echo "unknown option: $1" >&2; exit 64 ;;
  esac; shift
done
HIST="$LOG_DIR/history.tsv"
[[ -r "$HIST" ]] || { echo "no history file at $HIST" >&2; exit 1; }
CUTOFF=$(date -d "$((DAYS - 1)) days ago" +%F)

report() {
  echo "# Server monitoring report - $(hostname)"
  echo
  echo "Period: ${CUTOFF} to $(date +%F) (${DAYS} day(s)). Generated $(date '+%F %T')."
  echo
  awk -F'\t' -v cutoff="$CUTOFF" '
    substr($1,1,10) >= cutoff {
      n++; st[$2]++
      cpu+=$3; mem+=$4
      if ($3>pc) pc=$3; if ($4>pm) pm=$4; if ($5>pd) pd=$5
      if ($2!="OK") ev[++e]=$1 "\t" $2 "\t" $6
    }
    END {
      if (!n) { print "No data in this period."; exit }
      printf "## Summary\n\n| Metric | Value |\n|---|---|\n"
      printf "| Checks run | %d |\n| OK / WARN / CRIT | %d / %d / %d |\n", n, st["OK"], st["WARN"], st["CRIT"]
      printf "| Availability of healthy state | %.1f%% |\n", 100*st["OK"]/n
      printf "| CPU load avg / peak | %.0f%% / %d%% |\n", cpu/n, pc
      printf "| Memory avg / peak | %.0f%% / %d%% |\n", mem/n, pm
      printf "| Highest disk usage | %d%% |\n\n", pd
      printf "## Incidents and warnings\n\n"
      if (!e) { print "None recorded."; exit }
      print "| Time | Status | Detail |\n|---|---|---|"
      for (i=1;i<=e && i<=50;i++) { split(ev[i], f, "\t"); printf "| %s | %s | %s |\n", f[1], f[2], f[3] }
      if (e>50) printf "\n(%d more events not shown)\n", e-50
    }' "$HIST"
}

if [[ -n "$OUT" ]]; then report > "$OUT" && echo "wrote $OUT"; else report; fi
