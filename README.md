# PiVPN Config

Configuration and setup script for a Raspberry Pi VPN router using Mullvad and WireGuard.

## What it does

- Connects to the internet via Wi-Fi
- Routes all ethernet client traffic through a Mullvad VPN tunnel
- Kill switch: if VPN drops, traffic is blocked (not leaked to ISP)
- DNS queries go through Mullvad's DNS inside the tunnel
- IPv6 disabled to prevent leaks
- Tailscale for remote SSH access from anywhere
- SSH hardened to key-only authentication

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

- All client traffic forced through VPN tunnel
- Kill switch blocks traffic if VPN drops (iptables DROP on eth0 -> wlan0)
- IPv6 completely disabled to prevent tunnel bypass
- DNS goes to Mullvad DNS (10.64.0.1) inside the tunnel
- ICMP redirects disabled to prevent route manipulation
- SSH password authentication disabled

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
8. Reboot the Pi

All services start automatically on boot. Plug any device into the ethernet port and its traffic is VPN-protected.
