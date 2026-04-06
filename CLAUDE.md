# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Infrastructure config for a Raspberry Pi 4 VPN router. Not a software project — it's shell scripts and config files deployed to a Pi running Raspberry Pi OS.

## Architecture

- `setup.sh` — Main setup script. Run once on a fresh Pi OS install. Prompts for Mullvad account, generates WireGuard keys, registers with Mullvad API, configures everything, and enables services.
- `configs/` — Config files copied to the Pi during setup:
  - `mullvad.conf` — WireGuard config template (secrets replaced at setup time)
  - `vpn-router-setup.sh` — Runs at boot: brings up VPN, sets DNS, configures NAT/kill switch/MSS clamping
  - `vpn-router.service` — systemd unit for the boot script
  - `dnsmasq.conf` — DHCP server for ethernet clients (192.168.5.x)
  - `resolv.conf.mullvad` — DNS config using Mullvad DNS (10.64.0.1)
  - `90-ipforward.conf` / `91-disable-ipv6.conf` — sysctl hardening

## Key design decisions

- **MTU 1280 + MSS clamping** — Required because WireGuard reduces effective MTU. Without this, HTTPS fails silently (TCP handshake works but data transfer hangs).
- **Mullvad DNS in resolv.conf** — Tailscale DNS (100.100.100.100) cannot resolve through the VPN tunnel. The Pi's own DNS must use Mullvad DNS (10.64.0.1). resolv.conf is made immutable with `chattr +i`.
- **Kill switch via iptables** — `eth0 -> wlan0` is DROP'd so if VPN dies, client traffic is blocked, not leaked to ISP.
- **No secrets in repo** — WireGuard keys, Mullvad account number, and Wi-Fi passwords are all prompted during setup or generated at runtime.

## Target Pi

- Hostname: `pivpn`
- User: `andyfreed`
- Tailscale IP: `100.73.123.100`
- SSH access: key-only, restricted to ethernet (192.168.5.1) and Tailscale
- Wi-Fi networks: Ncwf1 (priority 10), BeaconHill (priority 5)

## Testing changes

SSH into the Pi via Tailscale: `ssh -i ~/.ssh/pi5_key andyfreed@100.73.123.100`

To verify VPN: `curl -s https://am.i.mullvad.net/connected`
