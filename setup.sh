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

echo "=== Installing Wi-Fi power save dispatcher ==="
# Broadcom Wi-Fi power save causes multi-second latency spikes on the Pi.
# This dispatcher disables it every time wlan0 comes up.
sudo cp "$SCRIPT_DIR/configs/90-wifi-powersave-off" /etc/NetworkManager/dispatcher.d/90-wifi-powersave-off
sudo chmod +x /etc/NetworkManager/dispatcher.d/90-wifi-powersave-off

echo "=== Installing CPU performance governor service ==="
sudo cp "$SCRIPT_DIR/configs/cpu-performance.service" /etc/systemd/system/cpu-performance.service

echo "=== Applying Pi 4 overclock (arm_freq=2100, over_voltage=8) ==="
# Only on Pi 4, only if not already present. Needs active cooling.
if grep -q "Raspberry Pi 4" /proc/device-tree/model 2>/dev/null && \
   ! grep -q "pivpn-overclock" /boot/firmware/config.txt; then
    sudo cp /boot/firmware/config.txt /boot/firmware/config.txt.bak-preoc
    sudo tee -a /boot/firmware/config.txt >/dev/null <<'EOF'

# pivpn-overclock (Pi 4 stable tier, requires active cooling)
[pi4]
arm_freq=2100
over_voltage=8
gpu_freq=750
EOF
    echo "  Overclock appended. Takes effect on next reboot."
else
    echo "  Skipped (not a Pi 4 or overclock already present)."
fi

# Fix DNS - use Mullvad DNS instead of Tailscale DNS (which can't resolve through VPN)
sudo cp "$SCRIPT_DIR/configs/resolv.conf.mullvad" /etc/resolv.conf.mullvad
sudo cp /etc/resolv.conf.mullvad /etc/resolv.conf
sudo chattr +i /etc/resolv.conf

echo "=== Configuring ethernet sharing (eth0 = client LAN) ==="
# eth0 is the Pi's built-in ethernet port; it serves the 192.168.5.0/24
# client LAN. If a USB ethernet adapter is present (eth1), it becomes the
# preferred uplink to the router/modem with wlan0 as a Wi-Fi fallback.
ETH_CONN=$(nmcli -t -f NAME,TYPE,DEVICE connection show | awk -F: '$2=="802-3-ethernet" && $3=="eth0"{print $1; exit}')
if [ -z "$ETH_CONN" ]; then
    ETH_CONN=$(nmcli -t -f NAME,TYPE connection show | grep ethernet | head -1 | cut -d: -f1)
fi
sudo nmcli connection modify "$ETH_CONN" ipv4.method shared ipv4.addresses 192.168.5.1/24 ipv4.gateway "" connection.autoconnect yes

echo "=== Configuring USB ethernet uplink (eth1) if present ==="
if [ -e /sys/class/net/eth1 ]; then
    sudo nmcli connection add type ethernet ifname eth1 con-name eth1-uplink \
        autoconnect yes ipv4.method auto ipv6.method disabled ipv4.route-metric 50 2>/dev/null || \
    sudo nmcli connection modify eth1-uplink ipv4.method auto ipv6.method disabled ipv4.route-metric 50
    sudo nmcli connection up eth1-uplink 2>/dev/null || true
    echo "  eth1 configured as primary uplink (metric 50)."
else
    echo "  No eth1 detected. Wi-Fi (wlan0) will be the uplink."
    echo "  Plug in a USB ethernet adapter and re-run this block to switch."
fi

echo "=== Hardening SSH ==="
sudo sed -i "s/#PasswordAuthentication yes/PasswordAuthentication no/" /etc/ssh/sshd_config
sudo sed -i "s/PasswordAuthentication yes/PasswordAuthentication no/" /etc/ssh/sshd_config
# Restrict SSH to ethernet and Tailscale only (not Wi-Fi)
# Note: update the Tailscale IP after running 'sudo tailscale up --ssh'
sudo bash -c 'cat > /etc/ssh/sshd_config.d/listen.conf << EOF
ListenAddress 192.168.5.1
EOF'
sudo systemctl restart sshd

echo "=== Disabling unnecessary services ==="
sudo systemctl disable --now cups cups-browsed 2>/dev/null
sudo systemctl disable --now bluetooth 2>/dev/null
sudo systemctl disable --now ModemManager 2>/dev/null
sudo systemctl disable --now rpcbind nfs-blkmap 2>/dev/null
sudo systemctl disable --now avahi-daemon 2>/dev/null
sudo systemctl disable --now lightdm 2>/dev/null

echo "=== Enabling services ==="
sudo systemctl daemon-reload
sudo systemctl enable dnsmasq
sudo systemctl enable vpn-router.service
sudo systemctl enable cpu-performance.service

echo "=== Setting up Tailscale ==="
echo "Run 'sudo tailscale up --ssh' and authenticate when ready."
echo "Then add your Tailscale IP to /etc/ssh/sshd_config.d/listen.conf:"
echo "  TSIP=\$(tailscale ip -4)"
echo "  echo \"ListenAddress \$TSIP\" | sudo tee -a /etc/ssh/sshd_config.d/listen.conf"
echo "  sudo systemctl restart sshd"

echo "=== Adding Wi-Fi networks ==="
echo "You can add additional Wi-Fi networks for fallback."
echo "The Pi will try higher-priority networks first."
while true; do
    read -p "Add a Wi-Fi network? (y/n): " ADD_WIFI
    if [ "$ADD_WIFI" != "y" ]; then break; fi
    read -p "  SSID: " WIFI_SSID
    read -p "  Password: " WIFI_PASS
    read -p "  Priority (higher = preferred, default 5): " WIFI_PRIO
    WIFI_PRIO=${WIFI_PRIO:-5}
    sudo nmcli connection add type wifi ifname wlan0 con-name "$WIFI_SSID" ssid "$WIFI_SSID"
    sudo nmcli connection modify "$WIFI_SSID" wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$WIFI_PASS" connection.autoconnect yes connection.autoconnect-priority "$WIFI_PRIO"
    echo "  Added $WIFI_SSID with priority $WIFI_PRIO"
done

echo ""
echo "=== Setup complete! ==="
echo "Reboot to start everything, or run:"
echo "  sudo wg-quick up mullvad"
echo "  sudo /usr/local/bin/vpn-router-setup.sh"
echo ""
echo "Ethernet clients get 192.168.5.x, all traffic goes through Mullvad VPN"
echo "Kill switch active: if VPN drops, traffic is blocked (not leaked)"
echo ""
echo "IMPORTANT: Install uBlock Origin in your browser and enable"
echo "'Prevent WebRTC from leaking local IP addresses' in its settings."
