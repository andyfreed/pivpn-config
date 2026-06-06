#!/bin/bash
# Control actions for the desktop app. One subcommand per invocation.
# Usage:
#   vpn-ctl.sh reconnect              - bounce the tunnel (same server)
#   vpn-ctl.sh pause <minutes>        - drop VPN+kill switch, auto-re-arm later
#   vpn-ctl.sh resume                 - re-arm now (cancel a pause)
#   vpn-ctl.sh reboot                 - reboot the Pi
#   vpn-ctl.sh locations              - JSON list of Mullvad cities (for picker)
#   vpn-ctl.sh connect <hostname>     - switch to a specific server by hostname
set -e
ACTION="${1:-}"
RELAYS=/tmp/relays-ctl.json
PAUSE_UNIT=vpn-resume.timer

case "$ACTION" in
  reconnect)
    sudo wg-quick down mullvad >/dev/null 2>&1 || true
    sudo wg-quick up mullvad >/dev/null 2>&1
    sleep 2
    echo '{"ok": true, "action": "reconnect"}'
    ;;

  pause)
    MIN="${2:-5}"
    # Drop the tunnel and the kill switch so normal traffic flows, then
    # schedule an automatic re-arm so you can't forget and stay exposed.
    sudo wg-quick down mullvad >/dev/null 2>&1 || true
    sudo iptables -D FORWARD -i eth0 -o wlan0 -j DROP 2>/dev/null || true
    sudo iptables -D FORWARD -i eth0 -o eth1 -j DROP 2>/dev/null || true
    # One-shot systemd timer to re-run the router setup (re-arms everything).
    sudo systemd-run --on-active="${MIN}m" --unit=vpn-resume \
        /usr/local/bin/vpn-ctl.sh resume >/dev/null 2>&1 || \
        ( sleep "$((MIN*60))" && /usr/local/bin/vpn-ctl.sh resume ) &
    python3 -c "import json;print(json.dumps({'ok':True,'action':'pause','minutes':int('$MIN')}))"
    ;;

  resume)
    sudo systemctl stop "$PAUSE_UNIT" 2>/dev/null || true
    sudo /usr/local/bin/vpn-router-setup.sh >/dev/null 2>&1 || true
    sleep 2
    echo '{"ok": true, "action": "resume"}'
    ;;

  reboot)
    echo '{"ok": true, "action": "reboot"}'
    sudo systemctl reboot
    ;;

  locations)
    curl -s --max-time 20 https://api.mullvad.net/www/relays/wireguard/ -o "$RELAYS"
    python3 - "$RELAYS" << 'PY'
import json, sys
d = json.load(open(sys.argv[1]))
seen = {}
for r in d:
    if not r.get('active'):
        continue
    key = (r.get('country_code'), r.get('city_code'))
    if key in seen:
        continue
    seen[key] = {
        "country": r.get('country_name'),
        "country_code": r.get('country_code'),
        "city": r.get('city_name'),
        "city_code": r.get('city_code'),
        "hostname": r.get('hostname'),   # a representative server in that city
    }
out = sorted(seen.values(), key=lambda x: (x["country"] or "", x["city"] or ""))
print(json.dumps(out))
PY
    ;;

  connect)
    HOST="${2:?hostname required}"
    curl -s --max-time 20 https://api.mullvad.net/www/relays/wireguard/ -o "$RELAYS"
    INFO=$(python3 - "$RELAYS" "$HOST" << 'PY'
import json, sys
d = json.load(open(sys.argv[1])); host = sys.argv[2]
for r in d:
    if r.get('hostname') == host:
        print(r['pubkey'], r['ipv4_addr_in']); break
PY
)
    PUB=$(echo "$INFO" | cut -d' ' -f1); IP=$(echo "$INFO" | cut -d' ' -f2)
    if [ -z "$IP" ]; then echo '{"ok": false, "error": "server not found"}'; exit 1; fi
    sudo sed -i "s|PublicKey = .*|PublicKey = $PUB|; s|Endpoint = .*|Endpoint = $IP:51820|" /etc/wireguard/mullvad.conf
    sudo wg-quick down mullvad >/dev/null 2>&1 || true
    sudo wg-quick up mullvad >/dev/null 2>&1
    sleep 3
    loc=$(curl -s --max-time 12 https://am.i.mullvad.net/json 2>/dev/null \
          | python3 -c "import json,sys;d=json.load(sys.stdin);print(d.get('city','?')+', '+d.get('country','?'))" 2>/dev/null)
    python3 -c "import json;print(json.dumps({'ok':True,'action':'connect','host':'$HOST','location':'''$loc'''}))"
    ;;

  *)
    echo '{"ok": false, "error": "usage: reconnect|pause <min>|resume|reboot|locations|connect <host>"}'
    exit 1
    ;;
esac
