#!/usr/bin/env bash
# healthcheck.sh - Linux server health monitor.
# Checks CPU, memory, disks, services, TCP ports, TLS certificates and failed
# SSH logins. Prints a report, appends a history line, optionally alerts a webhook.
# Exit codes: 0 = OK, 1 = WARN, 2 = CRIT.
set -uo pipefail

HM_VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROC_DIR="${HM_PROC_DIR:-/proc}"

# ---- defaults (override in the config file) ---------------------------------
CPU_WARN=70;  CPU_CRIT=90        # 1-min load average as % of core count
MEM_WARN=80;  MEM_CRIT=92        # used memory %
DISK_WARN=80; DISK_CRIT=90       # used space % per filesystem
CERT_WARN_DAYS=21; CERT_CRIT_DAYS=7
FAILED_LOGIN_WARN=20; FAILED_LOGIN_CRIT=100
SERVICES=""                      # e.g. "ssh cron nginx"
PORTS=""                         # e.g. "127.0.0.1:22 127.0.0.1:443"
CERT_HOSTS=""                    # e.g. "example.com:443"
AUTH_LOG="/var/log/auth.log"
LOG_DIR="/var/log/health-monitor"
STATE_DIR="/var/lib/health-monitor"
ALERT_WEBHOOK_URL=""             # Slack/Teams/Discord-style incoming webhook
ALERT_MIN_LEVEL="WARN"           # WARN or CRIT
ALERT_REPEAT_MINUTES=60          # re-alert interval while unhealthy
HOSTNAME_LABEL="$(hostname 2>/dev/null || echo unknown-host)"

# ---- state ------------------------------------------------------------------
declare -a R_NAME=() R_LEVEL=() R_MSG=()
M_CPU=0; M_MEM=0; M_DISK=0
OVERALL="OK"

level_rank() { case "$1" in OK) echo 0 ;; WARN) echo 1 ;; CRIT) echo 2 ;; *) echo 1 ;; esac; }

# level_for VALUE WARN CRIT -> OK|WARN|CRIT (higher value = worse)
level_for() {
  local v=$1 w=$2 c=$3
  if   (( v >= c )); then echo CRIT
  elif (( v >= w )); then echo WARN
  else echo OK; fi
}

# level_for_days DAYS WARN_DAYS CRIT_DAYS (lower value = worse)
level_for_days() {
  local d=$1 w=$2 c=$3
  if   (( d <= c )); then echo CRIT
  elif (( d <= w )); then echo WARN
  else echo OK; fi
}

record() { R_NAME+=("$1"); R_LEVEL+=("$2"); R_MSG+=("$3"); }

json_escape() {
  local s=$1
  s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/\\n}; s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

days_until() {  # days_until "Jan  1 00:00:00 2027 GMT"
  local end now
  end=$(date -d "$1" +%s 2>/dev/null) || return 1
  now=$(date +%s)
  echo $(( (end - now) / 86400 ))
}

# ---- checks -----------------------------------------------------------------
check_cpu() {
  local load1 cores pct
  if ! read -r load1 _ < "$PROC_DIR/loadavg"; then record cpu WARN "cannot read loadavg"; return; fi
  cores="${HM_CORES:-$(nproc 2>/dev/null || echo 1)}"
  pct=$(awk -v l="$load1" -v c="$cores" 'BEGIN{printf "%d", (l/c)*100}')
  M_CPU=$pct
  record cpu "$(level_for "$pct" "$CPU_WARN" "$CPU_CRIT")" "load1=${load1} on ${cores} core(s) = ${pct}%"
}

check_memory() {
  local total avail pct
  total=$(awk '/^MemTotal:/{print $2}' "$PROC_DIR/meminfo" 2>/dev/null)
  avail=$(awk '/^MemAvailable:/{print $2}' "$PROC_DIR/meminfo" 2>/dev/null)
  if [[ -z "$total" || -z "$avail" || "$total" -eq 0 ]]; then record memory WARN "cannot read meminfo"; return; fi
  pct=$(( (total - avail) * 100 / total ))
  M_MEM=$pct
  record memory "$(level_for "$pct" "$MEM_WARN" "$MEM_CRIT")" "used ${pct}% ($(( (total - avail) / 1024 )) of $(( total / 1024 )) MiB)"
}

check_disks() {
  local fs size used avail pct mount
  while read -r fs size used avail pct mount; do
    pct=${pct%\%}
    [[ "$pct" =~ ^[0-9]+$ ]] || continue
    (( pct > M_DISK )) && M_DISK=$pct
    record "disk:${mount}" "$(level_for "$pct" "$DISK_WARN" "$DISK_CRIT")" "${pct}% used on ${fs}"
  done < <(df -P -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null | tail -n +2)
}

check_services() {
  local svc state
  for svc in $SERVICES; do
    if ! command -v systemctl >/dev/null 2>&1; then
      record "service:${svc}" WARN "systemctl not available"; continue
    fi
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
      record "service:${svc}" OK "active"
    else
      state=$(systemctl is-active "$svc" 2>/dev/null | head -n1 || true)
      [[ -n "$state" ]] || state="systemd unreachable"
      record "service:${svc}" CRIT "not active (${state})"
    fi
  done
}

check_ports() {
  local hp host port
  for hp in $PORTS; do
    host=${hp%:*}; port=${hp##*:}
    if timeout 3 bash -c "exec 3<>/dev/tcp/${host}/${port}" 2>/dev/null; then
      record "port:${hp}" OK "accepting connections"
    else
      record "port:${hp}" CRIT "connection refused or timed out"
    fi
  done
}

check_certs() {
  local hp host port enddate days
  for hp in $CERT_HOSTS; do
    host=${hp%:*}; port=${hp##*:}
    enddate=$(echo | timeout 8 openssl s_client -servername "$host" -connect "${host}:${port}" 2>/dev/null \
      | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
    if [[ -z "$enddate" ]] || ! days=$(days_until "$enddate"); then
      record "cert:${hp}" WARN "could not read certificate"; continue
    fi
    record "cert:${hp}" "$(level_for_days "$days" "$CERT_WARN_DAYS" "$CERT_CRIT_DAYS")" "expires in ${days} day(s)"
  done
}

check_failed_logins() {
  local n
  [[ -r "$AUTH_LOG" ]] || return 0
  n=$(tail -n 5000 "$AUTH_LOG" | grep -c "Failed password" || true)
  record failed-ssh "$(level_for "$n" "$FAILED_LOGIN_WARN" "$FAILED_LOGIN_CRIT")" "${n} failed SSH password attempts in last 5000 auth log lines"
}

# ---- output -----------------------------------------------------------------
compute_overall() {
  local i r=0 k
  for i in "${!R_LEVEL[@]}"; do
    k=$(level_rank "${R_LEVEL[$i]}"); (( k > r )) && r=$k
  done
  case $r in 0) OVERALL=OK ;; 1) OVERALL=WARN ;; *) OVERALL=CRIT ;; esac
}

render_text() {
  local i
  printf 'Health report for %s at %s (v%s)\n' "$HOSTNAME_LABEL" "$(date '+%F %T %Z')" "$HM_VERSION"
  printf 'Overall: %s\n\n' "$OVERALL"
  printf '%-6s %-28s %s\n' LEVEL CHECK DETAIL
  for i in "${!R_NAME[@]}"; do
    printf '%-6s %-28s %s\n' "${R_LEVEL[$i]}" "${R_NAME[$i]}" "${R_MSG[$i]}"
  done
}

render_json() {
  local i sep=""
  printf '{"host":"%s","time":"%s","overall":"%s","metrics":{"cpu_pct":%s,"mem_pct":%s,"max_disk_pct":%s},"checks":[' \
    "$(json_escape "$HOSTNAME_LABEL")" "$(date -Is)" "$OVERALL" "$M_CPU" "$M_MEM" "$M_DISK"
  for i in "${!R_NAME[@]}"; do
    printf '%s{"name":"%s","level":"%s","detail":"%s"}' "$sep" \
      "$(json_escape "${R_NAME[$i]}")" "${R_LEVEL[$i]}" "$(json_escape "${R_MSG[$i]}")"
    sep=","
  done
  printf ']}\n'
}

problems_summary() {
  local i out=""
  for i in "${!R_NAME[@]}"; do
    [[ "${R_LEVEL[$i]}" == OK ]] && continue
    out+="${R_LEVEL[$i]} ${R_NAME[$i]}: ${R_MSG[$i]}; "
  done
  printf '%s' "${out%; }"
}

ensure_dir() {  # ensure_dir VARNAME FALLBACK
  local -n ref=$1
  mkdir -p "$ref" 2>/dev/null && [[ -w "$ref" ]] && return 0
  ref="$2"; mkdir -p "$ref"
}

record_history() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -Is)" "$OVERALL" "$M_CPU" "$M_MEM" "$M_DISK" "$(problems_summary)" \
    >> "$LOG_DIR/history.tsv"
}

send_alert() {  # send_alert TEXT
  [[ -n "$ALERT_WEBHOOK_URL" ]] || return 0
  local text; text=$(json_escape "$1")
  curl -fsS -m 10 -H 'Content-Type: application/json' \
    -d "{\"text\":\"${text}\",\"content\":\"${text}\"}" "$ALERT_WEBHOOK_URL" >/dev/null \
    || echo "warning: alert delivery failed" >&2
}

maybe_alert() {
  local state="$STATE_DIR/last_status" prev="OK" prev_ts=0 now repeat_s
  now=$(date +%s); repeat_s=$(( ALERT_REPEAT_MINUTES * 60 ))
  [[ -r "$state" ]] && read -r prev prev_ts < "$state"
  if (( $(level_rank "$OVERALL") >= $(level_rank "$ALERT_MIN_LEVEL") )); then
    if [[ "$OVERALL" != "$prev" ]] || (( now - prev_ts >= repeat_s )); then
      send_alert "[${OVERALL}] ${HOSTNAME_LABEL}: $(problems_summary)"
      echo "$OVERALL $now" > "$state"
    fi
  else
    if [[ "$prev" != "OK" ]]; then
      send_alert "[RECOVERED] ${HOSTNAME_LABEL} is healthy again"
    fi
    echo "OK $now" > "$state"
  fi
}

usage() {
  cat <<USAGE
Usage: healthcheck.sh [--config FILE] [--json] [--quiet] [--no-alert] [--help] [--version]
Exit codes: 0 OK, 1 WARN, 2 CRIT
USAGE
}

main() {
  local cfg="${HM_CONFIG:-/etc/health-monitor/monitor.conf}" as_json=0 quiet=0 alert=1
  [[ -f "$cfg" ]] || cfg="$SCRIPT_DIR/../config/monitor.conf"
  while (( $# )); do
    case "$1" in
      --config) cfg="$2"; shift ;;
      --json) as_json=1 ;;
      --quiet) quiet=1 ;;
      --no-alert) alert=0 ;;
      --version) echo "$HM_VERSION"; return 0 ;;
      -h|--help) usage; return 0 ;;
      *) echo "unknown option: $1" >&2; usage >&2; return 64 ;;
    esac
    shift
  done
  # shellcheck source=/dev/null
  [[ -f "$cfg" ]] && source "$cfg"   # config must be root-owned and not world-writable

  ensure_dir LOG_DIR "${HOME:-/tmp}/.local/state/health-monitor/log"
  ensure_dir STATE_DIR "${HOME:-/tmp}/.local/state/health-monitor/state"

  check_cpu; check_memory; check_disks; check_services; check_ports; check_certs; check_failed_logins
  compute_overall
  record_history
  (( alert )) && maybe_alert

  if (( ! quiet )); then
    if (( as_json )); then render_json; else render_text; fi
  fi
  return "$(level_rank "$OVERALL")"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
