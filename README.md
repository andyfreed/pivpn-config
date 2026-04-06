# PiVPN Config

Configuration and setup script for a Raspberry Pi VPN router using Mullvad and WireGuard.

## What it does

- Connects to the internet via Wi-Fi
- Routes all ethernet client traffic through a Mullvad VPN tunnel
- Kill switch: if VPN drops, traffic is blocked (not leaked to ISP)
- DNS queries go through Mullvad's DNS inside the tunnel
- Tailscale exit node: remote devices on the tailnet can route all traffic through the Pi and out via Mullvad
- Tailscale for remote SSH access from anywhere
- Hardened: IPv6 disabled, SSH key-only, unnecessary services removed

## Hardware

- Raspberry Pi 4 Model B (or Pi 5)
- Ethernet cable to connect devices

## Network layout

| Interface | Subnet | Purpose |
|-----------|--------|---------|
| wlan0 | DHCP from router | Internet via Wi-Fi |
| mullvad | 10.x.x.x (Mullvad) | VPN tunnel |
| eth0 | 192.168.5.0/24 | Wired device sharing |
| tailscale0 | 100.x.x.x | Remote access |

## Security

| Safeguard | Details |
|-----------|---------|
| VPN kill switch | eth0 -> wlan0 is DROP'd, traffic blocked if VPN drops |
| DNS through VPN | All DNS goes to Mullvad DNS (10.64.0.1) only — no fallback resolvers |
| MTU/MSS clamping | Fixes HTTPS through VPN tunnel (MTU 1280, MSS clamped) |
| IPv6 disabled | Prevents IPv6 traffic from leaking outside the tunnel |
| IPv6 forwarding blocked | Double protection even if IPv6 re-enables |
| ICMP redirects blocked | Prevents route manipulation attacks |
| SSH key-only | Password authentication disabled |
| SSH restricted | Only listens on ethernet (192.168.5.1) and Tailscale |
| Bluetooth disabled | Reduced attack surface |
| CUPS/print disabled | Reduced attack surface |
| ModemManager disabled | Not needed, removed |
| RPC/NFS disabled | Not needed, removed |
| Avahi/mDNS disabled | Stops hostname broadcasting on network |
| GUI disabled | Headless, fewer services running |

**Client-side:** Install [uBlock Origin](https://ublockorigin.com/) in your browser and enable "Prevent WebRTC from leaking local IP addresses" in its settings.

## Restore from scratch

1. Flash a fresh Raspberry Pi OS image using Raspberry Pi Imager
   - Set hostname to `pivpn`
   - Set username/password
   - Enable SSH with password auth
   - Configure Wi-Fi
2. Boot the Pi and SSH in
3. Add your SSH public key to `~/.ssh/authorized_keys`
4. Run:

```bash
sudo apt-get install -y git
git clone https://github.com/andyfreed/pivpn-config.git
cd pivpn-config
bash setup.sh
```

5. When prompted, enter your Mullvad account number and choose a server city
6. After setup completes, run:

```bash
sudo tailscale up --ssh
```

7. Open the auth link in your browser to add the Pi to your Tailscale network
8. Add your Tailscale IP to the SSH listener:

```bash
TSIP=$(tailscale ip -4)
echo "ListenAddress $TSIP" | sudo tee -a /etc/ssh/sshd_config.d/listen.conf
sudo systemctl restart sshd
```

9. Reboot the Pi

All services start automatically on boot. Plug any device into the ethernet port and its traffic is VPN-protected.

## Multiple Wi-Fi networks

The setup script lets you add multiple Wi-Fi networks with priorities. The Pi will try the highest priority network first and fall back to others if unavailable. You can also add networks later:

```bash
sudo nmcli connection add type wifi ifname wlan0 con-name "NetworkName" ssid "NetworkName"
sudo nmcli connection modify "NetworkName" wifi-sec.key-mgmt wpa-psk wifi-sec.psk "password" connection.autoconnect yes connection.autoconnect-priority 5
```

Higher priority number = tried first.
