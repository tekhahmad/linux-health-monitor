# Linux Health Monitor

A small, dependency-free server monitoring toolkit written in Bash. It checks the health of a Linux server on a schedule, keeps a history, raises alerts when something is wrong and produces daily/weekly Markdown reports.

It watch uptime and capacity, catch problems early, escalate them, and keep a record.

## What it checks

| Check | Method | Default WARN / CRIT |
|---|---|---|
| CPU | 1-minute load average as % of core count | 70% / 90% |
| Memory | `MemAvailable` vs `MemTotal` | 80% / 92% |
| Disk | `df` per filesystem | 80% / 90% |
| Services | `systemctl is-active` | not active = CRIT |
| TCP ports | `/dev/tcp` connect with timeout | refused = CRIT |
| TLS certificates | `openssl s_client` expiry | 21 / 7 days |
| Failed SSH logins | count in auth log tail | 20 / 100 |

Exit codes follow the Nagios convention: `0` OK, `1` WARN, `2` CRIT, so it plugs into cron, systemd, CI or other monitors.

## Features

- Text and JSON output (`--json`)
- Alerts to any Slack/Teams/Discord-style webhook, with **de-duplication** (alerts on state change, repeats on an interval, sends a recovery notice)
- History file (`history.tsv`) and a report generator (`report.sh --days 1|7`)
- systemd service and timer with sandboxing (`ProtectSystem=strict`, `NoNewPrivileges`), plus a cron alternative
- Unit tests using fixture `/proc` files, ShellCheck and a smoke test in GitHub Actions

## Quick start

```bash
git clone <your-repo-url> && cd linux-health-monitor
./bin/healthcheck.sh                      # run once (works without root)
./bin/healthcheck.sh --json --no-alert    # machine-readable
./tests/run_tests.sh                      # run the tests

sudo ./install.sh                         # install under /opt and enable timers
sudo nano /etc/health-monitor/monitor.conf
systemctl list-timers | grep health
/opt/health-monitor/bin/report.sh --days 7
```

## Configuration

Edit `/etc/health-monitor/monitor.conf`: thresholds, `SERVICES`, `PORTS`, `CERT_HOSTS`, and `ALERT_WEBHOOK_URL`. The file is sourced by Bash, so it must be root-owned and not world-writable. Never commit a real webhook URL.

## Design decisions (good interview talking points)

- **Why Bash?** Present on every server, no runtime to patch, and easy to audit. Anything heavier belongs in Prometheus (see the sibling `edtech-api` project).
- **Testability:** `/proc` location and core count are injectable (`HM_PROC_DIR`, `HM_CORES`), so thresholds are tested against fixtures and the main function only runs when the script is executed, not sourced.
- **Alert fatigue:** state is stored between runs so the same CRIT does not page every 5 minutes.
- **systemd `SuccessExitStatus=1 2`:** WARN/CRIT are monitoring results, not unit failures.
- **Least privilege:** the unit is sandboxed; it only writes to its log and state directories.

## Limitations and next steps

- Failed-login check looks at the tail of `auth.log`, not a precise time window (journald support would be better).
- Load average is a rough CPU signal; pair with Prometheus `node_exporter` for real utilisation.
- Possible extensions: log rotation config, email via `msmtp`, a Prometheus textfile-collector output mode.
