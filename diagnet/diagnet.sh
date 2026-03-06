#!/usr/bin/env bash
set -euo pipefail
BASE="/opt/css_diag_agent"
CONF="${DIAGNET_CONF:-${BASE}/diagnet.conf}"
[[ -f "$CONF" ]] && source "$CONF"
HOSTNAME="$(hostname -s || echo unknown)"
LOG_DIR="${LOG_DIR:-/var/log/css_diag_agent}"; mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/diagnet.log"; touch "$LOG_FILE"
PERIOD_SEC="${PERIOD_SEC:-5}"; PING_THRESH_MS="${PING_THRESH_MS:-50}"; TCP_THRESH_MS="${TCP_THRESH_MS:-300}"; ECHO_THRESH_MS="${ECHO_THRESH_MS:-500}"; DNS_THRESH_MS="${DNS_THRESH_MS:-200}"; TRIGGER_COOLDOWN_SEC="${TRIGGER_COOLDOWN_SEC:-300}"
DNS_TARGETS="${DNS_TARGETS:-}"; read -ra _DNS_TARGETS <<< "$DNS_TARGETS"
# PEER_IPS: obligatorio desde el conf
if [[ -z "${PEER_IPS+x}" ]]; then echo "ERROR: PEER_IPS no definido. Editar $CONF" >&2; exit 1; fi
read -ra PEER_IPS <<< "$PEER_IPS"
PEER_PORT="${PEER_PORT:-9400}"
SNAPSHOT="${SNAPSHOT_SCRIPT:-${BASE}/vmwatch/snapshot.sh}"; TCPDUMP_SCRIPT="${TCPDUMP_SCRIPT:-${BASE}/vmwatch/tcpdump.sh}"
ts_iso(){ date -u +"%Y-%m-%dT%H:%M:%S.%3NZ"; }; now_sec(){ date +%s; }
log(){ echo "$(ts_iso) [$HOSTNAME] $*" | tee -a "$LOG_FILE" >/dev/null; }
local_ips(){ ip -4 -o addr show | awk '{sub(/\/.*/,"",$4); print $4}'; }
guard(){ local key="$1"; local now="$(now_sec)"; local f="$LOG_DIR/.trg_${key}"; if [[ -f "$f" ]]; then local last; last=$(cat "$f" 2>/dev/null || echo 0); (( now - last < TRIGGER_COOLDOWN_SEC )) && return 1; fi; echo "$now" > "$f"; return 0; }
trigger(){ local reason="$1" host="$2" port="$3"; [[ -x "$SNAPSHOT" ]] && nohup "$SNAPSHOT" "$LOG_DIR" "$HOSTNAME" "n/a" "n/a" "$reason" >/dev/null 2>&1 & [[ -x "$TCPDUMP_SCRIPT" ]] && nohup "$TCPDUMP_SCRIPT" "$LOG_DIR" "${host}:${port}" >/dev/null 2>&1 & if command -v sar >/dev/null 2>&1; then local TS; TS=$(date -u +%Y%m%dT%H%M%SZ); nohup sar -A 1 60 -o "$LOG_DIR/sar_1s_${TS}.sadc" >/dev/null 2>&1 & fi; }
icmp_probe(){ local h="$1"; local out; out=$(ping -n -c1 -W1 "$h" 2>/dev/null || true); local rtt; rtt=$(awk 'match($0,/time=([0-9.]+)[ ]*ms/,m){print m[1]}' <<<"$out" | head -n1); if [[ -n "$rtt" ]]; then log "PING_OK host=${h} rtt_ms=${rtt}"; if awk "BEGIN{exit !($rtt > $PING_THRESH_MS)}"; then if guard "PING_${h}"; then log "PING_SLOW_TRIGGER host=${h} rtt_ms=${rtt}"; trigger "PING_SLOW ${h}" "$h" "$PEER_PORT"; fi; fi; else log "PING_FAIL host=${h}"; if guard "PING_${h}"; then trigger "PING_FAIL ${h}" "$h" "$PEER_PORT"; fi; fi; }
tcp_probe(){ local host="$1" port="$2"; local t0; t0=$(date +%s%N); if nc -z -w2 "$host" "$port" 2>/dev/null; then local ms=$(( ( $(date +%s%N) - t0 ) / 1000000 )); log "TCP_OK target=${host}:${port} connect_ms=${ms}"; if (( ms > TCP_THRESH_MS )); then if guard "TCP_${host}_${port}"; then log "TCP_SLOW_TRIGGER target=${host}:${port} connect_ms=${ms}"; trigger "TCP_SLOW ${host}:${port}" "$host" "$port"; fi; fi; else local ms=$(( ( $(date +%s%N) - t0 ) / 1000000 )); log "TCP_FAIL target=${host}:${port} connect_ms=${ms}"; if guard "TCP_${host}_${port}"; then trigger "TCP_FAIL ${host}:${port}" "$host" "$port"; fi; fi; }
echo_rtt(){ local host="$1" port="$2"; local PY_BIN; PY_BIN=$(command -v python3 2>/dev/null || command -v python2.6 2>/dev/null || command -v python 2>/dev/null || true); if [[ -z "$PY_BIN" ]]; then log "ECHO_SKIP target=${host}:${port} reason=python_not_found"; return 0; fi; local out rc; set +e; out=$("$PY_BIN" - "$host" "$port" <<'PY'
import socket, time, sys
host = sys.argv[1]
port = int(sys.argv[2])
try:
    ns = time.time_ns()
except AttributeError:
    ns = int(time.time()*1e9)
token = ("PING%d" % ns).encode()
try:
    try:
        t0 = time.time_ns()
    except AttributeError:
        t0 = int(time.time()*1e9)
    s = socket.create_connection((host, port), 2.0)
    s.sendall(token)
    buf = b""
    while len(buf) < len(token):
        chunk = s.recv(4096)
        if not chunk:
            break
        buf += chunk
    s.close()
    ok = (buf == token)
    try:
        tn = time.time_ns()
    except AttributeError:
        tn = int(time.time()*1e9)
    ms = int((tn - t0)/1000000)
    print(("OK %d" if ok else "BAD %d") % ms)
except Exception:
    try:
        tn = time.time_ns()
    except AttributeError:
        tn = int(time.time()*1e9)
    ms = int((tn - t0)/1000000)
    print("ERR %d" % ms)
PY
); rc=$?; set -e; [[ $rc -ne 0 || -z "$out" ]] && out="ERR 0"; local status="${out%% *}"; local ms="${out##* }"; if [[ "$status" == "OK" ]]; then log "ECHO_OK target=${host}:${port} rtt_ms=${ms}"; if (( ms > ECHO_THRESH_MS )); then if guard "ECHO_${host}_${port}"; then log "ECHO_SLOW_TRIGGER target=${host}:${port} rtt_ms=${ms}"; trigger "ECHO_SLOW ${host}:${port}" "$host" "$port"; fi; fi; else log "ECHO_FAIL target=${host}:${port} rtt_ms=${ms}"; if guard "ECHO_${host}_${port}"; then trigger "ECHO_FAIL ${host}:${port}" "$host" "$port"; fi; fi; }
dns_probe(){ local name="$1"; local t0; t0=$(date +%s%N); local out; out=$(getent hosts "$name" 2>/dev/null || true); local ms=$(( ( $(date +%s%N) - t0 ) / 1000000 )); if [[ -n "$out" ]]; then local ip; ip=$(awk '{print $1; exit}' <<<"$out"); log "DNS_OK name=${name} ip=${ip} resolve_ms=${ms}"; if (( ms > DNS_THRESH_MS )); then if guard "DNS_${name}"; then log "DNS_SLOW_TRIGGER name=${name} resolve_ms=${ms}"; trigger "DNS_SLOW ${name}" "${PROBE_IPS[0]:-localhost}" "$PEER_PORT"; fi; fi; else log "DNS_FAIL name=${name} resolve_ms=${ms}"; if guard "DNS_${name}"; then trigger "DNS_FAIL ${name}" "${PROBE_IPS[0]:-localhost}" "$PEER_PORT"; fi; fi; }
LIPS=(); while IFS= read -r _l; do LIPS+=("$_l"); done < <(local_ips || true); PROBE_IPS=(); for ip in "${PEER_IPS[@]}"; do skip=0; for lip in "${LIPS[@]}"; do [[ "$ip" == "$lip" ]] && { skip=1; break; }; done; (( skip==0 )) && PROBE_IPS+=("$ip"); done
log "START diagnet (synthetic) period=${PERIOD_SEC}s peers=${PROBE_IPS[*]:-none} port=${PEER_PORT}"
while true; do for h in "${PROBE_IPS[@]}"; do icmp_probe "$h"; done; for h in "${PROBE_IPS[@]}"; do tcp_probe "$h" "$PEER_PORT"; done; for h in "${PROBE_IPS[@]}"; do echo_rtt "$h" "$PEER_PORT"; done; for d in "${_DNS_TARGETS[@]}"; do dns_probe "$d"; done; if [[ -f "$LOG_FILE" ]] && (( $(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0) > 52428800 )); then mv "$LOG_FILE" "${LOG_FILE}.$(date +%Y%m%d%H%M%S)"; : > "$LOG_FILE"; log "ROTATE diagnet"; fi; sleep "$PERIOD_SEC"; done
