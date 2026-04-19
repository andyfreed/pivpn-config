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
  - `90-wifi-powersave-off` — NetworkManager dispatcher script that force-disables Broadcom Wi-Fi power save every time wlan0 comes up
  - `cpu-performance.service` — systemd unit pinning the CPU governor to `performance` (no frequency scaling lag)

## Key design decisions

- **Uplink: eth1 (USB ethernet) preferred, wlan0 (Wi-Fi) fallback** — The Pi's built-in Broadcom Wi-Fi is unusable as a router uplink (power save causes multi-second latency spikes; rate adaptation gets stuck). A USB 3 gigabit ethernet adapter wired to the upstream router is the primary uplink (route metric 50). wlan0 stays configured as fallback (metric 600).
- **MTU 1280 + MSS clamping** — Required because WireGuard reduces effective MTU. Without this, HTTPS fails silently (TCP handshake works but data transfer hangs).
- **Mullvad DNS in resolv.conf** — Tailscale DNS (100.100.100.100) cannot resolve through the VPN tunnel. The Pi's own DNS must use Mullvad DNS (10.64.0.1). resolv.conf is made immutable with `chattr +i`.
- **Kill switch via iptables** — `eth0 -> wlan0` AND `eth0 -> eth1` are both DROP'd so if the VPN dies, client traffic is blocked on every uplink, not leaked to the ISP.
- **Local LAN exception (optional)** — `vpn-router-setup.sh` has a `LOCAL_LAN_HOSTS` variable listing specific upstream-LAN IPs that client devices are allowed to reach directly. This is intentionally narrow (single-host allowlist, not a subnet) so the kill switch stays almost entirely strict. Source-NAT is applied so the remote host sees traffic from the Pi's eth1 address. Use for things like a NAS that can't be put behind the VPN but still needs to be accessible from the client LAN. Leave empty to keep the kill switch fully strict.
- **Wi-Fi power save disabled** — Dispatcher script at `/etc/NetworkManager/dispatcher.d/90-wifi-powersave-off` runs `iw dev wlan0 set power_save off` on every wlan0 up event. Without this, wlan0 pings are 2500 ms+ even with perfect signal.
- **CPU governor pinned to performance** — `cpu-performance.service` systemd unit. `ondemand` causes noticeable latency spikes on wake-from-idle for a router workload.
- **Pi 4 overclock: 2000 MHz / over_voltage 6** — Appended to `/boot/firmware/config.txt` by `setup.sh`. Conservative-stable tier that works on all Pi 4 revisions (including Rev 1.2 / B0 stepping) with typical USB-C power bricks. 2100/8 was observed to cause historical under-voltage throttling on marginal PSUs; 2000/6 avoids that while still giving a meaningful bump over stock 1500 MHz. Requires active cooling. Idempotent (guarded by a marker comment). Backup at `config.txt.bak-preoc`.
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
