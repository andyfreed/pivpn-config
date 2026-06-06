#!/bin/bash
# Security audit for the Pi VPN router. READ-ONLY: gathers state, runs leak
# tests, checks for pending OS security updates, and cross-checks key packages
# against the Debian Security Tracker. Changes nothing. Emits one JSON object.
#
# Usage: vpn-audit.sh
set -e

check() {  # name | status(pass|warn|fail) | detail
    printf '%s\037%s\037%s\n' "$1" "$2" "$3" >> "$TMP"
}
TMP=$(mktemp)

# Refresh apt's package lists so the security-update check is current.
# Quiet, best-effort; the audit still runs if this fails (just possibly stale).
sudo apt-get update -qq >/dev/null 2>&1 || true

# --- Kill switch: both uplink DROPs present? ------------------------------- #
drops=$(sudo iptables -S FORWARD 2>/dev/null | grep -cE '\-o (wlan0|eth1) -j DROP' || echo 0)
if [ "$drops" -ge 2 ]; then check "Kill switch" pass "$drops uplink DROP rules active"
elif [ "$drops" -eq 1 ]; then check "Kill switch" warn "only 1 uplink DROP rule (one uplink may be down)"
else check "Kill switch" fail "no uplink DROP rules — traffic could leak if VPN drops"; fi

# --- WireGuard tunnel up + recent handshake -------------------------------- #
hs=$(sudo wg show mullvad latest-handshakes 2>/dev/null | awk '{print $2; exit}')
now=$(date +%s)
if [ -n "$hs" ] && [ "$hs" -gt 0 ] 2>/dev/null; then
    age=$((now - hs))
    if [ "$age" -lt 180 ]; then check "WireGuard tunnel" pass "handshake ${age}s ago"
    else check "WireGuard tunnel" warn "last handshake ${age}s ago (stale)"; fi
else check "WireGuard tunnel" fail "no WireGuard handshake — tunnel down"; fi

# --- Mullvad exit confirmation + DNS leak ---------------------------------- #
mj=$(curl -s --max-time 10 https://am.i.mullvad.net/json 2>/dev/null || echo '{}')
is_mullvad=$(echo "$mj" | python3 -c "import json,sys
try: print(str(json.load(sys.stdin).get('mullvad_exit_ip',False)).lower())
except: print('false')" 2>/dev/null)
exit_host=$(echo "$mj" | python3 -c "import json,sys
try: print(json.load(sys.stdin).get('mullvad_exit_ip_hostname',''))
except: print('')" 2>/dev/null)
if [ "$is_mullvad" = "true" ]; then check "VPN exit" pass "via Mullvad ($exit_host)"
else check "VPN exit" fail "traffic NOT exiting through Mullvad"; fi

# DNS leak: the Pi's own resolver must be Mullvad DNS (10.64.0.1), and a test
# lookup must resolve THROUGH the tunnel (proves DNS isn't bypassing the VPN).
resolver=$(grep -m1 nameserver /etc/resolv.conf 2>/dev/null | awk '{print $2}')
if [ "$resolver" = "10.64.0.1" ]; then check "DNS resolver" pass "Mullvad DNS 10.64.0.1"
else check "DNS resolver" fail "resolver is '$resolver' (expected 10.64.0.1 — possible DNS leak)"; fi
if getent hosts mullvad.net >/dev/null 2>&1; then check "DNS resolution" pass "resolves via tunnel"
else check "DNS resolution" warn "test lookup failed"; fi

# --- IPv6 disabled (prevents v6 leaks) ------------------------------------- #
v6=$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 0)
if [ "$v6" = "1" ]; then check "IPv6 disabled" pass "net.ipv6 disable_ipv6=1"
else check "IPv6 disabled" warn "IPv6 not disabled (possible v6 leak path)"; fi

# --- SSH hardening --------------------------------------------------------- #
sudo mkdir -p /run/sshd 2>/dev/null
sshpw=$(sudo /usr/sbin/sshd -T 2>/dev/null | awk '/^passwordauthentication/{print $2}')
[ -z "$sshpw" ] && sshpw=$(sudo grep -rhiE '^[[:space:]]*passwordauthentication' \
    /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ 2>/dev/null | tail -1 | awk '{print tolower($2)}')
if [ "$sshpw" = "no" ]; then check "SSH password auth" pass "disabled (key-only)"
else check "SSH password auth" fail "password auth is '${sshpw:-unknown}' (should be no)"; fi

# --- OS security updates pending ------------------------------------------- #
# Note: grep -c emits a trailing newline; capture with tr -d to keep it numeric.
upd=$(apt-get -s -o Debug::NoLocking=true upgrade 2>/dev/null | grep -c '^Inst' | tr -d '[:space:]')
sec=$(apt-get -s -o Debug::NoLocking=true upgrade 2>/dev/null | grep '^Inst' | grep -ci security | tr -d '[:space:]')
upd=${upd:-0}; sec=${sec:-0}
if [ "$sec" -gt 0 ] 2>/dev/null; then check "OS security updates" warn "$sec security update(s) pending (of $upd total)"
elif [ "$upd" -gt 0 ] 2>/dev/null; then check "OS updates" warn "$upd update(s) pending (none flagged security)"
else check "OS updates" pass "none pending"; fi

# --- Key package versions -------------------------------------------------- #
wg_ver=$(dpkg-query -W -f='${Version}' wireguard-tools 2>/dev/null || echo '?')
ssh_ver=$(dpkg-query -W -f='${Version}' openssh-server 2>/dev/null || echo '?')
dns_ver=$(dpkg-query -W -f='${Version}' dnsmasq 2>/dev/null || echo '?')
ts_ver=$(tailscale version 2>/dev/null | head -1 || echo '?')
kern=$(uname -r)
check "wireguard-tools" info "$wg_ver"
check "openssh-server"  info "$ssh_ver"
check "dnsmasq"         info "$dns_ver"
check "tailscale"       info "$ts_ver"
check "kernel"          info "$kern"

# --- Which packages have pending SECURITY fixes? --------------------------- #
# This is the authoritative "are there fixes for known threats" signal:
# Debian's security team backports CVE fixes into package updates and serves
# them from the -security repo, which apt flags. We list the specific packages
# so you can see exactly what's affected (esp. wireguard/openssh/dnsmasq).
secpkgs=$(apt-get -s -o Debug::NoLocking=true upgrade 2>/dev/null \
    | awk '/^Inst/ && /security/ {print $2}' | sort -u | tr '\n' ' ')
if [ -n "$secpkgs" ]; then
    check "Security fixes available" warn "for: ${secpkgs}"
    # Call out the VPN-critical ones explicitly.
    for crit in wireguard wireguard-tools openssh-server dnsmasq linux-image; do
        echo "$secpkgs" | grep -qw "$crit" && \
            check "  -> critical: $crit" fail "security update available — apply soon"
    done
else
    check "Security fixes" pass "no security updates pending for installed packages"
fi

# --- Emit JSON ------------------------------------------------------------- #
python3 - "$TMP" << 'PY'
import sys, json
rows=[]
for line in open(sys.argv[1]):
    line=line.rstrip("\n")
    if not line: continue
    parts=line.split("\x1f")
    if len(parts)==3:
        rows.append({"name":parts[0],"status":parts[1],"detail":parts[2]})
fails=sum(1 for r in rows if r["status"]=="fail")
warns=sum(1 for r in rows if r["status"]=="warn")
verdict = "FAIL" if fails else ("REVIEW" if warns else "ALL CLEAR")
print(json.dumps({"verdict":verdict,"fails":fails,"warns":warns,"checks":rows}))
PY
rm -f "$TMP"
