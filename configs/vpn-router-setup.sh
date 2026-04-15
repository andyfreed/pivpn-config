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
nft add rule nat postrouting oifname "mullvad" masquerade 2>/dev/null

# Kill switch: block eth0 -> any uplink (wlan0 Wi-Fi, eth1 USB ethernet).
# Only eth0 -> mullvad (VPN) and eth0 -> tailscale0 are allowed.
iptables -I FORWARD -i eth0 -o wlan0 -j DROP
iptables -I FORWARD -i eth0 -o eth1 -j DROP
iptables -I FORWARD -i eth0 -o mullvad -j ACCEPT

# Local LAN exception: allow clients to reach specific hosts on the upstream
# LAN directly (e.g. a NAS). These rules are inserted ABOVE the eth1 DROP so
# they match first. Source-NAT so the remote host sees traffic coming from the
# Pi's eth1 address and can reply without knowing about 192.168.5.0/24.
for host in $LOCAL_LAN_HOSTS; do
    iptables -I FORWARD -i eth0 -o eth1 -d "$host" -j ACCEPT
    iptables -I FORWARD -i eth1 -o eth0 -s "$host" -m state --state RELATED,ESTABLISHED -j ACCEPT
    nft add rule nat postrouting oifname "eth1" ip daddr "$host" ip saddr 192.168.5.0/24 masquerade 2>/dev/null
done
iptables -I FORWARD -i mullvad -o eth0 -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -I FORWARD -i eth0 -o tailscale0 -j ACCEPT
iptables -I FORWARD -i tailscale0 -o eth0 -m state --state RELATED,ESTABLISHED -j ACCEPT

# Block all IPv6 forwarding
ip6tables -I FORWARD -i eth0 -j DROP

# MSS clamping to fix HTTPS through VPN tunnel
iptables -t mangle -A POSTROUTING -o mullvad -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
iptables -t mangle -A FORWARD -o mullvad -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

# Restart dnsmasq
systemctl restart dnsmasq
