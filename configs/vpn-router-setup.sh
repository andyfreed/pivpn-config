#!/bin/bash
sleep 5

# Bring up VPN
wg-quick up mullvad

# NAT through VPN
nft add table nat 2>/dev/null
nft add chain nat postrouting { type nat hook postrouting priority 100 \; } 2>/dev/null
nft add rule nat postrouting oifname "mullvad" masquerade 2>/dev/null

# Kill switch: block eth0 -> wlan0 (ISP), only allow eth0 -> mullvad (VPN)
iptables -I FORWARD -i eth0 -o wlan0 -j DROP
iptables -I FORWARD -i eth0 -o mullvad -j ACCEPT
iptables -I FORWARD -i mullvad -o eth0 -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -I FORWARD -i eth0 -o tailscale0 -j ACCEPT
iptables -I FORWARD -i tailscale0 -o eth0 -m state --state RELATED,ESTABLISHED -j ACCEPT

# Block all IPv6 forwarding
ip6tables -I FORWARD -i eth0 -j DROP

# Restart dnsmasq
systemctl restart dnsmasq
