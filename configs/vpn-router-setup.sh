#!/bin/bash
sleep 5

# Specific hosts on the upstream LAN that the client LAN is allowed to reach
# directly (bypassing the VPN). Use for things like a local NAS that can't be
# put behind the VPN but still needs to be accessible from client devices.
# Leave empty to keep the kill switch fully strict.
LOCAL_LAN_HOSTS="192.168.68.51"  # FREEDPLEX (QNAP)

# Bring up VPN
wg-quick up mullvad

# Fix DNS to use Mullvad (Tailscale DNS can't resolve through VPN)
chattr -i /etc/resolv.conf 2>/dev/null
cp /etc/resolv.conf.mullvad /etc/resolv.conf
chattr +i /etc/resolv.conf

# NAT through VPN
nft add table nat 2>/dev/null
nft add chain nat postrouting { type nat hook postrouting priority 100 \; } 2>/dev/null

# Helper: delete every existing copy of an iptables rule, then add one.
# This makes the script idempotent (safe to re-run via `vpn-update.sh apply`)
# WITHOUT flushing whole chains — important because the FORWARD chain also
# holds Tailscale's own rules, which we must not remove.
rerule() {  # rerule <table-args...> -- <rule...>
    local pre=() rule=() seen=0
    for a in "$@"; do
        if [ "$a" = "--" ]; then seen=1; continue; fi
        if [ "$seen" = 0 ]; then pre+=("$a"); else rule+=("$a"); fi
    done
    while iptables "${pre[@]}" -D "${rule[@]}" 2>/dev/null; do :; done
    iptables "${pre[@]}" -I "${rule[@]}"
}

# nat postrouting: we own this chain's rules — flush just it (not a shared chain).
nft flush chain nat postrouting 2>/dev/null
nft add rule nat postrouting oifname "mullvad" masquerade 2>/dev/null

# Kill switch: block eth0 -> any uplink (wlan0 Wi-Fi, eth1 USB ethernet).
# Only eth0 -> mullvad (VPN) and eth0 -> tailscale0 are allowed.
rerule -- FORWARD -i eth0 -o wlan0 -j DROP
rerule -- FORWARD -i eth0 -o eth1 -j DROP
rerule -- FORWARD -i eth0 -o mullvad -j ACCEPT

# Local LAN exception: allow clients to reach specific hosts on the upstream
# LAN directly (e.g. a NAS). These rules are inserted ABOVE the uplink DROPs
# so they match first. Rules are uplink-interface-agnostic — they work whether
# the Pi is currently using eth1 (USB ethernet) or wlan0 (Wi-Fi fallback) for
# its uplink. Source-NAT so the remote host sees traffic coming from the Pi's
# upstream address and can reply without knowing about 192.168.5.0/24.
for host in $LOCAL_LAN_HOSTS; do
    rerule -- FORWARD -i eth0 -d "$host" -j ACCEPT
    rerule -- FORWARD -o eth0 -s "$host" -m state --state RELATED,ESTABLISHED -j ACCEPT
    nft add rule nat postrouting ip daddr "$host" ip saddr 192.168.5.0/24 masquerade 2>/dev/null
done
rerule -- FORWARD -i mullvad -o eth0 -m state --state RELATED,ESTABLISHED -j ACCEPT
rerule -- FORWARD -i eth0 -o tailscale0 -j ACCEPT
rerule -- FORWARD -i tailscale0 -o eth0 -m state --state RELATED,ESTABLISHED -j ACCEPT

# Block all IPv6 forwarding
rerule -6 -- FORWARD -i eth0 -j DROP

# MSS clamping to fix HTTPS through VPN tunnel
rerule -t mangle -- POSTROUTING -o mullvad -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
rerule -t mangle -- FORWARD -o mullvad -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

# DHCP/DNS for the client LAN is provided by NetworkManager's shared mode on
# eth0 (it spawns its own dnsmasq on 192.168.5.1, forwarding DNS to whatever
# /etc/resolv.conf says — i.e. Mullvad 10.64.0.1 through the tunnel). The
# standalone dnsmasq service is disabled; nothing to restart here.
