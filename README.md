# css_diag_agent

Lightweight diagnostic toolkit for monitoring network and VM health across Linux clusters. Pure Bash + one Python echo server — no heavy dependencies.

Designed to detect and capture evidence of intermittent infrastructure issues: network micro-outages, scheduling jitter from noisy neighbors, DNS resolution failures, and disk I/O stalls.

## What it does

| Subsystem | Purpose | Default interval |
|---|---|---|
| **diagnet** | ICMP ping, TCP connect, echo RTT, and DNS probes against cluster peers | 5 s |
| **vmwatch** | Scheduling jitter detection, periodic TCP and disk fsync checks | 1 s |
| **alerts** | Periodic summary of incidents from both logs, syslog + email notification | 5 min |

When a threshold is exceeded, the toolkit automatically captures:
- **System snapshot** — clocksource, CPU, memory, IRQ, network stats, kernel warnings, top processes (saved as `.tgz`)
- **Packet capture** — 65s tcpdump filtered to peer IPs/ports
- **sar recording** — 1-second granularity system activity data

A per-event cooldown (default 300s) prevents trigger storms.

## Quick start

```bash
# 1. Edit configuration — set your peer IPs at minimum
vim diagnet.conf

# 2. Install everything (requires root)
chmod +x install.sh
./install.sh

# 3. Check status
./install.sh --status
```

Selective installation:

```bash
./install.sh --diagnet    # probes + echo server only
./install.sh --vmwatch    # jitter detector only
./install.sh --alerts     # periodic summaries only
./install.sh --uninstall  # stop services, remove units (keeps data)
```

## Init system compatibility

The installer auto-detects the init system and adapts accordingly:

| Init system | Detection | Services | Alerts scheduling |
|---|---|---|---|
| **systemd** | `/run/systemd/system` exists | `.service` units via `systemctl` | systemd timer (every 5 min) |
| **SysV init** | fallback | `/etc/init.d/` scripts via `update-rc.d` or `chkconfig` | cron job in `/etc/cron.d/` |

### systemd services

| Unit | Description |
|---|---|
| `echo_server.service` | TCP echo server on `PEER_PORT` |
| `diagnet.service` | Continuous probe loop |
| `vmwatch.service` | Jitter + net + disk heartbeat loop |
| `diagnet-alert.timer` | Triggers `diagnet-alert.service` every 5 min |

### SysV init services

| Script | Description |
|---|---|
| `css-echo-server` | TCP echo server (uses python3/python2.6/python auto-detection) |
| `css-diagnet` | Continuous probe loop |
| `css-vmwatch` | Jitter + net + disk heartbeat loop |
| `css-diagnet-alert` (cron) | Alert summary every 5 min via `/etc/cron.d/` |

All init.d scripts support `start`, `stop`, `restart`, and `status` commands.

## Configuration

All settings live in `diagnet.conf`, sourced by every script. The installer copies it to `/opt/css_diag_agent/diagnet.conf` only if no config exists yet.

```bash
# Required — space-separated peer IPs
PEER_IPS="10.0.0.1 10.0.0.2"

# Echo server port (runs on each node)
PEER_PORT=9400

# diagnet probes
PERIOD_SEC=5
PING_THRESH_MS=50
TCP_THRESH_MS=300
ECHO_THRESH_MS=500
TRIGGER_COOLDOWN_SEC=300

# DNS probe (empty = disabled)
DNS_TARGETS="google.com internal.corp"
DNS_THRESH_MS=200

# vmwatch
PERIOD_MS=1000
JITTER_THRESHOLD_MS=200
NET_EVERY=3
DISK_EVERY=10

# alerts
DIAGNOSTIC_WINDOW_MIN=15
```

## Directory layout

```
/opt/css_diag_agent/
├── diagnet.conf
├── diagnet/
│   ├── diagnet.sh            # probe loop
│   ├── echo_server.py        # TCP echo server
│   ├── diagnet_report.sh     # one-shot log reporter
│   ├── diagnet.service        # systemd unit
│   ├── diagnet.init           # SysV init script
│   ├── echo_server.service    # systemd unit
│   └── echo_server.init       # SysV init script
├── vmwatch/
│   ├── vmwatch.sh             # jitter + net + disk loop
│   ├── snapshot.sh            # system snapshot
│   ├── tcpdump.sh             # packet capture
│   ├── vmwatch.service        # systemd unit
│   └── vmwatch.init           # SysV init script
└── alerts/
    ├── diagnet_alert.sh       # periodic summary
    ├── diagnet-alert.service  # systemd unit
    ├── diagnet-alert.timer    # systemd timer
    └── diagnet-alert.cron     # cron alternative

/var/log/css_diag_agent/
├── diagnet.log                # probe results (auto-rotates at 50MB)
├── vmwatch.log                # heartbeats and events
├── alerts.log                 # periodic summaries
├── tcpdump.log                # capture log
├── snapshot_*.tgz             # system snapshots
├── pcap_*.pcap                # packet captures
└── sar_1s_*.sadc              # sar recordings
```

## Log format

All events follow the same structure:

```
2025-06-15T10:30:05.123Z [hostname] EVENT_TYPE key=value ...
```

Event types: `PING_OK`, `PING_FAIL`, `PING_SLOW_TRIGGER`, `TCP_OK`, `TCP_FAIL`, `TCP_SLOW_TRIGGER`, `ECHO_OK`, `ECHO_FAIL`, `ECHO_SLOW_TRIGGER`, `DNS_OK`, `DNS_FAIL`, `DNS_SLOW_TRIGGER`, `SCHED_JITTER`, `NET_OK`, `NET_FAIL`, `DISK_SNAP`, `HEARTBEAT`.

## Requirements

- Linux with systemd or SysV init (auto-detected)
- Bash 3.x+, coreutils, iputils (ping), nc (netcat)
- Python 2.4+ or 3.x (echo server only)
- Optional: tcpdump, sysstat (sar, mpstat, pidstat, iostat)

## License

[MIT](LICENSE)
