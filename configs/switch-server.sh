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
        if len(percity[r['city_code']])<2:
            percity[r['city_code']].append(r['ipv4_addr_in']+':'+r['hostname'])
for v in percity.values():
    for e in v: print(e)
PY

# Drop the tunnel so pings go direct over the physical uplink.
sudo wg-quick down mullvad >/dev/null 2>&1 || true
sleep 1

# Ping all candidates IN PARALLEL — total time is bounded by the slowest single
# ping (~2s), not the sum. Each writes "ms hostname ip" to its own temp file.
RESDIR=$(mktemp -d)
i=0
while IFS=: read ip hn; do
    [ -z "$ip" ] && continue
    (
        ms=$(ping -c 2 -W 1 -q "$ip" 2>/dev/null | tail -1 | sed 's|.*= ||' | cut -d/ -f2)
        [ -n "$ms" ] && echo "${ms%.*} $hn $ip" > "$RESDIR/$i"
    ) &
    i=$((i+1))
done < /tmp/cands.txt
wait

# Pick the lowest-latency result.
best_ip=""; best_hn=""; best_ms=99999
for f in "$RESDIR"/*; do
    [ -f "$f" ] || continue
    read m h p < "$f"
    if [ "$m" -lt "$best_ms" ] 2>/dev/null; then best_ms=$m; best_hn=$h; best_ip=$p; fi
done
rm -rf "$RESDIR"

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
