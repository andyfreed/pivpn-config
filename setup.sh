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
# dnsmasq: the BINARY is required by NetworkManager's shared mode (which runs
# its own dnsmasq instance for the client LAN); the standalone SERVICE is
# disabled below — two instances can't bind the same ports.
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
sudo cp "$SCRIPT_DIR/configs/90-ipforward.conf" /etc/sysctl.d/90-ipforward.conf
sudo cp "$SCRIPT_DIR/configs/91-disable-ipv6.conf" /etc/sysctl.d/91-disable-ipv6.conf
sudo sysctl --system

sudo cp "$SCRIPT_DIR/configs/vpn-router-setup.sh" /usr/local/bin/vpn-router-setup.sh
sudo chmod +x /usr/local/bin/vpn-router-setup.sh
sudo cp "$SCRIPT_DIR/configs/vpn-router.service" /etc/systemd/system/vpn-router.service

echo "=== Installing control-app helper scripts ==="
# Used by the PiVPN Control desktop app (github.com/andyfreed/pivpn-control):
#   vpn-status.sh   - emit status JSON (read-only)
#   switch-server.sh - switch to the fastest server in a region (us|eu)
#   vpn-update.sh   - check/apply updates to this repo and redeploy
for helper in vpn-status.sh switch-server.sh vpn-update.sh vpn-audit.sh vpn-stats.sh vpn-ctl.sh; do
    sudo cp "$SCRIPT_DIR/configs/$helper" "/usr/local/bin/$helper"
    sudo chmod +x "/usr/local/bin/$helper"
done

echo "=== Installing Wi-Fi power save dispatcher ==="
# Broadcom Wi-Fi power save causes multi-second latency spikes on the Pi.
# This dispatcher disables it every time wlan0 comes up.
sudo cp "$SCRIPT_DIR/configs/90-wifi-powersave-off" /etc/NetworkManager/dispatcher.d/90-wifi-powersave-off
sudo chmod +x /etc/NetworkManager/dispatcher.d/90-wifi-powersave-off

echo "=== Installing CPU performance governor service ==="
sudo cp "$SCRIPT_DIR/configs/cpu-performance.service" /etc/systemd/system/cpu-performance.service

echo "=== Applying Pi 4 overclock (arm_freq=2000, over_voltage=6) ==="
# Only on Pi 4, only if not already present. Needs active cooling.
# 2000/6 is the conservative-stable tier — works on all Pi 4 revisions
# including Rev 1.2 (B0 stepping) with typical USB-C power bricks.
# Pushing 2100/8 risks under-voltage events on marginal PSUs.
if grep -q "Raspberry Pi 4" /proc/device-tree/model 2>/dev/null && \
   ! grep -q "pivpn-overclock" /boot/firmware/config.txt; then
    sudo cp /boot/firmware/config.txt /boot/firmware/config.txt.bak-preoc
    sudo tee -a /boot/firmware/config.txt >/dev/null <<'EOF'

# pivpn-overclock (Pi 4 stable tier, requires active cooling)
[pi4]
arm_freq=2000
over_voltage=6
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

echo "=== Configuring ethernet sharing (built-in NIC = client LAN) ==="
# The Pi's BUILT-IN ethernet port serves the 192.168.5.0/24 client LAN via
# NetworkManager "shared" mode (it spawns a dnsmasq on 192.168.5.1 that hands
# out DHCP leases and forwards client DNS to /etc/resolv.conf's nameserver —
# Mullvad 10.64.0.1, i.e. through the tunnel). A USB ethernet adapter, if
# present, becomes the preferred uplink (wlan0 is the fallback).
#
# CRITICAL: pin the client-LAN (shared) connection to the built-in NIC by MAC.
# Without a pin the shared profile isn't tied to a device, so when a USB
# ethernet dongle appears or revives, NetworkManager can bind the shared
# profile to the DONGLE instead — the client LAN (and any PC on it) then loses
# DHCP, and the iptables kill-switch rules (written for eth0) point at the
# wrong interface. Detect the built-in NIC as the non-USB ethernet and pin it.
BUILTIN_IF=""; BUILTIN_MAC=""
for dev in /sys/class/net/eth*; do
    [ -e "$dev" ] || continue
    ifn=$(basename "$dev")
    if readlink -f "$dev/device" 2>/dev/null | grep -q usb; then
        continue                      # USB adapter -> uplink, not the client LAN
    fi
    BUILTIN_IF="$ifn"; BUILTIN_MAC=$(cat "$dev/address"); break
done
: "${BUILTIN_IF:=eth0}"

ETH_CONN=$(nmcli -t -f NAME,TYPE,DEVICE connection show | awk -F: -v d="$BUILTIN_IF" '$2=="802-3-ethernet" && $3==d{print $1; exit}')
if [ -z "$ETH_CONN" ]; then
    ETH_CONN=$(nmcli -t -f NAME,TYPE connection show | grep ethernet | head -1 | cut -d: -f1)
fi
sudo nmcli connection modify "$ETH_CONN" \
    ipv4.method shared ipv4.addresses 192.168.5.1/24 ipv4.gateway "" \
    connection.autoconnect yes connection.autoconnect-priority 100
if [ -n "$BUILTIN_MAC" ]; then
    sudo nmcli connection modify "$ETH_CONN" 802-3-ethernet.mac-address "$BUILTIN_MAC"
    echo "  Client LAN pinned to built-in NIC $BUILTIN_IF ($BUILTIN_MAC)."
fi

echo "=== Configuring USB ethernet uplink if present ==="
# The dongle is whatever ethernet is NOT the (MAC-pinned) built-in NIC. Bind
# the uplink by interface NAME (not MAC) so a replacement dongle still works.
USB_IF=""
for dev in /sys/class/net/eth*; do
    [ -e "$dev" ] || continue
    ifn=$(basename "$dev")
    [ "$ifn" = "$BUILTIN_IF" ] && continue
    if readlink -f "$dev/device" 2>/dev/null | grep -q usb; then USB_IF="$ifn"; break; fi
done
if [ -n "$USB_IF" ]; then
    sudo nmcli connection add type ethernet ifname "$USB_IF" con-name eth1-uplink \
        autoconnect yes ipv4.method auto ipv6.method disabled ipv4.route-metric 50 2>/dev/null || \
    sudo nmcli connection modify eth1-uplink connection.interface-name "$USB_IF" \
        ipv4.method auto ipv6.method disabled ipv4.route-metric 50
    sudo nmcli connection up eth1-uplink 2>/dev/null || true
    echo "  $USB_IF configured as primary uplink (metric 50); wlan0 is the fallback."
else
    echo "  No USB ethernet detected. Wi-Fi (wlan0) will be the uplink."
    echo "  Plug in a USB ethernet adapter and re-run this block to switch."
fi

echo "=== Hardening SSH ==="
sudo sed -i "s/#PasswordAuthentication yes/PasswordAuthentication no/" /etc/ssh/sshd_config
sudo sed -i "s/PasswordAuthentication yes/PasswordAuthentication no/" /etc/ssh/sshd_config
# Raspberry Pi OS images ship a cloud-init drop-in that sets
# `PasswordAuthentication yes`, which overrides the main config. Neutralize it
# AND add a high-priority drop-in so key-only auth wins no matter what.
if [ -f /etc/ssh/sshd_config.d/50-cloud-init.conf ]; then
    sudo sed -i "s/^PasswordAuthentication yes/PasswordAuthentication no/" \
        /etc/ssh/sshd_config.d/50-cloud-init.conf
fi
sudo tee /etc/ssh/sshd_config.d/99-hardening.conf >/dev/null <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
EOF
# Restrict SSH to ethernet and Tailscale only (not Wi-Fi)
# Note: update the Tailscale IP after running 'sudo tailscale up --ssh'
sudo bash -c 'cat > /etc/ssh/sshd_config.d/listen.conf << EOF
ListenAddress 192.168.5.1
EOF'
# Because sshd binds that specific address, it loses a boot race against
# NetworkManager bringing eth0 up and dies ("Cannot assign requested
# address"). This drop-in waits for the network and retries on failure.
sudo mkdir -p /etc/systemd/system/ssh.service.d
sudo cp "$SCRIPT_DIR/configs/ssh-wait-network.conf" \
    /etc/systemd/system/ssh.service.d/10-wait-network.conf
sudo systemctl enable NetworkManager-wait-online.service 2>/dev/null
sudo systemctl daemon-reload
sudo systemctl restart sshd

echo "=== Disabling unnecessary services ==="
sudo systemctl disable --now cups cups-browsed 2>/dev/null
sudo systemctl disable --now bluetooth 2>/dev/null
sudo systemctl disable --now ModemManager 2>/dev/null
sudo systemctl disable --now rpcbind nfs-blkmap 2>/dev/null
sudo systemctl disable --now avahi-daemon 2>/dev/null
sudo systemctl disable --now lightdm 2>/dev/null
# Standalone dnsmasq would fight NetworkManager's shared-mode dnsmasq over
# ports 53/67 on eth0 and lose at every boot (status: failed). NM's instance
# does the job (DHCP + tunnel-routed DNS), so the standalone service stays off.
sudo systemctl disable --now dnsmasq 2>/dev/null

echo "=== Enabling services ==="
sudo systemctl daemon-reload
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
