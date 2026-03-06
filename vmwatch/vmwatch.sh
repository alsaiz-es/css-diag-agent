#!/usr/bin/env bash
set -euo pipefail
BASE="/opt/css_diag_agent"
CONF="${DIAGNET_CONF:-${BASE}/diagnet.conf}"
[[ -f "$CONF" ]] && source "$CONF"
# PEER_IPS: obligatorio desde el conf
PEER_PORT="${PEER_PORT:-9400}"
if [[ -z "${PEER_IPS+x}" ]]; then echo "ERROR: PEER_IPS no definido. Editar $CONF" >&2; exit 1; fi
read -ra _ips <<< "$PEER_IPS"; PEERS=(); for _ip in "${_ips[@]}"; do PEERS+=("${_ip}:${PEER_PORT}"); done
LOG_DIR="${LOG_DIR:-/var/log/css_diag_agent}"
SNAPSHOT="${SNAPSHOT_SCRIPT:-${BASE}/vmwatch/snapshot.sh}"
TCPDUMP_SCRIPT="${TCPDUMP_SCRIPT:-${BASE}/vmwatch/tcpdump.sh}"
JITTER_THRESHOLD_MS="${JITTER_THRESHOLD_MS:-200}"
PERIOD_MS="${PERIOD_MS:-1000}"
NET_EVERY="${NET_EVERY:-3}"
DISK_EVERY="${DISK_EVERY:-10}"
HOSTNAME="$(hostname -s || echo unknown)"
mkdir -p "$LOG_DIR"; LOG_FILE="$LOG_DIR/vmwatch.log"; touch "$LOG_FILE"
ts_iso(){ date -u +"%Y-%m-%dT%H:%M:%S.%3NZ"; }
log(){ echo "$(ts_iso) [$HOSTNAME] $*" | tee -a "$LOG_FILE" >/dev/null; }
now_ns(){ date +%s%N; }
net_check(){ local peer="$1"; local host="${peer%%:*}"; local port="${peer##*:}"; local sns; sns=$(now_ns); if nc -z -w2 "$host" "$port" 2>/dev/null; then local ens; ens=$(now_ns); local ms=$(( (ens - sns) / 1000000 )); log "NET_OK peer=${peer} connect_ms=${ms}"; else local ens; ens=$(now_ns); local ms=$(( (ens - sns) / 1000000 )); log "NET_FAIL peer=${peer} connect_ms=${ms}"; fi; }
disk_check(){ local tmp="${LOG_DIR}/.io_test.$$"; local sns; sns=$(now_ns); ( dd if=/dev/zero of="${tmp}" bs=4k count=8 oflag=dsync 2>/dev/null ) || true; local ens; ens=$(now_ns); local ms=$(( (ens - sns) / 1000000 )); rm -f "${tmp}" || true; log "DISK_SNAP write_fsync_ms=${ms}"; }
trigger(){ local reason="$1"; [[ -x "$SNAPSHOT" ]] && nohup "$SNAPSHOT" "$LOG_DIR" "$HOSTNAME" "$JITTER_THRESHOLD_MS" "$PERIOD_MS" "$reason" >/dev/null 2>&1 & [[ -x "$TCPDUMP_SCRIPT" ]] && nohup "$TCPDUMP_SCRIPT" "$LOG_DIR" "${PEERS[*]}" >/dev/null 2>&1 & }
last_ns="$(now_ns)"; cycle=0; log "START vmwatch period_ms=${PERIOD_MS} jitter_thresh_ms=${JITTER_THRESHOLD_MS} peers=${PEERS[*]}"
while true; do
  sleep "$(awk -v ms="${PERIOD_MS}" 'BEGIN {printf "%.3f", ms/1000}')"; cycle=$((cycle+1))
  now_ns="$(now_ns)"; delta_ms=$(( (now_ns - last_ns) / 1000000 )); last_ns="$now_ns"
  if (( delta_ms > (PERIOD_MS + JITTER_THRESHOLD_MS) )); then log "SCHED_JITTER delta_ms=${delta_ms}"; trigger "SCHED_JITTER delta_ms=${delta_ms}"; else log "HEARTBEAT delta_ms=${delta_ms}"; fi
  if (( NET_EVERY > 0 && cycle % NET_EVERY == 0 )); then for p in "${PEERS[@]}"; do net_check "$p" & done; fi
  if (( DISK_EVERY > 0 && cycle % DISK_EVERY == 0 )); then disk_check & fi
done
