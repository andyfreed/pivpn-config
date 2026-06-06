#!/bin/bash
# FAST real-time stats for the live meters. All reads are LOCAL (no network
# calls) so it returns in well under a second — safe to poll every ~2s.
# Emits one JSON object. The desktop app computes up/down RATES from the
# byte counters across successive polls.
set -e

IFACE=mullvad
RX=$(cat "/sys/class/net/$IFACE/statistics/rx_bytes" 2>/dev/null || echo 0)
TX=$(cat "/sys/class/net/$IFACE/statistics/tx_bytes" 2>/dev/null || echo 0)

# Handshake age (seconds); -1 if none.
hs=$(sudo wg show "$IFACE" latest-handshakes 2>/dev/null | awk '{print $2; exit}')
now=$(date +%s)
if [ -n "$hs" ] && [ "$hs" -gt 0 ] 2>/dev/null; then hs_age=$((now-hs)); else hs_age=-1; fi

# Tunnel up?
up=0; [ -d "/sys/class/net/$IFACE" ] && up=1

# Active uplink + wired status.
uplink=$(ip route 2>/dev/null | awk '/^default/{print $5; exit}')
eth1=$(cat /sys/class/net/eth1/carrier 2>/dev/null || echo 0)

# CPU temp (millidegrees -> C) and load average.
temp=$(vcgencmd measure_temp 2>/dev/null | sed 's/[^0-9.]//g')
[ -z "$temp" ] && temp=$(awk '{printf "%.1f", $1/1000}' /sys/class/thermal/thermal_zone0/temp 2>/dev/null)
load=$(awk '{print $1}' /proc/loadavg 2>/dev/null)

# CPU usage % over a short sample.
read -r _ a b c idle1 rest < /proc/stat
busy1=$((a+b+c)); total1=$((busy1+idle1))
sleep 0.2
read -r _ a b c idle2 rest < /proc/stat
busy2=$((a+b+c)); total2=$((busy2+idle2))
dt=$((total2-total1)); db=$((busy2-busy1))
cpu=0; [ "$dt" -gt 0 ] && cpu=$(( 100*db/dt ))

python3 - "$RX" "$TX" "$hs_age" "$up" "$uplink" "$eth1" "$temp" "$load" "$cpu" "$now" << 'PY'
import sys, json
a = sys.argv
print(json.dumps({
    "rx_bytes": int(a[1]), "tx_bytes": int(a[2]),
    "handshake_age": int(a[3]),
    "tunnel_up": a[4] == "1",
    "uplink": a[5], "wired": a[6].strip() == "1",
    "temp_c": float(a[7]) if a[7] else None,
    "load1": float(a[8]) if a[8] else None,
    "cpu_pct": int(a[9]),
    "t": int(a[10]),
}))
PY
