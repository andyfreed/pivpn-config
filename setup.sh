#!/bin/bash
set -e

# PiVPN Setup Script
# Run on a fresh Raspberry Pi OS install to configure:
# - Mullvad VPN via WireGuard
# - Ethernet sharing with kill switch
# - Tailscale for remote access
# - IPv6 disabled, ICMP hardened, SSH key-only

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Prompt for Mullvad account number
read -p "Enter your Mullvad account number: " MULLVAD_ACCOUNT
if [ -z "$MULLVAD_ACCOUNT" ]; then
    echo "Error: account number cannot be empty"
    exit 1
fi

echo "=== Updating system ==="
sudo apt-get update
sudo apt-get upgrade -y

echo "=== Installing packages ==="
sudo apt-get install -y wireguard wireguard-tools dnsmasq openresolv

echo "=== Installing Tailscale ==="
curl -fsSL https://tailscale.com/install.sh | sudo sh

echo "=== Generating WireGuard keys ==="
WG_PRIVATE=$(wg genkey)
WG_PUBLIC=$(echo "$WG_PRIVATE" | wg pubkey)

echo "=== Registering key with Mullvad ==="
MULLVAD_RESPONSE=$(curl -s -d account="$MULLVAD_ACCOUNT" --data-urlencode pubkey="$WG_PUBLIC" https://api.mullvad.net/wg/)
MULLVAD_ADDR=$(echo "$MULLVAD_RESPONSE" | cut -d',' -f1)

if [ -z "$MULLVAD_ADDR" ] || echo "$MULLVAD_ADDR" | grep -q "error"; then
    echo "Error registering with Mullvad: $MULLVAD_RESPONSE"
    exit 1
fi
echo "Got Mullvad address: $MULLVAD_ADDR"

# Pick a server - default to NYC
echo ""
echo "Available US cities: nyc, lax, chi, dal, mia, sea, atl, slc, phx, den"
read -p "Enter city code (default: nyc): " CITY
CITY=${CITY:-nyc}

SERVER_INFO=$(curl -s https://api.mullvad.net/www/relays/wireguard/ | python3 -c "
import json, sys
data = json.load(sys.stdin)
for r in data:
    if r.get('country_code') == 'us' and r.get('active') and '$CITY' in r.get('city_code', ''):
        print(f\"{r['ipv4_addr_in']} {r['pubkey']}\")
        break
")

SERVER_IP=$(echo "$SERVER_INFO" | cut -d' ' -f1)
SERVER_PUBKEY=$(echo "$SERVER_INFO" | cut -d' ' -f2)

if [ -z "$SERVER_IP" ]; then
    echo "Error: could not find a server in $CITY"
    exit 1
fi
echo "Using server: $SERVER_IP"

echo "=== Configuring WireGuard ==="
sudo cp "$SCRIPT_DIR/configs/mullvad.conf" /etc/wireguard/mullvad.conf
sudo sed -i "s|CHANGE_ME_PRIVATE_KEY|$WG_PRIVATE|" /etc/wireguard/mullvad.conf
sudo sed -i "s|CHANGE_ME_ADDRESS|$(echo $MULLVAD_ADDR | cut -d'/' -f1)|" /etc/wireguard/mullvad.conf
sudo sed -i "s|CHANGE_ME_SERVER_PUBKEY|$SERVER_PUBKEY|" /etc/wireguard/mullvad.conf
sudo sed -i "s|CHANGE_ME_SERVER_IP|$SERVER_IP|" /etc/wireguard/mullvad.conf
sudo chmod 600 /etc/wireguard/mullvad.conf

echo "=== Copying config files ==="
sudo cp "$SCRIPT_DIR/configs/dnsmasq.conf" /etc/dnsmasq.conf
sudo cp "$SCRIPT_DIR/configs/90-ipforward.conf" /etc/sysctl.d/90-ipforward.conf
sudo cp "$SCRIPT_DIR/configs/91-disable-ipv6.conf" /etc/sysctl.d/91-disable-ipv6.conf
sudo sysctl --system

sudo cp "$SCRIPT_DIR/configs/vpn-router-setup.sh" /usr/local/bin/vpn-router-setup.sh
sudo chmod +x /usr/local/bin/vpn-router-setup.sh
sudo cp "$SCRIPT_DIR/configs/vpn-router.service" /etc/systemd/system/vpn-router.service

echo "=== Configuring ethernet sharing ==="
ETH_CONN=$(nmcli -t -f NAME,TYPE connection show | grep ethernet | head -1 | cut -d: -f1)
sudo nmcli connection modify "$ETH_CONN" ipv4.method shared ipv4.addresses 192.168.5.1/24 ipv4.gateway "" connection.autoconnect yes

echo "=== Hardening SSH ==="
sudo sed -i "s/#PasswordAuthentication yes/PasswordAuthentication no/" /etc/ssh/sshd_config
sudo sed -i "s/PasswordAuthentication yes/PasswordAuthentication no/" /etc/ssh/sshd_config
sudo systemctl restart sshd

echo "=== Enabling services ==="
sudo systemctl daemon-reload
sudo systemctl enable dnsmasq
sudo systemctl enable vpn-router.service

echo "=== Setting up Tailscale ==="
echo "Run 'sudo tailscale up --ssh' and authenticate when ready."

echo ""
echo "=== Setup complete! ==="
echo "Reboot to start everything, or run:"
echo "  sudo wg-quick up mullvad"
echo "  sudo /usr/local/bin/vpn-router-setup.sh"
echo ""
echo "Ethernet clients get 192.168.5.x, all traffic goes through Mullvad VPN"
echo "Kill switch active: if VPN drops, traffic is blocked (not leaked)"
