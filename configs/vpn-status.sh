#!/bin/bash
# Emit current VPN/router status as JSON for the desktop app.
# Safe to run anytime; read-only.
set -e

# Mullvad connection check (best-effort, short timeout)
MULLVAD_JSON=$(curl -s --max-time 8 https://am.i.mullvad.net/json 2>/dev/null || echo '{}')
connected=$(echo "$MULLVAD_JSON" | python3 -c "import json,sys
try: print(str(json.load(sys.stdin).get('mullvad_exit_ip', False)).lower())
except: print('false')" 2>/dev/null)
exit_ip=$(echo "$MULLVAD_JSON"   | python3 -c "import json,sys
try: print(json.load(sys.stdin).get('ip',''))
except: print('')" 2>/dev/null)
city=$(echo "$MULLVAD_JSON"      | python3 -c "import json,sys
try: print(json.load(sys.stdin).get('city',''))
except: print('')" 2>/dev/null)
country=$(echo "$MULLVAD_JSON"   | python3 -c "import json,sys
try: print(json.load(sys.stdin).get('country',''))
except: print('')" 2>/dev/null)
hostname=$(echo "$MULLVAD_JSON"  | python3 -c "import json,sys
try: print(json.load(sys.stdin).get('mullvad_exit_ip_hostname',''))
except: print('')" 2>/dev/null)

# WireGuard handshake age (seconds since last handshake), -1 if none
hs_epoch=$(sudo wg show mullvad latest-handshakes 2>/dev/null | awk '{print $2; exit}')
now=$(date +%s)
if [ -n "$hs_epoch" ] && [ "$hs_epoch" -gt 0 ] 2>/dev/null; then
    hs_age=$((now - hs_epoch))
else
    hs_age=-1
fi

# Active uplink interface + whether the wired dongle is up
uplink=$(ip route 2>/dev/null | awk '/^default/{print $5; exit}')
eth1_carrier=$(cat /sys/class/net/eth1/carrier 2>/dev/null || echo 0)

# Kill switch sanity: count the DROP rules and NAS allowlist rules
drop_rules=$(sudo iptables -S FORWARD 2>/dev/null | grep -cE 'DROP' || echo 0)
nas_rules=$(sudo iptables -S FORWARD 2>/dev/null | grep -c '192.168.68.51' || echo 0)

# Config version (Pi-side repo HEAD)
cfg_commit=$(cd "$HOME/pivpn-config" 2>/dev/null && git rev-parse --short HEAD 2>/dev/null || echo 'unknown')

python3 - "$connected" "$exit_ip" "$city" "$country" "$hostname" "$hs_age" \
            "$uplink" "$eth1_carrier" "$drop_rules" "$nas_rules" "$cfg_commit" << 'PY'
import json, sys
a = sys.argv
print(json.dumps({
    "connected":    a[1] == "true",
    "exit_ip":      a[2],
    "city":         a[3],
    "country":      a[4],
    "hostname":     a[5],
    "handshake_age": int(a[6]) if a[6].lstrip('-').isdigit() else -1,
    "uplink":       a[7],
    "wired_up":     a[8].strip() == "1",
    "kill_switch_drops": int(a[9]) if a[9].isdigit() else 0,
    "nas_rules":    int(a[10]) if a[10].isdigit() else 0,
    "config_commit": a[11],
}))
PY
