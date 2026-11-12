#!/usr/bin/env bash
# Installs the monitor under /opt/health-monitor and enables systemd timers. Run as root.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
install -d /opt/health-monitor/bin /etc/health-monitor /var/log/health-monitor /var/lib/health-monitor
install -m 0755 "$SRC"/bin/*.sh /opt/health-monitor/bin/
[[ -f /etc/health-monitor/monitor.conf ]] || install -m 0644 "$SRC/config/monitor.conf" /etc/health-monitor/monitor.conf
install -m 0644 "$SRC"/systemd/*.service "$SRC"/systemd/*.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now health-monitor.timer health-report.timer
echo "Installed. Try: systemctl start health-monitor.service && tail /var/log/health-monitor/history.tsv"
