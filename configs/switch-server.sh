#!/bin/bash
# Switch Mullvad to the fastest server in a region. Usage: switch-server.sh us|eu
# Measures true latency with the tunnel DOWN (kill switch stays armed → no leak),
# then brings the tunnel up on the winner.
set -e
REGION="${1:-us}"
RELAYS=/tmp/relays-switch.json

if [ "$REGION" = "eu" ]; then CCS="gb nl fr be ie de"; else CCS="us"; fi

# Need the API before we drop the tunnel — fetch via current connection.
curl -s --max-time 20 https://api.mullvad.net/www/relays/wireguard/ -o "$RELAYS"

python3 - "$RELAYS" "$CCS" > /tmp/cands.txt << 'PY'
import json,sys
relays,ccs=sys.argv[1],set(sys.argv[2].split())
d=json.load(open(relays))
percity={}
for r in d:
    if r.get('country_code') in ccs and r.get('active'):
        percity.setdefault(r.get('city_code'),[])
        if len(percity[r['city_code']])<3:
            percity[r['city_code']].append(r['ipv4_addr_in']+':'+r['hostname'])
for v in percity.values():
    for e in v: print(e)
PY

# Drop the tunnel so pings go direct over the physical uplink.
sudo wg-quick down mullvad >/dev/null 2>&1 || true
sleep 1

best_ip=""; best_hn=""; best_ms=99999
while IFS=: read ip hn; do
    ms=$(ping -c 3 -W 1 -q "$ip" 2>/dev/null | tail -1 | sed 's|.*= ||' | cut -d/ -f2)
    [ -z "$ms" ] && continue
    msi=${ms%.*}
    if [ "$msi" -lt "$best_ms" ] 2>/dev/null; then best_ms=$msi; best_ip=$ip; best_hn=$hn; fi
done < /tmp/cands.txt

if [ -z "$best_ip" ]; then
    echo "ERROR: no reachable server; restoring tunnel"
    sudo wg-quick up mullvad >/dev/null 2>&1; exit 1
fi

PUBKEY=$(python3 -c "import json
for r in json.load(open('$RELAYS')):
    if r.get('hostname')=='$best_hn': print(r['pubkey']); break")

sudo sed -i "s|PublicKey = .*|PublicKey = $PUBKEY|; s|Endpoint = .*|Endpoint = $best_ip:51820|" /etc/wireguard/mullvad.conf
sudo wg-quick up mullvad >/dev/null 2>&1
sleep 3
echo "Switched to $best_hn (~${best_ms}ms direct)"
curl -s --max-time 12 https://am.i.mullvad.net/connected
echo
